-- Where the extreme-price bar comes from, and how the hours it selects are distributed.
--
-- Establishes every figure quoted under "A negative hour and an extreme hour are two separate
-- flags" in DATA.md. Run against a database built by `python -m gridstress.load`:
--
--     duckdb data/processed/grid.duckdb -c ".read analysis/00_extreme_price.sql"
--
-- Numbered 00 because it answers a question asked before the hourly tables are built, and is
-- deliberately self-contained: it reads the fact tables rather than table_h_price_load, so the
-- bar can be checked without first running sql/04_hourly_tables.sql.
--
-- Section 1 is the bar itself. Section 2 shows why the quantile is taken over hourly means
-- rather than over market time units. Section 3 is the distribution of the hours it selects.

SET TimeZone = 'UTC';

-- One row per hour, the mean of that hour's market time units. This is the population the
-- quantile is taken over: see "Price is rolled up to the hour before it is profiled" in DATA.md.
CREATE OR REPLACE TEMP TABLE hourly_price AS
SELECT d.date_utc, d.year_date, AVG(f.price_eur_per_mwh) AS avg_h_price
FROM fact_price f JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
GROUP BY 1, 2;

-- 1. The bar. 225.00 EUR/MWh.
SELECT quantile_cont(avg_h_price, 0.9) AS extreme_price_value FROM hourly_price;

-- 2. Why the population matters. Taken over market time units the bar is 27.38 EUR/MWh lower,
-- because the quarter-hourly years contribute four rows per hour instead of one and those years
-- are the cheap ones. Within either period alone the two agree, which is what shows the gap comes
-- from mixing resolutions rather than from the choice of statistic.
SELECT
    'whole range'                                                        AS period,
    (SELECT quantile_cont(price_eur_per_mwh, 0.9) FROM fact_price)       AS over_market_time_units,
    (SELECT quantile_cont(avg_h_price, 0.9) FROM hourly_price)           AS over_hourly_means
UNION ALL
SELECT
    'hourly price only',
    (SELECT quantile_cont(price_eur_per_mwh, 0.9) FROM fact_price
     WHERE date_utc < TIMESTAMPTZ '2025-09-30 22:00:00+00'),
    (SELECT quantile_cont(avg_h_price, 0.9) FROM hourly_price
     WHERE date_utc < TIMESTAMPTZ '2025-09-30 22:00:00+00')
UNION ALL
SELECT
    'quarter-hourly price only',
    (SELECT quantile_cont(price_eur_per_mwh, 0.9) FROM fact_price
     WHERE date_utc >= TIMESTAMPTZ '2025-09-30 22:00:00+00'),
    (SELECT quantile_cont(avg_h_price, 0.9) FROM hourly_price
     WHERE date_utc >= TIMESTAMPTZ '2025-09-30 22:00:00+00');

-- 3. How the selected hours fall by year. A fixed bar lets the years differ, which is the point
-- of fixing it, and here they differ a great deal: 4,055 of the 4,956 extreme hours are in 2022.
SELECT
    year_date AS year,
    COUNT(*) AS all_hours,
    COUNT(*) FILTER (
        WHERE avg_h_price > (SELECT quantile_cont(avg_h_price, 0.9) FROM hourly_price)
    ) AS extreme_hours
FROM hourly_price
GROUP BY 1
ORDER BY 1;
