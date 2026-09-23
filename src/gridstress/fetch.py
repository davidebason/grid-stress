"""Fetch the project's three datasets from ENTSO-E and save every response to data/raw/.

A program, not a library: run it with `python -m gridstress.fetch`.

One file per window, named for the dataset, the window and the day it was fetched, because
ENTSO-E restates published data and a row count is only reproducible against a known fetch date.
A window whose file already exists is skipped, so an interrupted run can be restarted without
refetching what it already has. Nothing is parsed here: that is a separate step reading these
files.
"""

import sys
from datetime import date
from pathlib import Path

from gridstress.client import api_request, window_edges

RAW = Path("data/raw")

# The range, as Amsterdam local midnights expressed in UTC: 2021-01-01 to 2026-09-01.
RANGE_BEGIN = "202012312300"
RANGE_END = "202608312200"

NETHERLANDS = "10YNL----------L"

# The three datasets, with the query each one needs. A75 asked for with in_Domain returns both
# directions, generation and consumption, one TimeSeries per production type per direction.
DATASETS = {
    "A65": {
        "name": "actual total load",
        "process_type": "A16",
        "domain_1": "outBiddingZone_Domain",
        "zone_1": NETHERLANDS,
    },
    "A75": {
        "name": "actual generation per production type",
        "process_type": "A16",
        "domain_1": "in_Domain",
        "zone_1": NETHERLANDS,
    },
    "A44": {
        "name": "day-ahead prices",
        "process_type": None,
        "domain_1": "in_Domain",
        "zone_1": NETHERLANDS,
        "domain_2": "out_Domain",
        "zone_2": NETHERLANDS,
    },
}


def raw_path(document_type, window_start, window_end, fetched_on):
    """Where one window's response is saved."""
    return RAW / f"{document_type.lower()}_{window_start}_{window_end}_fetched{fetched_on}.xml"


def already_fetched(document_type, window_start, window_end):
    """Any file for this window, whatever day it was fetched on."""
    pattern = f"{document_type.lower()}_{window_start}_{window_end}_fetched*.xml"
    return sorted(RAW.glob(pattern))


def fetch_dataset(document_type, spec, timeout, fetched_on):
    """Fetch every window of one dataset, saving each response. Returns the windows not fetched."""
    edges = window_edges(RANGE_BEGIN, RANGE_END)
    windows = list(zip(edges, edges[1:], strict=False))
    missing = []

    print(f"\n{document_type}, {spec['name']}: {len(windows)} windows")
    for number, (window_start, window_end) in enumerate(windows, start=1):
        existing = already_fetched(document_type, window_start, window_end)
        if existing:
            print(
                f"  {number}/{len(windows)} {window_start} to {window_end}: have {existing[0].name}"
            )
            continue

        outcome = api_request(
            document_type,
            spec["process_type"],
            window_start,
            window_end,
            timeout,
            spec["domain_1"],
            spec["zone_1"],
            spec.get("domain_2"),
            spec.get("zone_2"),
        )

        if outcome is None:
            print(f"  {number}/{len(windows)} {window_start} to {window_end}: fetch stopped here")
            missing.extend(windows[number - 1 :])
            return missing
        if isinstance(outcome, str):
            print(f"  {number}/{len(windows)}: {outcome}")
            missing.extend(windows[number - 1 :])
            return missing

        window_missing, responses = outcome
        missing.extend(window_missing)
        for start, end, response in responses:
            path = raw_path(document_type, start, end, fetched_on)
            path.write_bytes(response.content)
            size_mb = path.stat().st_size / 1e6
            print(f"  {number}/{len(windows)} {start} to {end}: {size_mb:.1f} MB -> {path.name}")

    return missing


def main():
    RAW.mkdir(parents=True, exist_ok=True)
    fetched_on = date.today().strftime("%Y%m%d")
    timeout = 300

    not_fetched = {}
    for document_type, spec in DATASETS.items():
        not_fetched[document_type] = fetch_dataset(document_type, spec, timeout, fetched_on)

    print("\nSummary")
    for document_type, windows in not_fetched.items():
        if windows:
            print(f"  {document_type}: {len(windows)} windows not fetched")
            for window_start, window_end in windows:
                print(f"    {window_start} {window_end}")
        else:
            print(f"  {document_type}: every window fetched")

    files = sorted(RAW.glob("*.xml"))
    total_mb = sum(path.stat().st_size for path in files) / 1e6
    print(f"\n{len(files)} files in {RAW}, {total_mb:.1f} MB in total")

    if any(not_fetched.values()):
        print("\nRerun to retry the windows above: files already fetched are skipped.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
