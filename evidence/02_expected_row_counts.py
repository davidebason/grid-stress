"""What each table should hold, derived from the range and the documents' own metadata.

Computes the expected row count of every table without opening the database, so the figures the
loader reports can be checked against something independent of the loader. The range and the
resolution change are the only inputs for load, price and time; generation is counted from the
number of TimeSeries each A75 response carries.

Run from the repository root:

    python evidence/02_expected_row_counts.py

Regenerates the expected figures quoted under "What the database holds" in DATA.md.
"""

import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

RAW = Path("data/raw")

# The fetch range, as Amsterdam local midnights expressed in UTC. Matches RANGE_BEGIN and
# RANGE_END in src/gridstress/fetch.py.
RANGE_BEGIN = "202012312300"
RANGE_END = "202608312200"

# The instant the day-ahead market time unit changed from one hour to a quarter, delivery day
# 2026-10-01 Amsterdam local. See "The resolution of each dataset" in DATA.md.
MTU_CHANGE = "202509302200"

HOUR, QUARTER = 3600, 900


def units(begin, end, seconds):
    """How many whole units of `seconds` fit between two YYYYMMDDHHmm instants."""
    a = datetime.strptime(begin, "%Y%m%d%H%M").replace(tzinfo=UTC)
    b = datetime.strptime(end, "%Y%m%d%H%M").replace(tzinfo=UTC)
    return int((b - a).total_seconds() // seconds)


def expected_generation():
    """One row per market time unit per TimeSeries, summed over the A75 windows."""
    total = 0
    for path in sorted(RAW.glob("a75_*.xml")):
        root = ET.parse(path).getroot()
        namespace = {"d": root.tag[1:].split("}")[0]}
        n_series = len(root.findall("d:TimeSeries", namespace))
        _, window_start, window_end, _ = path.stem.split("_")
        total += n_series * units(window_start, window_end, QUARTER)
    return total


def main():
    hourly = units(RANGE_BEGIN, MTU_CHANGE, HOUR)
    quarterly = units(MTU_CHANGE, RANGE_END, QUARTER)

    expected = {
        "dim_production_type": 20,
        "dim_time": units(RANGE_BEGIN, RANGE_END, HOUR),
        "fact_load": units(RANGE_BEGIN, RANGE_END, QUARTER),
        "fact_price": hourly + quarterly,
        "fact_generation": expected_generation(),
    }

    for table, n in expected.items():
        print(f"{table:22}{n:>12,}")
    print(f"\nfact_price is {hourly:,} hourly + {quarterly:,} quarter-hourly")
    print("dim_production_type is the 20 production types B01 to B20 in code list v36r0")


if __name__ == "__main__":
    main()
