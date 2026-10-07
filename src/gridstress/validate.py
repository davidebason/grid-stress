"""Invariants the loaded tables must satisfy, checked before a load is committed.

Each check is a query that must return no rows. A row it returns is a counterexample, so the
error message can name the table, the rule and how many rows broke it. `validate` runs every
check and raises once with all the failures rather than stopping at the first, because a load
that breaks one invariant usually breaks several and seeing them together says more.

The rules come from DATA.md: the bounds SDAC applies to a clearing price, the directions an A75
series can carry, the production type code list, and the hours an Amsterdam local day has. The
upper bound on generation is the one rule with no published source behind it, so it is set by the
data itself: a single production type cannot plausibly out-produce the highest load the country
ever recorded, and the bound moves with the load table rather than sitting as a constant. That
rule no longer discovers anything, because `load.py` deletes the rows breaking it before calling
this module; it stays so the deletion is confirmed rather than assumed, and so the bound is
written down beside the other rules. None of them is a property of the current data;
they are properties the data must keep having after a refetch, a parser change or a fourth
dataset.

`load.py` calls this inside its transaction, after the derived tables are built, so a failure
rolls the whole load back and leaves the previous database untouched. The checks therefore cover
both what the API sent and what was derived from it: a derived table that disagrees with the
facts beneath it never reaches the file.
"""

import duckdb

# Delivery day 2026-05-29 Amsterdam local, the first day the SDAC minimum clearing price was
# -600 rather than -500. See "Day-ahead prices have a floor and a ceiling, and the floor moved"
# in DATA.md.
FLOOR_MOVED = "2026-05-28 22:00:00+00"
FLOOR_BEFORE, FLOOR_AFTER, CEILING = -500, -600, 4000

CHECKS = {
    "dim_time: one row per hour of each local day, as the zone database defines it": """
        SELECT date_ams, COUNT(*) AS rows_held
        FROM dim_time
        GROUP BY date_ams
        HAVING COUNT(*) <> date_diff(
            'hour',
            CAST(date_ams AS TIMESTAMP) AT TIME ZONE 'Europe/Amsterdam',
            CAST(date_ams + INTERVAL 1 DAY AS TIMESTAMP) AT TIME ZONE 'Europe/Amsterdam'
        )
    """,
    "dim_time: no gap in the hourly grid": """
        SELECT date_utc, next_utc FROM (
            SELECT date_utc, LEAD(date_utc) OVER (ORDER BY date_utc) AS next_utc FROM dim_time
        ) WHERE next_utc IS NOT NULL AND next_utc <> date_utc + INTERVAL 1 HOUR
    """,
    "fact_load: no null value": "SELECT date_utc FROM fact_load WHERE load_mw IS NULL",
    "fact_price: no null value": "SELECT date_utc FROM fact_price WHERE price_eur_per_mwh IS NULL",
    "fact_generation: no null value": "SELECT date_utc FROM fact_generation WHERE power_mw IS NULL",
    "fact_load: load is not negative": "SELECT date_utc, load_mw FROM fact_load WHERE load_mw < 0",
    "fact_generation: output is not negative": """
        SELECT date_utc, psr_type, direction, power_mw FROM fact_generation WHERE power_mw < 0
    """,
    "fact_price: every price is within the bounds in force when it cleared": f"""
        SELECT date_utc, price_eur_per_mwh FROM fact_price
        WHERE price_eur_per_mwh > {CEILING}
           OR price_eur_per_mwh < CASE
                  WHEN date_utc >= TIMESTAMPTZ '{FLOOR_MOVED}' THEN {FLOOR_AFTER}
                  ELSE {FLOOR_BEFORE}
              END
    """,
    "fact_generation: no production type out-produces the highest load ever recorded": """
        SELECT date_utc, psr_type, direction, power_mw FROM fact_generation
        WHERE power_mw > (SELECT MAX(load_mw) FROM fact_load)
    """,
    "fact_generation: direction is only 'in' or 'out'": """
        SELECT DISTINCT direction FROM fact_generation WHERE direction NOT IN ('in', 'out')
    """,
    "fact_generation: every production type is in the dimension": """
        SELECT DISTINCT f.psr_type FROM fact_generation f
        LEFT JOIN dim_production_type d USING (psr_type)
        WHERE d.psr_type IS NULL
    """,
    "table_h_price_load: one row per hour, never two": """
        SELECT date_utc FROM table_h_price_load GROUP BY date_utc HAVING COUNT(*) <> 1
    """,
    "table_h_price_load: the two event flags are disjoint": """
        SELECT date_utc FROM table_h_price_load WHERE price_neg AND extreme_price
    """,
    "table_composition: shares sum to one in every hour": """
        SELECT date_utc, ROUND(SUM(share_h), 6) AS total
        FROM table_composition GROUP BY date_utc HAVING ROUND(SUM(share_h), 6) <> 1.0
    """,
    "table_composition: one row per hour per production type": """
        SELECT date_utc, psr_type FROM table_composition
        GROUP BY date_utc, psr_type HAVING COUNT(*) <> 1
    """,
    "b20_thermal_table: one row per Amsterdam local day": """
        SELECT date_ams FROM b20_thermal_table GROUP BY date_ams HAVING COUNT(*) <> 1
    """,
    "table_h_price_post: every row is a row of the hourly table": """
        SELECT p.date_utc FROM table_h_price_post p
        LEFT JOIN table_h_price_load h USING (date_utc)
        WHERE h.date_utc IS NULL
    """,
    "table_h_price_post: nothing before the boundary it is defined by": """
        SELECT date_ams FROM table_h_price_post WHERE date_ams < DATE '2023-03-01'
    """,
    "table_price_unit: every published price appears exactly once": """
        SELECT f.date_utc FROM fact_price f
        LEFT JOIN (
            SELECT date_utc, COUNT(*) AS copies FROM table_price_unit GROUP BY date_utc
        ) t USING (date_utc)
        WHERE t.copies IS DISTINCT FROM 1
    """,
    "table_price_unit: each local day is priced whole, at one known resolution": """
        SELECT date_ams, COUNT(*) AS units FROM table_price_unit
        GROUP BY date_ams
        HAVING BOOL_OR(unit_minutes IS NULL)
            OR COUNT(DISTINCT unit_minutes) <> 1
            OR COUNT(*) * MIN(unit_minutes) <> 60 * date_diff(
                'hour',
                CAST(date_ams AS TIMESTAMP) AT TIME ZONE 'Europe/Amsterdam',
                CAST(date_ams + INTERVAL 1 DAY AS TIMESTAMP) AT TIME ZONE 'Europe/Amsterdam'
            )
    """,
    "fact tables: every hour used is an hour dim_time holds": """
        SELECT h FROM (
            SELECT DISTINCT date_trunc('hour', date_utc) AS h FROM fact_load
            UNION SELECT DISTINCT date_trunc('hour', date_utc) FROM fact_price
            UNION SELECT DISTINCT date_trunc('hour', date_utc) FROM fact_generation
        ) f
        LEFT JOIN dim_time d ON d.date_utc = f.h
        WHERE d.date_utc IS NULL
    """,
}


class ValidationError(Exception):
    """Raised when a loaded table breaks an invariant recorded in DATA.md."""


def failures(con: duckdb.DuckDBPyConnection) -> dict[str, int]:
    """Run every check and return the failing ones, with how many rows broke each."""
    found = {}
    for rule, sql in CHECKS.items():
        offending = con.execute(f"SELECT COUNT(*) FROM ({sql})").fetchone()[0]
        if offending:
            found[rule] = offending
    return found


def validate(con: duckdb.DuckDBPyConnection) -> None:
    """Raise ValidationError naming every invariant the database breaks, or return quietly."""
    found = failures(con)
    if found:
        lines = "\n".join(f"  {rows:>10,} rows  {rule}" for rule, rows in found.items())
        raise ValidationError(f"{len(found)} of {len(CHECKS)} checks failed:\n{lines}")
