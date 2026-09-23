-- The project range, as Amsterdam local midnights expressed in UTC: the local days 2021-01-01 to
-- 2026-08-31, matching RANGE_BEGIN and RANGE_END in src/gridstress/fetch.py. generate_series
-- includes both endpoints, so the last row is the last hour that BEGINS inside the range,
-- 2026-08-31 21:00Z, one hour before the range's exclusive end of 2026-08-31 22:00Z. 49,655 rows.

CREATE OR REPLACE TABLE dim_time AS
WITH date_ams_table AS (
    SELECT
    date_utc,
    CAST(date_utc AT TIME ZONE 'Europe/Amsterdam' AS DATE) AS date_ams
    FROM generate_series(
        TIMESTAMPTZ '2020-12-31 23:00:00+00',
        TIMESTAMPTZ '2026-08-31 21:00:00+00',
        INTERVAL 1 HOUR
    ) AS g(date_utc)
)
SELECT
    date_utc,
    date_ams,
    EXTRACT(hour FROM date_utc AT TIME ZONE 'Europe/Amsterdam') AS hour_date,
    dayname(date_ams) AS day_of_week,
    EXTRACT(month FROM date_ams) AS month_date,
    EXTRACT(year FROM date_ams) AS year_date
FROM date_ams_table;