-- Q1_NEG_EXT. How often are prices negative or extreme, and when.
--
-- Measurables: negative hour, extreme hour, deepest price in the hour, hourly price.
-- Reads: table_h_price_load.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/01_negative_and_extreme.sql"

SET TimeZone = 'UTC';

-- ---------------------------------------------------------------------------------------------
-- One statement per granularity. Counts alone are not comparable across granularities because the
-- groups are different sizes -- 172 hours in a G_HOUR_MONTH group against 7,094 in a G_DOW one --
-- so each count is reported beside its share of the group. The bars are drawn on the share, one
-- character per percentage point, so a bar of the same length means the same thing in every
-- statement below and its length can be read as the number.
--
-- price_bar is drawn from 60 EUR/MWh rather than from zero, one character per 5 above it. The
-- median hourly price never falls below 69 or rises above 132 at any granularity, so a bar from
-- zero would spend seven of its thirteen characters on ground every group shares: at G_DOW it
-- varied by a single character across the whole week. The baseline is fixed rather than fitted
-- per statement, so these bars stay comparable between statements like the other two.
--
-- Ordered by the grouping key, not by the counts: only one column can control the row order, and
-- ordering by a count leaves every other column shapeless. The largest group is still visible as
-- the longest bar.
--
-- Hourly price is reported as the median of the group, not the mean: the 2021-2022 price level
-- drags every mean up, by 6 EUR/MWh on Sunday and 26 on Tuesday, so the two rank the days
-- differently over the whole range.
--
-- Deepest price in the hour is reported as the 5th percentile of the group, not its median and
-- not its minimum. A median returns what the hourly price already said, the two columns holding
-- the same number in 83.8% of hours because one published price per hour makes min, mean and max
-- identical before 2025-10-01. A minimum is one observation and does not improve with group
-- size: at G_HOUR it tracks the midday block where negatives happen, but at G_DOW it is one
-- print in 7,094 and reads Friday -499.6 against Tuesday -79.2, with no trace of the weekend
-- pattern every other column shows. The 5th percentile keeps that pattern at both.
-- ---------------------------------------------------------------------------------------------

-- G_HOUR: hour of day within the dataset. 24 groups, about 2,069 hours in each.
-- Expected rows: 24.
SELECT
    hour_date,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep,
    repeat('#', CAST(200.0 * COUNT(*) FILTER (WHERE price_neg)     / (2*COUNT(*)) AS INT)) AS neg_bar,
    repeat('.', CAST(200.0 * COUNT(*) FILTER (WHERE extreme_price) / (2*COUNT(*)) AS INT)) AS ext_bar,
    repeat('+', CAST(GREATEST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price) - 60, 0)
                     / 5 AS INT)) AS price_bar
FROM table_h_price_load
GROUP BY hour_date
ORDER BY hour_date
;

-- G_DOW: day of week within the dataset. 7 groups, about 7,094 hours in each.
-- Expected rows: 7.
SELECT
    day_of_week,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep,
    repeat('#', CAST(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar,
    repeat('+', CAST(GREATEST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price) - 60, 0)
                     / 5 AS INT)) AS price_bar
FROM table_h_price_load
GROUP BY day_of_week
ORDER BY day_of_week
;

-- G_MONTH: month within the dataset. 12 groups, about 4,138 hours in each.
-- Expected rows: 12.
SELECT
    month_date,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep,
    repeat('#', CAST(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar,
    repeat('+', CAST(GREATEST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price) - 60, 0)
                     / 5 AS INT)) AS price_bar
FROM table_h_price_load
GROUP BY month_date
ORDER BY month_date
;

-- G_YEAR: year within the dataset. 6 groups, about 8,712 hours in each.
-- Expected rows: 6.
SELECT
    year_date,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep,
    repeat('#', CAST(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar,
    repeat('+', CAST(GREATEST(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price) - 60, 0)
                     / 5 AS INT)) AS price_bar
FROM table_h_price_load
GROUP BY year_date
ORDER BY year_date
;

-- G_MONTH_YEAR: month within year. 68 groups, about 730 hours in each. No bars: at 68 rows
-- there is no glance to take one in, and the notebook draws this one as a heatmap.
-- Expected rows: 68.
SELECT
    year_date, month_date,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep
FROM table_h_price_load
GROUP BY year_date, month_date
ORDER BY year_date, month_date
;

-- G_HOUR_MONTH: hour within month. 288 groups, about 172 hours in each. No bars, as above.
-- Expected rows: 288.
SELECT
    month_date, hour_date,
    COUNT(*)                                          AS hours,
    COUNT(*) FILTER (WHERE price_neg)                 AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*), 2) AS neg_pct,
    COUNT(*) FILTER (WHERE extreme_price)             AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY avg_h_price), 2) AS med_h_p,
    ROUND(PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY min_price), 2) AS p05_deep
FROM table_h_price_load
GROUP BY month_date, hour_date
ORDER BY month_date, hour_date
;

-----------------------------------------------------------
    
-- ---------------------------------------------------------------------------------------------
-- When in the day and the year a consumer meets each end of the price, in the coarse blocks the
-- memo states. The negative hours split by season, March to September against October to
-- February, and by time of day: midday 10:00 to 16:59, night 00:00 to 06:59, and the rest. This
-- is G_HOUR_MONTH coarsened, so it reads one grouping, not two.
-- Expected rows: 6.
SELECT
    CASE WHEN month_date IN (10, 11, 12, 1, 2) THEN 'Oct-Feb' ELSE 'Mar-Sep' END AS season,
    CASE WHEN hour_date BETWEEN 10 AND 16 THEN 'midday 10-16'
         WHEN hour_date BETWEEN 0 AND 6   THEN 'night 0-6'
         ELSE 'other' END                                                       AS time_of_day,
    COUNT(*)                                                                    AS hours,
    COUNT(*) FILTER (WHERE price_neg)                                           AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg) / COUNT(*), 2)              AS neg_pct
FROM table_h_price_load
GROUP BY season, time_of_day
ORDER BY season, time_of_day
;

-- The extreme hours since 2023, by hour, day of week and month. Over the whole range 4,055 of
-- the 4,956 extreme hours fall in 2022, so every whole-range profile of extremes above is
-- mostly the shape of the gas crisis. These three show the shape a consumer meets now.
-- Expected rows: 24, 7, 12.
SELECT
    hour_date,
    COUNT(*) FILTER (WHERE extreme_price)                                       AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2)          AS ext_pct
FROM table_h_price_load
WHERE year_date >= 2023
GROUP BY hour_date
ORDER BY hour_date
;

SELECT
    day_of_week,
    COUNT(*) FILTER (WHERE extreme_price)                                       AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2)          AS ext_pct
FROM table_h_price_load
WHERE year_date >= 2023
GROUP BY day_of_week
ORDER BY day_of_week
;

SELECT
    month_date,
    COUNT(*) FILTER (WHERE extreme_price)                                       AS ext,
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2)          AS ext_pct
FROM table_h_price_load
WHERE year_date >= 2023
GROUP BY month_date
ORDER BY month_date
;

-- G_YEAR over January to August only. The range ends on 2026-08-31, so 2026 is eight months
-- long, and those months hold most of a year's negative hours: a partial 2026 set against full
-- years overstates it. This compares every year over the months 2026 has.
-- Expected rows: 6.
SELECT
    year_date,
    COUNT(*)                                                                    AS hours,
    COUNT(*) FILTER (WHERE price_neg)                                           AS neg,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg) / COUNT(*), 2)              AS neg_pct
FROM table_h_price_load
WHERE month_date <= 8
GROUP BY year_date
ORDER BY year_date
;
