import xml.etree.ElementTree as ET
from datetime import datetime

import pandas as pd


def fill_time_measure(position, value, curve_type, date_start, date_end, resolution):

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

    date_start_pd = pd.Timestamp(date_start)
    step = pd.Timedelta(resolution)

    return [date_start_pd + (p - 1) * step for p in position]


def xml_reader(file):

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

    df = pd.DataFrame({"date_utc": times, "power_mw": value})

    return df


def gl75_reader(root, ns):

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
        [psrType[i], pd.DataFrame({"date_utc": time[i], "power_mw": value[i]})] for i in gener_idx
    ]
    consumptions = [
        [psrType[i], pd.DataFrame({"date_utc": time[i], "power_mw": value[i]})] for i in cons_idx
    ]

    return [["generation", generations], ["consumption", consumptions]]


def pm_reader(root, ns):

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
    time = [utc_times(position[i], date_start[i], resolution[i]) for i in range(len(period))]

    df = pd.DataFrame(
        {
            "date_utc": [t for ti in time for t in ti],
            "price_eur_per_mwh": [v for vi in value for v in vi],
        }
    )

    # One series per local day, so the order of the frame is the order of the series in the
    # document. Sorting makes it independent of that.
    return df.sort_values("date_utc", ignore_index=True)
