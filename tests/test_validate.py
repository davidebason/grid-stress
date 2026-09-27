"""Tests for the load invariants, against a small database built from the recorded fixtures.

CI never sees data/raw, which is gitignored, so these tests build their own database: the three
files in sql/ followed by five fixture documents inserted through the same statements
load.py uses. It is the real schema and the real insert path over a few thousand rows.

Each check in validate.CHECKS gets a corruption that should make it fire, and a test that it
does. A check nothing can break is not a check, so the parametrised list is also an inventory:
adding a rule without adding a corruption for it fails test_every_check_has_a_corruption.
"""

from datetime import date
from pathlib import Path

import duckdb
import pytest

from gridstress import load, my_parse, validate

FIXTURES = Path(__file__).parent / "fixtures"
SQL_DIR = Path(__file__).resolve().parents[1] / "sql"

# One fixture per document type, plus both clock-change days. The hand-built sparse load file is
# left out because it covers the same day as the dense one and would collide on the primary key.
DOCUMENTS = [
    ("load_nl_20260914_dense.xml", "a65"),
    ("load_nl_20260329_dst_spring.xml", "a65"),
    ("load_nl_20251026_dst_autumn.xml", "a65"),
    ("price_nl_20260914.xml", "a44"),
    ("generation_nl_20260914.xml", "a75"),
]


# The fixtures were recorded on 2026-09-16 and 2026-09-17, a fortnight after the fetch range ends
# on 2026-08-31, so the real dim_time holds no rows for the days they cover. The test database
# therefore runs 03_dim_time.sql with its end boundary moved, changing nothing else: the hours are
# still derived by the file under test rather than restated here.
DIM_TIME_END = "TIMESTAMPTZ '2026-08-31 21:00:00+00'"
DIM_TIME_END_FOR_FIXTURES = "TIMESTAMPTZ '2026-09-14 21:00:00+00'"


def build(documents=DOCUMENTS, extra=None):
    """A fresh in-memory database: the real schema, then these documents inserted as load does."""
    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    for name in load.SQL_SCHEMA:
        sql_file = SQL_DIR / name
        sql = sql_file.read_text()
        if name == "03_dim_time.sql":
            assert sql.count(DIM_TIME_END) == 1
            sql = sql.replace(DIM_TIME_END, DIM_TIME_END_FOR_FIXTURES)
        con.execute(sql)

    for path, document_type in list(documents) + list(extra or []):
        _, _, df = my_parse.xml_reader(FIXTURES / path if isinstance(path, str) else path)
        df["source_file"] = Path(path).name
        df["fetched_on"] = date(2026, 9, 17)
        df["created_utc"] = "2026-09-17T00:00:00Z"
        df["revision"] = "1"
        con.execute(load.DICT_SQL[document_type])
    return con


@pytest.fixture
def con():
    return build()


def test_the_fixture_database_is_clean(con):
    assert validate.failures(con) == {}
    validate.validate(con)


def test_the_fixture_database_holds_what_it_should(con):
    counts = {
        table: con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        for table in (
            "dim_production_type",
            "dim_time",
            "fact_load",
            "fact_price",
            "fact_generation",
        )
    }
    assert counts["dim_production_type"] == 20
    assert counts["dim_time"] == 49_655 + 14 * 24  # the range, plus the fixture fortnight
    assert counts["fact_load"] == 96 + 92 + 100  # dense day, spring day, autumn day
    assert counts["fact_price"] == 96
    assert counts["fact_generation"] == 20 * 96  # 10 types, both directions


# Each rule, and a corruption that must make it fire.

CORRUPTIONS = {
    "dim_time: one row per hour of each local day, as the zone database defines it": (
        "DELETE FROM dim_time WHERE date_utc = (SELECT MIN(date_utc) FROM dim_time)"
    ),
    "dim_time: no gap in the hourly grid": (
        "DELETE FROM dim_time WHERE date_utc = TIMESTAMPTZ '2023-06-15 12:00:00+00'"
    ),
    "fact_load: no null value": (
        "UPDATE fact_load SET load_mw = NULL WHERE date_utc = (SELECT MIN(date_utc) FROM fact_load)"
    ),
    "fact_price: no null value": (
        "UPDATE fact_price SET price_eur_per_mwh = NULL "
        "WHERE date_utc = (SELECT MIN(date_utc) FROM fact_price)"
    ),
    "fact_generation: no null value": (
        "UPDATE fact_generation SET power_mw = NULL "
        "WHERE date_utc = (SELECT MIN(date_utc) FROM fact_generation)"
    ),
    "fact_load: load is not negative": (
        "UPDATE fact_load SET load_mw = -1 WHERE date_utc = (SELECT MIN(date_utc) FROM fact_load)"
    ),
    "fact_generation: output is not negative": (
        "UPDATE fact_generation SET power_mw = -1 "
        "WHERE date_utc = (SELECT MIN(date_utc) FROM fact_generation)"
    ),
    "fact_price: every price is within the bounds in force when it cleared": (
        "UPDATE fact_price SET price_eur_per_mwh = 9999 "
        "WHERE date_utc = (SELECT MIN(date_utc) FROM fact_price)"
    ),
    "fact_generation: no production type out-produces the highest load ever recorded": (
        "UPDATE fact_generation SET power_mw = "
        "(SELECT MAX(load_mw) FROM fact_load) + 1 WHERE psr_type = 'B04'"
    ),
    "fact_generation: direction is only 'in' or 'out'": (
        "UPDATE fact_generation SET direction = 'sideways' WHERE direction = 'in'"
    ),
    "fact_generation: every production type is in the dimension": (
        "UPDATE fact_generation SET psr_type = 'B99' WHERE psr_type = 'B16'"
    ),
    "fact tables: every hour used is an hour dim_time holds": (
        "INSERT INTO fact_load (date_utc, load_mw) "
        "VALUES (TIMESTAMPTZ '2019-01-01 00:00:00+00', 1.0)"
    ),
}


def test_every_check_has_a_corruption():
    assert set(CORRUPTIONS) == set(validate.CHECKS)


@pytest.mark.parametrize("rule", list(CORRUPTIONS))
def test_each_check_fires_when_its_rule_is_broken(con, rule):
    assert rule not in validate.failures(con)
    con.execute(CORRUPTIONS[rule])
    assert rule in validate.failures(con)
    with pytest.raises(validate.ValidationError, match="checks failed"):
        validate.validate(con)


# The price bound is the one rule that is not a constant.


@pytest.mark.parametrize(
    ("when", "accepted"),
    [
        ("2026-06-01 12:00:00+00", True),  # after the floor moved to -600
        ("2026-05-01 12:00:00+00", False),  # before it, where -550 could not have cleared
    ],
)
def test_the_price_floor_follows_the_date(con, when, accepted):
    con.execute(
        "INSERT INTO fact_price (date_utc, resolution, price_eur_per_mwh) "
        f"VALUES (TIMESTAMPTZ '{when}', 'PT60M', -550.0)"
    )
    rule = "fact_price: every price is within the bounds in force when it cleared"
    assert (rule not in validate.failures(con)) is accepted


# The deliberately corrupted fixture.


def test_a_corrupted_fixture_is_rejected(tmp_path):
    """A load document with a negative quantity must not reach a committed database."""
    text = (FIXTURES / "load_nl_20260914_dense.xml").read_text(encoding="utf-8")
    assert "<quantity>10377.306</quantity>" in text
    corrupted = tmp_path / "load_nl_20260914_negative.xml"
    corrupted.write_text(
        text.replace("<quantity>10377.306</quantity>", "<quantity>-10377.306</quantity>")
    )

    con = build(documents=[], extra=[(corrupted, "a65")])
    with pytest.raises(validate.ValidationError, match="load is not negative"):
        validate.validate(con)
