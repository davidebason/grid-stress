"""Which resolution each dataset uses, and when the day-ahead price resolution changed.

Reads every response in data/raw/ and reports, per dataset, the resolutions present, how many
Periods carry each, and the local days at which one gives way to the next. Also reports the curve
types, because under A03 a Period carries only the positions whose value changed, so the number of
points in a day says nothing about its resolution and the resolution element is the only source.

Run from the repository root:

    python evidence/01_price_resolution.py

Regenerates the figures quoted under "The resolution of each dataset" in DATA.md.
"""

import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

RAW = Path("data/raw")

DATASETS = {
    "a44": "day-ahead prices",
    "a65": "actual total load",
    "a75": "actual generation per production type",
}

# What one Period covers, which is not the same for every dataset: a price Period is one local
# day, a load or generation Period is the whole requested window. Point counts are only
# comparable against an expectation for the first.
PERIOD_IS_A_LOCAL_DAY = {"a44": True, "a65": False, "a75": False}

# Points a complete Period would carry, per resolution, for a local day of each length. A day is
# 23 hours when the clocks go forward, 25 when they go back.
POINTS_PER_DAY = {
    "PT60M": {23: 23, 24: 24, 25: 25},
    "PT15M": {23: 92, 24: 96, 25: 100},
}


def periods(path):
    """Every Period in one response, as (resolution, curve type, period start, point count)."""
    root = ET.parse(path).getroot()
    namespace = {"d": root.tag[1:].split("}")[0]}

    out = []
    for series in root.findall("d:TimeSeries", namespace):
        curve_type = series.find("d:curveType", namespace).text
        for period in series.findall("d:Period", namespace):
            out.append(
                (
                    period.find("d:resolution", namespace).text,
                    curve_type,
                    period.find("d:timeInterval/d:start", namespace).text,
                    len(period.findall("d:Point/d:position", namespace)),
                )
            )
    return out


def report_dataset(prefix, description):
    """Print one dataset's resolutions, per file and then over the whole range."""
    paths = sorted(RAW.glob(f"{prefix}_*.xml"))
    print(f"\n{prefix.upper()}, {description}: {len(paths)} files")

    starts = defaultdict(list)
    points = defaultdict(list)
    curve_types = set()

    for path in paths:
        by_resolution = defaultdict(list)
        for resolution, curve_type, start, n_points in periods(path):
            by_resolution[resolution].append(start)
            starts[resolution].append(start)
            points[resolution].append(n_points)
            curve_types.add(curve_type)

        window = f"{path.name.split('_')[1]} to {path.name.split('_')[2]}"
        summary = "; ".join(
            f"{resolution} x{len(v)} ({min(v)} .. {max(v)})"
            for resolution, v in sorted(by_resolution.items())
        )
        print(f"  {window}: {summary}")

    print(f"  curve types: {', '.join(sorted(curve_types))}")
    for resolution in sorted(starts):
        v = starts[resolution]
        n = points[resolution]
        line = (
            f"  {resolution}: {len(v)} periods, first {min(v)}, last {max(v)}, "
            f"points {min(n)} to {max(n)}"
        )
        if PERIOD_IS_A_LOCAL_DAY[prefix]:
            expected = POINTS_PER_DAY[resolution]
            line += (
                f" against {expected[23]}/{expected[24]}/{expected[25]} "
                f"for a complete 23/24/25-hour local day"
            )
        else:
            line += " per Period, each Period covering a whole requested window"
        print(line)

    return starts


def report_changeover(starts):
    """Print the boundary between two resolutions, where a dataset has more than one."""
    if len(starts) < 2:
        print("\nOne resolution throughout the range: no changeover.")
        return

    ordered = sorted(starts, key=lambda resolution: min(starts[resolution]))
    for earlier, later in zip(ordered, ordered[1:], strict=False):
        last_earlier = max(starts[earlier])
        first_later = min(starts[later])
        print(
            f"\nChangeover {earlier} to {later}:"
            f"\n  last {earlier} Period starts {last_earlier}"
            f"\n  first {later} Period starts {first_later}"
        )
        overlap = [s for s in starts[earlier] if s > first_later]
        print(f"  {earlier} Periods starting after that instant: {len(overlap)}")


def main():
    for prefix, description in DATASETS.items():
        starts = report_dataset(prefix, description)
        if prefix == "a44":
            report_changeover(starts)


if __name__ == "__main__":
    main()
