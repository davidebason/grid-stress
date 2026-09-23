"""Parse ENTSO-E Transparency Platform XML into tidy frames.

One reader per document type, each returning a single DataFrame whose columns already match the
fact table that document feeds: A65 load, A75 generation per production type and direction, A44
day-ahead prices. xml_reader dispatches on the document's own type element and adds the two
document-level provenance values every caller needs.

Every series is decoded on its own terms. Each Period states its own time interval and
resolution, and under the A03 block encoding only the positions whose value changed are listed,
so a listed value holds until the next listed position or until the period ends. That is expanded
back to one point per interval before any timestamp is computed. See DATA.md, under What a
generation response contains, for the encodings observed and for what this parser does not
assume.

Production type codes are kept as ENTSO-E writes them and are never translated to names.
"""

import xml.etree.ElementTree as ET
from datetime import datetime

import pandas as pd


def fill_time_measure(position, value, curve_type, date_start, date_end, resolution):
    """Expand a sparse A03 series so that every interval carries a value.

    Missing positions are filled with the last listed value, and the series is extended to the
    number of intervals between date_start and date_end. An A01 series is dense by definition and
    is returned unchanged, as is any series that already has the expected number of points.

    position and value are modified in place as well as returned.
    """

    if curve_type == "A01":
        return position, value
    else:
        n_should = (
            datetime.fromisoformat(date_end) - datetime.fromisoformat(date_start)
        ) // pd.Timedelta(resolution).to_pytimedelta()
        n = len(position)
        if n == n_should:
            return position, value
        else:
            copy_position = position.copy()
            copy_value = value.copy()

            for i in range(n - 1):
                k = copy_position[i + 1] - copy_position[i]
                if k > 1:
                    for j in range(k - 1):
                        position.insert(copy_position[i] + j, copy_position[i] + 1 + j)
                        value.insert(copy_position[i] + j, copy_value[i])

            delta = n_should - len(position)

            if delta > 0:
                last_position = position[-1]
                last_value = value[-1]
                for i in range(delta):
                    position.append(last_position + 1 + i)
                    value.append(last_value)

            return position, value


def utc_times(position, date_start, resolution):
    """Return the UTC timestamp of each position.

    Position 1 is date_start, and each further position is one resolution later. The times come
    from the document's own interval and resolution, so nothing here assumes how long a day is.
    """

    date_start_pd = pd.Timestamp(date_start)
    step = pd.Timedelta(resolution)

    return [date_start_pd + (p - 1) * step for p in position]


def xml_reader(file):
    """Parse one saved response and return its contents with the document-level provenance.

    Dispatches on the document's own type element rather than on the filename. Returns one of
    three shapes:

    - a supported document, A65, A75 or A44: (createdDateTime, revisionNumber, frame), where the
      frame's columns already match the fact table that document feeds;
    - an acknowledgement, which carries no type element: (createdDateTime, the reason text);
    - any other document type: a message saying so, with nothing parsed.

    createdDateTime is when ENTSO-E generated the response, not when the data was published, so
    it records when the file was fetched rather than the vintage of what is in it.
    """

    xml = ET.parse(file)
    root = xml.getroot()
    ns = {"d": root.tag[1:].split("}")[0]}

    type_file = root.find("d:type", ns)
    createdDateTime = root.find("d:createdDateTime", ns).text

    if type_file is None:
        return createdDateTime, root.find("d:Reason/d:text", ns).text
    else:
        type_file = type_file.text
        revisionNumber = root.find("d:revisionNumber", ns).text
        if type_file == "A65":
            return createdDateTime, revisionNumber, gl65_reader(root, ns)
        elif type_file == "A75":
            return createdDateTime, revisionNumber, gl75_reader(root, ns)
        elif type_file == "A44":
            return createdDateTime, revisionNumber, pm_reader(root, ns)
        else:
            return (
                f"Your file is of type {type_file}. This reader can only read files of type A44, "
                "A65, A75 or Acknowledgement_MarketDocument. The reader stops here."
            )


def gl65_reader(root, ns):
    """Read an A65 load document into one frame of date_utc and load_mw.

    A load document holds a single TimeSeries covering the whole requested window.
    """

    series = root.find("d:TimeSeries", ns)
    period = series.find("d:Period", ns)

    curve_type = series.find("d:curveType", ns).text

    date_start = period.find("d:timeInterval/d:start", ns).text
    date_end = period.find("d:timeInterval/d:end", ns).text
    resolution = period.find("d:resolution", ns).text

    position = [int(x.text) for x in period.findall("d:Point/d:position", ns)]
    value = [float(x.text) for x in period.findall("d:Point/d:quantity", ns)]
    position, value = fill_time_measure(
        position, value, curve_type, date_start, date_end, resolution
    )
    times = utc_times(position, date_start, resolution)

    df = pd.DataFrame({"date_utc": times, "load_mw": value})

    return df


def gl75_reader(root, ns):
    """Read an A75 generation document into one frame, every series concatenated.

    Columns are date_utc, psr_type, direction and power_mw. direction is "in" or "out", taken
    from whether a series carries inBiddingZone_Domain or outBiddingZone_Domain, which is the
    only marker of direction since both hold the same zone code. A series summed without it
    counts consumption as generation. Each series states its own interval and resolution, so the
    times are built per series rather than once for the document.
    """

    series = root.findall("d:TimeSeries", ns)
    period = [x.find("d:Period", ns) for x in series]

    curve_type = [x.find("d:curveType", ns).text for x in series]

    date_start = [x.find("d:timeInterval/d:start", ns).text for x in period]
    date_end = [x.find("d:timeInterval/d:end", ns).text for x in period]
    resolution = [x.find("d:resolution", ns).text for x in period]

    position = [[int(y.text) for y in x.findall("d:Point/d:position", ns)] for x in period]
    value = [[float(y.text) for y in x.findall("d:Point/d:quantity", ns)] for x in period]
    filled = [
        fill_time_measure(
            position[i], value[i], curve_type[i], date_start[i], date_end[i], resolution[i]
        )
        for i in range(len(period))
    ]
    position = [f[0] for f in filled]
    value = [f[1] for f in filled]
    time = [utc_times(position[i], date_start[i], resolution[i]) for i in range(len(period))]

    psrType = [x.find("d:MktPSRType/d:psrType", ns).text for x in series]
    gener_idx = [
        i for i, s in enumerate(series) if s.find("d:inBiddingZone_Domain.mRID", ns) is not None
    ]
    cons_idx = [
        i for i, s in enumerate(series) if s.find("d:outBiddingZone_Domain.mRID", ns) is not None
    ]

    generations = [
        pd.DataFrame(
            {
                "date_utc": time[i],
                "psr_type": [psrType[i]] * len(time[i]),
                "direction": ["in"] * len(time[i]),
                "power_mw": value[i],
            }
        )
        for i in gener_idx
    ]
    consumptions = [
        pd.DataFrame(
            {
                "date_utc": time[i],
                "psr_type": [psrType[i]] * len(time[i]),
                "direction": ["out"] * len(time[i]),
                "power_mw": value[i],
            }
        )
        for i in cons_idx
    ]
    df = [x for sublist in [generations, consumptions] for x in sublist]

    return pd.concat(df, ignore_index=True)


def pm_reader(root, ns):
    """Read an A44 price document into one frame of date_utc, resolution and price_eur_per_mwh.

    Prices arrive as one TimeSeries per Amsterdam local day, each carrying its own resolution:
    hourly through the local day 2025-09-30 and quarter-hourly from 2025-10-01, when the
    day-ahead market time unit changed. The resolution is therefore kept per row rather than
    assumed for the document.
    """

    series = root.findall("d:TimeSeries", ns)
    period = [x.find("d:Period", ns) for x in series]

    curve_type = [x.find("d:curveType", ns).text for x in series]

    date_start = [x.find("d:timeInterval/d:start", ns).text for x in period]
    date_end = [x.find("d:timeInterval/d:end", ns).text for x in period]
    resolution = [x.find("d:resolution", ns).text for x in period]

    position = [[int(y.text) for y in x.findall("d:Point/d:position", ns)] for x in period]
    value = [[float(y.text) for y in x.findall("d:Point/d:price.amount", ns)] for x in period]
    filled = [
        fill_time_measure(
            position[i], value[i], curve_type[i], date_start[i], date_end[i], resolution[i]
        )
        for i in range(len(period))
    ]
    position = [f[0] for f in filled]
    value = [f[1] for f in filled]
    time_resolution = [
        [utc_times(position[i], date_start[i], resolution[i]), resolution[i]]
        for i in range(len(period))
    ]

    df = pd.DataFrame(
        {
            "date_utc": [tr for tri in time_resolution for tr in tri[0]],
            "resolution": [tri[1] for tri in time_resolution for _ in tri[0]],
            "price_eur_per_mwh": [v for vi in value for v in vi],
        }
    )

    # One series per local day, so the order of the frame is the order of the series in the
    # document. Sorting makes it independent of that.
    return df.sort_values("date_utc", ignore_index=True)
