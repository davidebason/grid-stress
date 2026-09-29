-- Run by `python -m gridstress.load`, inside its transaction, after 04_hourly_tables.sql.
-- Also runnable by hand against an already-loaded database:
--
--     duckdb data/processed/grid.duckdb -c ".read sql/05_post_crisis.sql"
--
-- The same hourly table restricted to the period after the 2021-2022 gas-market event, so a
-- profile that collapses the year is not measuring when the crisis happened. Starting at
-- 2023-03-01 rather than cutting a band out of the middle keeps the period contiguous: a hole
-- in the range would make any month-on-month or year-on-year reading discontinuous, and the
-- eight clean months of early 2021 are not worth that. See "The 2021 and 2022 price level is a
-- gas-market event" in DATA.md and evidence/07_extreme_price_period.sql for the boundary.
--
-- Covered by validate.py, like everything the loader runs.

SET TimeZone = 'UTC';

-- The boundary is an Amsterdam local date, so the filter is on date_ams: the equivalent UTC
-- instant differs by an hour either side of a clock change, and dim_time already absorbed that.
CREATE OR REPLACE TABLE table_h_price_post AS
SELECT *
FROM table_h_price_load
WHERE date_ams >= DATE '2023-03-01'
;

-- extreme_price is carried over unchanged: it still flags an hourly mean above 225.00 EUR/MWh,
-- the 0.9 quantile of the WHOLE range. This table filters, it does not redefine. Recomputing the
-- quantile over this period alone would give a much lower bar and would make a tenth of these
-- hours extreme by construction, which is a different question. Left as a decision, not assumed.
SELECT
    COUNT(*) AS hours,
    MIN(date_ams) AS first_day,
    MAX(date_ams) AS last_day,
    COUNT(*) FILTER (WHERE price_neg) AS negative_hours,
    COUNT(*) FILTER (WHERE extreme_price) AS extreme_hours,
    ROUND(MEDIAN(avg_h_price), 1) AS median_price
FROM table_h_price_post
;
