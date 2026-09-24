"""Load the fetched ENTSO-E responses into DuckDB.

Reads every response in data/raw/, parses it with my_parse, and inserts the rows into the three
fact tables declared in sql/pre_load/: fact_load, fact_generation and fact_price. Every row
carries the four provenance columns, so any figure can be traced back to the file it came from
and the day that file was fetched.

No modelling decisions are made here. The grain, the keys and the dimensions are settled in
sql/pre_load/, which runs first; this module only moves parsed rows into the tables those files
declare. See DATA.md for provenance and the reasoning behind the model.

A program, not a library: run it with `python -m gridstress.load`.
"""

import logging
import time
from datetime import datetime
from pathlib import Path

import duckdb

from gridstress import my_parse, validate

logger = logging.getLogger(__name__)

DICT_SQL = {
    "a44": """
        INSERT INTO fact_price
            (date_utc, resolution, price_eur_per_mwh,
             source_file, fetched_on, created_utc, revision)
        SELECT date_utc, resolution, price_eur_per_mwh,
               source_file, fetched_on, created_utc, revision
        FROM df
    """,
    "a65": """
        INSERT INTO fact_load
            (date_utc, load_mw,
             source_file, fetched_on, created_utc, revision)
        SELECT date_utc, load_mw,
               source_file, fetched_on, created_utc, revision
        FROM df
    """,
    "a75": """
        INSERT INTO fact_generation
            (date_utc, psr_type, direction, power_mw,
             source_file, fetched_on, created_utc, revision)
        SELECT date_utc, psr_type, direction, power_mw,
               source_file, fetched_on, created_utc, revision
        FROM df
    """,
}


def main() -> None:
    """Rebuild every table from the responses in data/raw/.

    Runs the declarations in sql/pre_load/ first, then inserts one file at a time inside a single
    transaction, so a run that fails part way leaves no partial load behind.
    """

    # Log configuration
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    # General paths.
    project_root = Path(__file__).resolve().parents[2]
    raw = project_root / "data" / "raw"
    db_path = project_root / "data" / "processed" / "grid.duckdb"
    sql_dir = project_root / "sql" / "pre_load"

    # Make directories if missing.
    db_path.parent.mkdir(parents=True, exist_ok=True)

    # Paths for the documents to be loaded.
    path_list = [path for path in sorted(raw.glob("*.xml"))]
    if len(path_list) == 0:
        logger.warning("there is no file in %s", raw)

    # Start loading SQL tables.
    con = duckdb.connect(db_path)
    con.execute("SET TimeZone = 'UTC'")
    con.execute((sql_dir / "01_dim_production_type.sql").read_text())
    con.execute((sql_dir / "02_facts.sql").read_text())
    con.execute((sql_dir / "03_dim_time.sql").read_text())

    # Add data to the SQL tables.
    t0 = time.time()
    con.execute("BEGIN TRANSACTION")
    try:
        for path in path_list:
            t = time.time()

            source_file = path.name
            fetched_on = datetime.strptime(
                path.stem.split("_")[3].removeprefix("fetched"), "%Y%m%d"
            ).date()
            created_time, revision_number, df = my_parse.xml_reader(path)

            df["source_file"] = source_file
            df["fetched_on"] = fetched_on
            df["created_utc"] = created_time
            df["revision"] = revision_number

            con.execute(DICT_SQL[path.stem.split("_")[0]])
            logger.info(
                "parsed and inserted %s rows from %s in %.1fs",
                f"{len(df):,}",
                source_file,
                time.time() - t,
            )

        # Inside the transaction, so a database that breaks an invariant is never committed.
        validate.validate(con)

    except Exception:
        con.execute("ROLLBACK")
        raise
    else:
        con.execute("COMMIT")
        # Table names come from the literal tuple below, never from input, so interpolating
        # them into the query is safe.
        for table in (
            "dim_production_type",
            "dim_time",
            "fact_load",
            "fact_price",
            "fact_generation",
        ):
            rows = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            logger.info("rows in %s: %s", table, f"{rows:,}")
        logger.info("done in %.0fs", time.time() - t0)


if __name__ == "__main__":
    main()
