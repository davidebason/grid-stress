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
-- so each count is reported beside its share of the group. The bar is drawn on the share for the
-- same reason: two bars of the same length mean the same thing in every statement below.
--
-- Ordered by the grouping key, not by the counts: only one column can control the row order, and
-- ordering by a count leaves every other column shapeless. The largest group is still visible as
-- the longest bar.
--
-- Deepest price in the hour and hourly price are absent: their per-group statistic is still open
-- in the analysis plan, and for the deepest price the choice decides whether it is a measurable
-- at all, since a median of it reports what the hourly price already said in 83.8% of hours.
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
    repeat('#', CAST(200.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(200.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar
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
    repeat('#', CAST(200.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(200.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar
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
    repeat('#', CAST(200.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(200.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar
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
    repeat('#', CAST(200.0 * COUNT(*) FILTER (WHERE price_neg)     / COUNT(*) AS INT)) AS neg_bar,
    repeat('.', CAST(200.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*) AS INT)) AS ext_bar
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
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct
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
    ROUND(100.0 * COUNT(*) FILTER (WHERE extreme_price) / COUNT(*), 2) AS ext_pct
FROM table_h_price_load
GROUP BY month_date, hour_date
ORDER BY month_date, hour_date
;
