-- Run by `python -m gridstress.load`, inside its transaction, after 05_post_crisis.sql.
-- Also runnable by hand against an already-loaded database:
--
--     duckdb data/processed/grid.duckdb -c ".read sql/06_price_units.sql"
--
-- Day-ahead prices at the grain they were published at: one row per market time unit, hourly
-- through the local day 2025-09-30 and quarter-hourly from 2025-10-01. Every other derived table
-- averages a price into its hour, which is right for asking what an hour costs and wrong for
-- asking what a consumer able to move load inside an hour could escape. This table keeps the
-- units whole and attaches the local calendar to them, so an analysis file can work at either
-- grain without joining fact_price to dim_time itself. See "Day-ahead prices change from PT60M
-- to PT15M exactly once" in DATA.md.
--
-- Covered by validate.py, like everything the loader runs.

SET TimeZone = 'UTC';

-- unit_minutes is read off the resolution each series declared, not inferred from the date: the
-- change is a property of the published series, and DATA.md records that resolution has to be
-- read from the series rather than assumed. A resolution other than the two the range holds
-- comes out NULL, which validate.py refuses.
--
-- The join puts each unit in the hour it starts in, and through that hour in its Amsterdam
-- local day. The hour is UTC-aligned and the Amsterdam offset is always a whole number of hours,
-- so no unit straddles two local days.
CREATE OR REPLACE TABLE table_price_unit AS
SELECT
    f.date_utc,
    CASE f.resolution
        WHEN 'PT60M' THEN 60
        WHEN 'PT15M' THEN 15
    END AS unit_minutes,
    d.date_ams,
    d.hour_date,
    d.day_of_week,
    d.month_date,
    d.year_date,
    f.price_eur_per_mwh
FROM fact_price f
JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
;

-- 73,775 rows: 41,615 at 60 minutes ending 2025-09-30 and 32,160 at 15 minutes from 2025-10-01.
SELECT
    unit_minutes,
    COUNT(*)      AS units,
    MIN(date_ams) AS first_day,
    MAX(date_ams) AS last_day
FROM table_price_unit
GROUP BY unit_minutes
ORDER BY unit_minutes DESC
;
