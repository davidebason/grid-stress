-- When the extreme prices actually happened, and why the period is not a calendar year.
--
-- Establishes the dates quoted under "The 2021 and 2022 price level is a gas-market event" in
-- DATA.md, and the boundaries of the band any analysis that excludes it has to use. Read only:
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read evidence/07_extreme_price_period.sql"
--
-- Section 1 is the month-by-month series that shows the band: zero extreme hours through August
-- 2021, the first five in September, sustained through December 2022, a tail in January and
-- February 2023, and nothing after. Section 2 is what each candidate cut keeps and discards,
-- which is the argument for cutting on the band rather than on calendar years.

SET TimeZone = 'UTC';

-- 1. The band, month by month. Zero extreme hours through August 2021 with a median price of 47
-- to 85; the first five in September as the median jumps to 133; sustained through December 2022
-- with medians of 139 to 449; a tail of 17 and 2 in January and February 2023; and from March 2023
-- a median that never leaves 80 to 132 again. The boundaries are not calendar years, which is the
-- whole point: the first eight months of 2021 are the cheapest hours in the range.
SELECT
    year_date AS year,
    month_date AS month,
    ROUND(MEDIAN(avg_h_price), 0) AS median_price,
    COUNT(*) FILTER (WHERE extreme_price) AS extreme_hours,
    COUNT(*) FILTER (WHERE price_neg) AS negative_hours,
    repeat('.', CAST(COUNT(*) FILTER (WHERE extreme_price) / 12 AS INT)) AS extreme_bar
FROM table_h_price_load
WHERE year_date <= 2023
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2. What each candidate cut keeps and discards. A calendar cut is wrong in both directions: it
-- throws away the 65 negative hours of January to August 2021, which are clean data, and keeps
-- the elevated January and February 2023. Cutting on the band fixes both. The project took the
-- third option, starting at 2023-03-01, which discards early 2021 as well but leaves the period
-- contiguous -- a hole in the middle would make any month-on-month reading discontinuous.
SELECT 'whole range' AS cut, COUNT(*) AS hours,
       COUNT(*) FILTER (WHERE price_neg) AS negative,
       COUNT(*) FILTER (WHERE extreme_price) AS extreme
FROM table_h_price_load
UNION ALL
SELECT 'drop calendar 2021 and 2022', COUNT(*),
       COUNT(*) FILTER (WHERE price_neg), COUNT(*) FILTER (WHERE extreme_price)
FROM table_h_price_load WHERE year_date NOT IN (2021, 2022)
UNION ALL
SELECT 'drop the band, 2021-09 to 2023-02', COUNT(*),
       COUNT(*) FILTER (WHERE price_neg), COUNT(*) FILTER (WHERE extreme_price)
FROM table_h_price_load
WHERE date_ams < DATE '2021-09-01' OR date_ams >= DATE '2023-03-01'
UNION ALL
SELECT 'from 2023-03-01, as adopted', COUNT(*),
       COUNT(*) FILTER (WHERE price_neg), COUNT(*) FILTER (WHERE extreme_price)
FROM table_h_price_load WHERE date_ams >= DATE '2023-03-01';

-- 3. The eight months a calendar cut would discard for nothing: no extreme hours at all, the
-- lowest medians in the range, and 65 negative hours that every later analysis would lose.
SELECT
    COUNT(*) AS hours,
    ROUND(MEDIAN(avg_h_price), 1) AS median_price,
    COUNT(*) FILTER (WHERE price_neg) AS negative_hours,
    COUNT(*) FILTER (WHERE extreme_price) AS extreme_hours
FROM table_h_price_load
WHERE date_ams >= DATE '2021-01-01' AND date_ams < DATE '2021-09-01';
