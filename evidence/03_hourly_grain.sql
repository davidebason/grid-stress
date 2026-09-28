-- Why price is rolled up to the hour before it is profiled, and what that costs.
--
-- Establishes the three figures quoted under "Price is rolled up to the hour before it is
-- profiled" in DATA.md. Run against a database built by `python -m gridstress.load`:
--
--     duckdb data/processed/grid.duckdb -c ".read evidence/03_hourly_grain.sql"
--
-- Section 1 is the weighting a profile inherits if it groups market time units directly, since
-- an hour is one row before 2025-10-01 and four after. Section 2 is what the roll-up removes.

SET TimeZone = 'UTC';

CREATE OR REPLACE TEMP TABLE hourly_price AS
SELECT
    date_trunc('hour', date_utc)                          AS hour_utc,
    AVG(price_eur_per_mwh)                                AS price_eur_per_mwh,
    MAX(price_eur_per_mwh) - MIN(price_eur_per_mwh)       AS spread_within_hour,
    ANY_VALUE(resolution)                                 AS resolution,
    COUNT(*)                                              AS market_time_units
FROM fact_price
GROUP BY 1;

-- 1. The same statistic, computed over market time units and over hours. The two must be
--    grouped separately: averaging the hourly value over the fact rows would re-apply the very
--    weighting this is measuring, and the difference would cancel to zero.
--    Expect the largest gaps around midday, of the order of 10 EUR/MWh.
WITH over_units AS (
    SELECT d.hour_date AS hour_of_day, AVG(f.price_eur_per_mwh) AS mean_price
    FROM fact_price f
    JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
    GROUP BY 1
),
over_hours AS (
    SELECT d.hour_date AS hour_of_day, AVG(h.price_eur_per_mwh) AS mean_price
    FROM hourly_price h
    JOIN dim_time d ON h.hour_utc = d.date_utc
    GROUP BY 1
)
SELECT
    hour_of_day,
    ROUND(u.mean_price, 3)                AS mean_over_market_time_units,
    ROUND(h.mean_price, 3)                AS mean_over_hours,
    ROUND(u.mean_price - h.mean_price, 3) AS difference
FROM over_units u
JOIN over_hours h USING (hour_of_day)
ORDER BY ABS(u.mean_price - h.mean_price) DESC;

-- 2. What the roll-up removes: how much a price moves inside one hour, and where it can at all.
--    An hour published at PT60M has one value, so its spread is zero by construction.
--    Expect about 8,000 hours able to vary, averaging around 24 EUR/MWh, against 41,615 that
--    cannot.
SELECT
    resolution,
    COUNT(*)                                              AS hours,
    ROUND(AVG(spread_within_hour), 2)                     AS mean_spread_within_hour,
    ROUND(MAX(spread_within_hour), 2)                     AS max_spread_within_hour
FROM hourly_price
GROUP BY 1
ORDER BY 1;
