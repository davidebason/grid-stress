-- The three fact tables, one per dataset, each covering the whole range from the raw responses in
-- data/raw. Grains, and the reasoning behind them, are in DATA.md.
--
--   fact_load        one row per market time unit
--   fact_generation  one row per market time unit, production type and direction
--   fact_price       one row per market time unit
--
-- date_utc is the instant the market time unit begins, in UTC. Local Amsterdam labels are derived
-- later, in the time dimension, so that the 23-hour and 25-hour local days are handled once.
--
-- Load and generation are quarter-hourly throughout the range, so their rows are all one quarter
-- hour. Prices are hourly through the local day 2025-09-30 and quarter-hourly from 2025-10-01, so
-- fact_price carries the resolution of each row: without it, a count of rows is not a count of
-- comparable things.
--
-- direction is 'in' or 'out', naming which of inBiddingZone_Domain or outBiddingZone_Domain an
-- A75 series carries. Those mean generation and consumption respectively, but the column keeps
-- the document's own distinction rather than the interpretation, as the psrType codes do. See
-- DATA.md for what the two mean and how far that reading is established.
--
-- The last four columns of each table are provenance: which raw file a row was parsed from, the
-- day it was fetched, and the document's own createdDateTime and revisionNumber. ENTSO-E restates
-- published data, so a row count is only reproducible against a stated fetch.

CREATE OR REPLACE TABLE fact_load (
    date_utc TIMESTAMPTZ PRIMARY KEY,
    load_mw DOUBLE,
    source_file VARCHAR,
    fetched_on DATE,
    created_utc TIMESTAMPTZ,
    revision INTEGER
);

CREATE OR REPLACE TABLE fact_generation (
    date_utc TIMESTAMPTZ,
    psr_type VARCHAR,
    direction VARCHAR,
    power_mw DOUBLE,
    source_file VARCHAR,
    fetched_on DATE,
    created_utc TIMESTAMPTZ,
    revision INTEGER,
    PRIMARY KEY (date_utc, psr_type, direction)
);

CREATE OR REPLACE TABLE fact_price (
    date_utc TIMESTAMPTZ PRIMARY KEY,
    resolution VARCHAR,
    price_eur_per_mwh DOUBLE,
    source_file VARCHAR,
    fetched_on DATE,
    created_utc TIMESTAMPTZ,
    revision INTEGER
);