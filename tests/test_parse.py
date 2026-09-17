"""Tests for the ENTSO-E XML parser, against the recorded responses in tests/fixtures.

Every fixture is a real API response except load_nl_20260914_sparse_handbuilt.xml, which is
load_nl_20260914_dense.xml with the Point elements for positions 5 to 9, 61 to 89 and 91 to 96
deleted and nothing else changed. It exercises all three A03 omissions on one known series: a gap
at the start, a long gap in the middle, and a listing that stops before the period end.

Expected values are read off the fixture files by hand and written out, not recomputed with the
parser's own logic, except in the generation tests, where the listed points of each series are read
straight from the XML and the parser's filled frame is checked against them.
"""

import xml.etree.ElementTree as ET
from pathlib import Path

import pandas as pd
import pytest

from gridstress import my_parse

FIXTURES = Path(__file__).parent / "fixtures"
STEP = pd.Timedelta(minutes=15)


def utc(text):
    return pd.Timestamp(text, tz="UTC")


def read(name):
    return my_parse.xml_reader(FIXTURES / name)


def assert_regular_times(frame, first, n_rows):
    """The first column starts at `first`, has `n_rows` rows, and steps by exactly 15 minutes."""
    times = frame["date_utc"]
    assert len(frame) == n_rows
    assert times.iloc[0] == first
    assert (times.diff().dropna() == STEP).all()
    assert str(times.dt.tz) == "UTC"


# fill_time_measure and utc_times, on small hand-written inputs


def test_fill_leaves_a_complete_series_unchanged():
    position, value = my_parse.fill_time_measure(
        [1, 2, 3, 4], [1.0, 2.0, 3.0, 4.0], "A03", "2026-09-13T22:00Z", "2026-09-13T23:00Z", "PT15M"
    )
    assert position == [1, 2, 3, 4]
    assert value == [1.0, 2.0, 3.0, 4.0]


def test_fill_repeats_the_last_listed_value_across_a_gap():
    position, value = my_parse.fill_time_measure(
        [1, 4], [10.0, 40.0], "A03", "2026-09-13T22:00Z", "2026-09-13T23:00Z", "PT15M"
    )
    assert position == [1, 2, 3, 4]
    assert value == [10.0, 10.0, 10.0, 40.0]


def test_fill_extends_the_last_listed_value_to_the_period_end():
    position, value = my_parse.fill_time_measure(
        [1, 2], [1.0, 2.0], "A03", "2026-09-13T22:00Z", "2026-09-13T23:00Z", "PT15M"
    )
    assert position == [1, 2, 3, 4]
    assert value == [1.0, 2.0, 2.0, 2.0]


def test_fill_expands_a_single_point_to_the_whole_period():
    position, value = my_parse.fill_time_measure(
        [1], [7.5], "A03", "2026-09-13T22:00Z", "2026-09-14T22:00Z", "PT15M"
    )
    assert position == list(range(1, 97))
    assert value == [7.5] * 96


def test_fill_returns_a01_series_as_given():
    position, value = my_parse.fill_time_measure(
        [1, 3], [1.0, 3.0], "A01", "2026-09-13T22:00Z", "2026-09-13T23:00Z", "PT15M"
    )
    assert position == [1, 3]
    assert value == [1.0, 3.0]


def test_utc_times_places_each_position_from_the_start():
    times = my_parse.utc_times([1, 2, 4], "2026-09-13T22:00Z", "PT15M")
    assert times == [utc("2026-09-13 22:00"), utc("2026-09-13 22:15"), utc("2026-09-13 22:45")]


def test_utc_times_follows_the_resolution():
    times = my_parse.utc_times([1, 2], "2024-01-01T00:00Z", "PT60M")
    assert times == [utc("2024-01-01 00:00"), utc("2024-01-01 01:00")]


# Acknowledgements


@pytest.mark.parametrize(
    ("name", "created", "text_start"),
    [
        ("no_data_acknowledgement.xml", "2026-09-16T04:35:26Z", "No matching data found"),
        ("bad_request_400.xml", "2026-09-16T04:41:28Z", "The combination of [DOCUMENT_TYPE=XXX"),
    ],
)
def test_acknowledgement_returns_created_time_and_reason(name, created, text_start):
    out = read(name)
    assert len(out) == 2
    assert out[0] == created
    assert out[1].startswith(text_start)


# Load, A65


def test_load_dense_day():
    created, revision, frame = read("load_nl_20260914_dense.xml")
    assert created == "2026-09-16T04:28:02Z"
    assert revision == "1"
    assert list(frame.columns) == ["date_utc", "power_mw"]
    assert_regular_times(frame, utc("2026-09-13 22:00"), 96)
    assert frame["date_utc"].iloc[-1] == utc("2026-09-14 21:45")
    assert frame["power_mw"].iloc[0] == 10377.306
    assert frame["power_mw"].iloc[-1] == 11061.016


@pytest.mark.parametrize(
    ("name", "first", "last", "n_rows", "first_value", "last_value"),
    [
        (
            "load_nl_20260329_dst_spring.xml",
            "2026-03-28 23:00",
            "2026-03-29 21:45",
            92,
            12302.17,
            12731.982,
        ),
        (
            "load_nl_20251026_dst_autumn.xml",
            "2025-10-25 22:00",
            "2025-10-26 22:45",
            100,
            12479.629,
            12498.207,
        ),
    ],
)
def test_load_clock_change_days(name, first, last, n_rows, first_value, last_value):
    _, _, frame = read(name)
    assert_regular_times(frame, utc(first), n_rows)
    assert frame["date_utc"].iloc[-1] == utc(last)
    assert frame["power_mw"].iloc[0] == first_value
    assert frame["power_mw"].iloc[-1] == last_value


def test_load_hand_built_sparse_day_is_filled_like_the_dense_day():
    _, _, frame = read("load_nl_20260914_sparse_handbuilt.xml")
    assert_regular_times(frame, utc("2026-09-13 22:00"), 96)
    power = frame["power_mw"]
    # position p is row p - 1
    assert power.iloc[0] == 10377.306
    assert list(power.iloc[3:9]) == [10459.096] * 6  # position 4 listed, 5 to 9 omitted
    assert power.iloc[9] == 10397.556  # position 10 listed again
    assert list(power.iloc[59:89]) == [7518.166] * 30  # position 60 listed, 61 to 89 omitted
    assert list(power.iloc[89:96]) == [11278.126] * 7  # position 90 listed, 91 to 96 omitted


def test_load_sparse_and_dense_agree_wherever_the_sparse_file_lists_a_point():
    _, _, dense = read("load_nl_20260914_dense.xml")
    _, _, sparse = read("load_nl_20260914_sparse_handbuilt.xml")
    listed_rows = [p - 1 for p in [1, 2, 3, 4, *range(10, 61), 90]]
    assert list(sparse["date_utc"]) == list(dense["date_utc"])
    assert list(sparse["power_mw"].iloc[listed_rows]) == list(dense["power_mw"].iloc[listed_rows])


# Prices, A44


def test_price_day():
    created, revision, frame = read("price_nl_20260914.xml")
    assert created == "2026-09-16T04:32:15Z"
    assert revision == "1"
    assert list(frame.columns) == ["date_utc", "price_eur_per_mwh"]
    assert_regular_times(frame, utc("2026-09-13 22:00"), 96)
    assert list(frame["price_eur_per_mwh"].iloc[:3]) == [218.18, 205.79, 196.0]
    assert frame["price_eur_per_mwh"].iloc[-1] == 202.16


# Generation per production type, A75


GENERATION = "generation_nl_20260914.xml"
CODES_ON_THE_DAY = {"B01", "B04", "B05", "B11", "B14", "B16", "B17", "B18", "B19", "B20"}


def listed_points(code, direction_element):
    """Position to value, as listed in the XML, for the one series with this code and direction."""
    root = ET.parse(FIXTURES / GENERATION).getroot()
    ns = {"d": root.tag[1:].split("}")[0]}
    matches = [
        s
        for s in root.findall("d:TimeSeries", ns)
        if s.findtext("d:MktPSRType/d:psrType", namespaces=ns) == code
        and s.find(direction_element, ns) is not None
    ]
    assert len(matches) == 1
    points = matches[0].findall("d:Period/d:Point", ns)
    return {
        int(p.findtext("d:position", namespaces=ns)): float(p.findtext("d:quantity", namespaces=ns))
        for p in points
    }


def test_generation_is_split_into_generation_and_consumption():
    created, revision, groups = read(GENERATION)
    assert created == "2026-09-17T02:14:38Z"
    assert revision == "1"
    assert [label for label, _ in groups] == ["generation", "consumption"]
    for _, items in groups:
        assert len(items) == 10
        assert {code for code, _ in items} == CODES_ON_THE_DAY


def test_generation_frames_cover_the_day():
    _, _, groups = read(GENERATION)
    for _, items in groups:
        for _, frame in items:
            assert list(frame.columns) == ["date_utc", "power_mw"]
            assert_regular_times(frame, utc("2026-09-13 22:00"), 96)


@pytest.mark.parametrize(
    ("label", "element"),
    [
        ("generation", "d:inBiddingZone_Domain.mRID"),
        ("consumption", "d:outBiddingZone_Domain.mRID"),
    ],
)
def test_generation_values_follow_the_listed_points(label, element):
    """Listed values sit at their own positions; omitted positions repeat the last listed value."""
    _, _, groups = read(GENERATION)
    items = dict(groups)[label]
    for code, frame in items:
        listed = listed_points(code, element)
        current = None
        for position in range(1, 97):
            current = listed.get(position, current)
            assert frame["power_mw"].iloc[position - 1] == current, (label, code, position)


def test_generation_keeps_codes_it_has_never_seen(tmp_path):
    """A production type code outside the known list is passed through, not rejected."""
    text = (
        (FIXTURES / GENERATION)
        .read_text(encoding="utf-8")
        .replace("<psrType>B01</psrType>", "<psrType>B99</psrType>")
    )
    path = tmp_path / "generation_with_unknown_code.xml"
    path.write_text(text, encoding="utf-8")
    _, _, groups = my_parse.xml_reader(path)
    for _, items in groups:
        assert "B99" in {code for code, _ in items}


# Documents the parser does not read


def test_unsupported_document_type_is_reported_not_parsed(tmp_path):
    text = (
        (FIXTURES / "load_nl_20260914_dense.xml")
        .read_text(encoding="utf-8")
        .replace("<type>A65</type>", "<type>A99</type>")
    )
    path = tmp_path / "unsupported_type.xml"
    path.write_text(text, encoding="utf-8")
    out = my_parse.xml_reader(path)
    assert isinstance(out, str)
    assert "A99" in out
