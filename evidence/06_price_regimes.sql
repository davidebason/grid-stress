-- The price level by year, the 2021-2022 rise month by month, and what grew alongside the
-- negative hours.
--
-- Establishes the figures quoted under "The 2021 and 2022 price level is a gas-market event" and
-- "Negative hours rise across the range, and this source cannot attribute the rise" in DATA.md.
-- Run against a database built by `python -m gridstress.load` followed by sql/04_hourly_tables.sql:
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read evidence/06_price_regimes.sql"
--
-- Section 1 is the yearly price level against the two event flags. Section 2 is the month-by-month
-- rise and fall through 2021 and 2022. Section 3 is the mean output of each production type that
-- bears on the negative-hour question, per year, with B16's annual peak beside it.

SET TimeZone = 'UTC';

-- 1. Price level and event counts per year. 2026 is a partial year, 5,831 hours against 8,760,
-- so its counts are comparable only as a rate.
SELECT
    year_date AS year,
    COUNT(*) AS hours,
    ROUND(MEDIAN(avg_h_price), 1) AS median_price,
    COUNT(*) FILTER (WHERE price_neg) AS negative_hours,
    COUNT(*) FILTER (WHERE extreme_price) AS extreme_hours,
    ROUND(100.0 * COUNT(*) FILTER (WHERE price_neg) / COUNT(*), 1) AS negative_pct
FROM table_h_price_load
GROUP BY 1
ORDER BY 1;

-- 2. The rise and fall, month by month. The first extreme hours of the range appear in September
-- 2021, and the level falls back from October 2022.
SELECT
    year_date AS year,
    month_date AS month,
    ROUND(MEDIAN(avg_h_price), 0) AS median_price,
    COUNT(*) FILTER (WHERE extreme_price) AS extreme_hours
FROM table_h_price_load
WHERE year_date IN (2021, 2022)
GROUP BY 1, 2
ORDER BY 1, 2;

-- 3. Mean hourly output per year for the types that bear on the negative-hour question, in MW.
-- B16's annual maximum sits beside its mean because the mean alone hides that the series is flat:
-- it is the transmission-connected remnant, not national solar. See "What TenneT publishes per
-- production type, and what it does not" above.
SELECT
    year_date AS year,
    ROUND(AVG(pw_h_gen) FILTER (WHERE psr_type = 'B18'), 0) AS wind_offshore_mw,
    ROUND(AVG(pw_h_gen) FILTER (WHERE psr_type = 'B19'), 0) AS wind_onshore_mw,
    ROUND(AVG(pw_h_gen) FILTER (WHERE psr_type = 'B20'), 0) AS other_mw,
    ROUND(AVG(pw_h_gen) FILTER (WHERE psr_type = 'B16'), 0) AS solar_mw,
    ROUND(MAX(pw_h_gen) FILTER (WHERE psr_type = 'B16'), 0) AS solar_peak_mw,
    ROUND(AVG(pw_h_gen) FILTER (WHERE psr_type = 'B04'), 0) AS gas_mw
FROM table_composition
GROUP BY 1
ORDER BY 1;
