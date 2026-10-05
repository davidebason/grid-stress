-- Q3_SWING. Within a single day, do the swings in price go with the swings in load, in thermal
-- output and in the B20 daily swing, and with a high B20 daily floor; and on the days where they
-- do not, which days are those.
--
-- Thermal output, B04 gas plus B05 coal, is what still has to be burned once the weather has done
-- whatever it is doing. It stands in for the renewable share, which this source cannot measure
-- because TenneT files unidentifiable output under B20, so it is a substitute and not an
-- equivalent. The B20 swing and floor sit beside it: the part of the unidentifiable bucket that
-- follows the sun and the part that does not. All three were a separate question until
-- 2026-10-05, when they were folded in here under the same matching rule and null model.
--
-- Measurables: daily extremes, load, thermal output, B20 daily swing, B20 daily floor,
-- [extreme hour, from Q1].
-- Reads: table_h_price_load, table_composition, b20_thermal_table.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
-- The row is one Amsterdam local day, not one hour. An hour-of-day profile pools 2,069 separate
-- dates into each of its 24 groups, so it can speak about the shape of an average day and never
-- about whether two series moved together on any actual one.
--
-- The matching rule. Within one month of one year, n is that group's count of extreme-price
-- days. The n days of largest value are then taken from each other series in the same group,
-- and the group reports how many of the n coincide. Price sizes the set, so no threshold is
-- picked for load, thermal output or either B20 measure. The grouping is month-within-year: at G_MONTH the 305 extreme
-- days of 2022 would set n for every other year's same month.
--
-- One null model, and every probability in the file comes from it. If a series had nothing to
-- do with price, which of a month's Mondays carry the extreme flag would be unrelated to which
-- of its Mondays are in the top n, and likewise for each weekday. So inside one weekday of one
-- month, with D days of which E are extreme and T are in the top n, the overlap is
-- hypergeometric:
--
--     P(K = j) = C(E, j) * C(D - E, T - j) / C(D, T)
--
-- and a month's overlap is the sum of its seven weekday overlaps, which are independent, so its
-- distribution is their convolution. A year's is the convolution of its months, and the whole
-- range's the convolution of everything. The p-value is P(K >= observed) under that
-- distribution: the probability that luck alone does at least as well as the series did.
--
-- Why within the weekday, rather than one hypergeometric over the whole month. 28.6% of days
-- are weekends but only 18.1% of extreme days and 9.1% of top-load days are. Both sets avoid
-- weekends, so they overlap for calendar reasons with no shared cause, and a null that treats
-- every day of the month alike credits that overlap to load. Holding each weekday's counts
-- fixed puts the calendar into the null as well as the data.
--
-- Definitions this file fixes, each of which moves the numbers:
--   extreme day   a day holding at least one extreme hour, extreme being an hourly price above
--                 225.00 EUR/MWh, the 0.90 quantile over the whole range, fixed once in Q1.
--                 487 of the 2,069 days qualify. One extreme hour counts the same as 24.
--   biggest load  the day's MAX(avg_h_load). The daily mean and the daily swing order the same
--                 month differently and either would be a different question.
--   thermal       B04 gas plus B05 coal, summed per hour in mean MW from table_composition, then
--                 the day's max - min: a swing, as the plan's thermal output row specifies, so it
--                 ranks the days on which the burned fleet ramped hardest. Not the existing
--                 day_th_energy_output, which is a sum over the day and so a level of energy.
--   B20 floor     the day's MIN of B20, as Q2 built it. A level rather than a swing, so the n
--                 largest are the days the bucket never fell low: its heating-season baseload.
--   ties          ROW_NUMBER with date_ams as the tiebreak, so a group's top-n is exactly n rows.
--   naming        days_in_group, never N. DuckDB identifiers are case-insensitive, so AS n and
--                 AS N are one column, n < N is always false, and every statement returns
--                 nothing, with no error.
--   precision     every probability is DOUBLE. A literal such as 0.5 is typed DECIMAL(2,1) in
--                 DuckDB, and a convolution seeded with one silently rounds 0.125 to 0.2.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/03_swing.sql"

SET TimeZone = 'UTC';

-- log C(a, b). DuckDB has no comb(), and C(31, 15) is already 300 million, so the binomials are
-- built and combined in logs and exponentiated once. A TEMP MACRO is DuckDB; elsewhere the same
-- expression is written inline or as a SQL function.
CREATE OR REPLACE TEMP MACRO lchoose(a, b) AS lgamma(a + 1) - lgamma(b + 1) - lgamma(a - b + 1);


-- One row per Amsterdam local day. Expected rows: 2,069.
CREATE OR REPLACE TEMP TABLE day_series AS
WITH price_day AS (
    SELECT
        date_ams,
        year_date,
        month_date,
        BOOL_OR(extreme_price) AS is_ext_day,
        MAX(avg_h_load)        AS day_max_load
    FROM table_h_price_load
    GROUP BY date_ams, year_date, month_date
),
thermal_hour AS (
    SELECT date_ams, date_utc, SUM(pw_h_gen) AS th_mw
    FROM table_composition
    WHERE psr_type IN ('B04', 'B05')
    GROUP BY date_ams, date_utc
),
thermal_day AS (
    SELECT date_ams, MAX(th_mw) - MIN(th_mw) AS day_swing_th
    FROM thermal_hour
    GROUP BY date_ams
)
SELECT
    p.date_ams,
    p.year_date,
    p.month_date,
    b.day_of_week,
    p.is_ext_day,
    p.day_max_load,
    t.day_swing_th,
    b.pw_swing_day_b20 AS day_swing_b20,
    b.pw_floor_day_b20 AS day_floor_b20
FROM price_day p
JOIN b20_thermal_table b ON p.date_ams = b.date_ams
JOIN thermal_day t       ON p.date_ams = t.date_ams
;

-- n per month-year. Expected rows: 68.
CREATE OR REPLACE TEMP TABLE group_n AS
SELECT
    year_date,
    month_date,
    COUNT(*)                            AS days_in_group,
    COUNT(*) FILTER (WHERE is_ext_day)  AS n
FROM day_series
GROUP BY year_date, month_date
;

-- Each day's place within its own month-year, once per series. Expected rows: 2,069.
CREATE OR REPLACE TEMP TABLE ranked AS
SELECT
    d.*,
    g.n,
    g.days_in_group,
    ROW_NUMBER() OVER (PARTITION BY d.year_date, d.month_date
                       ORDER BY d.day_max_load  DESC, d.date_ams) AS place_load,
    ROW_NUMBER() OVER (PARTITION BY d.year_date, d.month_date
                       ORDER BY d.day_swing_th  DESC, d.date_ams) AS place_th,
    ROW_NUMBER() OVER (PARTITION BY d.year_date, d.month_date
                       ORDER BY d.day_swing_b20 DESC, d.date_ams) AS place_b20,
    ROW_NUMBER() OVER (PARTITION BY d.year_date, d.month_date
                       ORDER BY d.day_floor_b20 DESC, d.date_ams) AS place_floor
FROM day_series d JOIN group_n g ON d.year_date = g.year_date AND d.month_date = g.month_date
;

-- The unit the null model works on: one weekday of one month. Every month holds each weekday
-- four or five times. Expected rows: 476, which is 68 groups times 7 weekdays.
CREATE OR REPLACE TEMP TABLE strata AS
SELECT
    year_date,
    month_date,
    day_of_week,
    n,
    days_in_group,
    COUNT(*)                                               AS days_s,
    COUNT(*) FILTER (WHERE is_ext_day)                     AS ext_s,
    COUNT(*) FILTER (WHERE place_load <= n)                AS top_load_s,
    COUNT(*) FILTER (WHERE place_th   <= n)                AS top_th_s,
    COUNT(*) FILTER (WHERE place_b20  <= n)                AS top_b20_s,
    COUNT(*) FILTER (WHERE place_floor <= n)               AS top_floor_s,
    COUNT(*) FILTER (WHERE is_ext_day AND place_load <= n) AS match_load_s,
    COUNT(*) FILTER (WHERE is_ext_day AND place_th   <= n) AS match_th_s,
    COUNT(*) FILTER (WHERE is_ext_day AND place_b20  <= n) AS match_b20_s,
    COUNT(*) FILTER (WHERE is_ext_day AND place_floor <= n) AS match_floor_s
FROM ranked
GROUP BY year_date, month_date, day_of_week, n, days_in_group
;

-- The same, one row per series, so everything downstream is written once. Expected rows: 1,904.
CREATE OR REPLACE TEMP TABLE strata_long AS
SELECT 'load' AS series, year_date, month_date, day_of_week, n, days_in_group,
       days_s, ext_s, top_load_s AS top_s, match_load_s AS match_s
FROM strata
UNION ALL
SELECT 'thermal', year_date, month_date, day_of_week, n, days_in_group,
       days_s, ext_s, top_th_s, match_th_s
FROM strata
UNION ALL
SELECT 'b20', year_date, month_date, day_of_week, n, days_in_group,
       days_s, ext_s, top_b20_s, match_b20_s
FROM strata
UNION ALL
SELECT 'b20_floor', year_date, month_date, day_of_week, n, days_in_group,
       days_s, ext_s, top_floor_s, match_floor_s
FROM strata
;


-- The match table: every group, the observed rate beside the rate the null model expects. The
-- expectation of a hypergeometric is E*T/D, summed over the seven weekdays. The 21 empty and 4
-- whole-month groups are printed rather than filtered away: an empty group has no set to
-- intersect, and in a whole month the top n of any series is every day, so the expected rate is
-- 100% and the match carries nothing. NULLIF, because DuckDB returns inf for division by zero.
-- Expected rows: 68, of which 43 informative.
SELECT
    year_date,
    month_date,
    days_in_group,
    n,
    CASE WHEN n = 0 THEN 'empty'
         WHEN n = days_in_group THEN 'whole month'
         ELSE 'informative' END AS kind,
    SUM(match_load_s) AS match_load,
    ROUND(100.0 * SUM(match_load_s) / NULLIF(n, 0), 1) AS pct_load,
    ROUND(100.0 * SUM(1.0 * ext_s * top_load_s / days_s) / NULLIF(n, 0), 1) AS chance_load,
    SUM(match_th_s) AS match_th,
    ROUND(100.0 * SUM(match_th_s) / NULLIF(n, 0), 1) AS pct_th,
    ROUND(100.0 * SUM(1.0 * ext_s * top_th_s / days_s) / NULLIF(n, 0), 1) AS chance_th,
    SUM(match_b20_s) AS match_b20,
    ROUND(100.0 * SUM(match_b20_s) / NULLIF(n, 0), 1) AS pct_b20,
    ROUND(100.0 * SUM(1.0 * ext_s * top_b20_s / days_s) / NULLIF(n, 0), 1) AS chance_b20,
    SUM(match_floor_s) AS match_floor,
    ROUND(100.0 * SUM(match_floor_s) / NULLIF(n, 0), 1) AS pct_floor,
    ROUND(100.0 * SUM(1.0 * ext_s * top_floor_s / days_s) / NULLIF(n, 0), 1) AS chance_floor
FROM strata
GROUP BY year_date, month_date, days_in_group, n
ORDER BY year_date, month_date
;

SELECT '--------------------------------' AS separator;


-- The probability of each possible overlap inside one weekday of one informative month. j runs
-- over the overlaps that are possible at all: at least E + T - D, since that many must collide
-- when the two sets together exceed the days available, and at most the smaller set.
-- Expected rows: about 1,000.
CREATE OR REPLACE TEMP TABLE stratum_pmf AS
SELECT
    s.series, s.year_date, s.month_date, s.day_of_week, j.j,
    exp(lchoose(s.ext_s, j.j)
        + lchoose(s.days_s - s.ext_s, s.top_s - j.j)
        - lchoose(s.days_s, s.top_s)) AS p
FROM strata_long s,
     generate_series(greatest(0, s.ext_s + s.top_s - s.days_s), least(s.ext_s, s.top_s)) AS j(j)
WHERE s.n > 0 AND s.n < s.days_in_group
;

-- Each stratum is a step in three convolutions at once: its month's, its year's, and the whole
-- range's. step numbers the strata inside each of those, so the recursion below can add them in
-- one at a time.
CREATE OR REPLACE TEMP TABLE units AS
SELECT 'month' AS level, series, printf('%d-%02d', year_date, month_date) AS part,
       DENSE_RANK() OVER (PARTITION BY series, year_date, month_date ORDER BY day_of_week) AS step,
       j, p
FROM stratum_pmf
UNION ALL
SELECT 'year', series, CAST(year_date AS VARCHAR),
       DENSE_RANK() OVER (PARTITION BY series, year_date ORDER BY month_date, day_of_week),
       j, p
FROM stratum_pmf
UNION ALL
SELECT 'all', series, 'all',
       DENSE_RANK() OVER (PARTITION BY series ORDER BY year_date, month_date, day_of_week),
       j, p
FROM stratum_pmf
;

-- The convolution. Start from certainty, an overlap of 0 with probability 1; at each step add
-- one stratum's overlap, so the new total is the old total plus j, with probability the product,
-- summed over every pair that lands on the same total. After the last step the rows are the
-- exact distribution of the overlap under the null. The aggregate inside a recursive term is
-- accepted by DuckDB and refused by Postgres, where the same fold needs a procedural loop.
CREATE OR REPLACE TEMP TABLE dist AS
WITH RECURSIVE conv(level, series, part, step, k, p) AS (
    SELECT DISTINCT level, series, part, 0::BIGINT, 0::BIGINT, 1.0::DOUBLE FROM units
    UNION ALL
    SELECT c.level, c.series, c.part, c.step + 1, c.k + u.j, SUM(c.p * u.p)
    FROM conv c JOIN units u
      ON u.level = c.level AND u.series = c.series AND u.part = c.part AND u.step = c.step + 1
    GROUP BY c.level, c.series, c.part, c.step + 1, c.k + u.j
)
SELECT c.level, c.series, c.part, c.k, c.p
FROM conv c
JOIN (SELECT level, series, part, MAX(step) AS last_step FROM units GROUP BY level, series, part) m
  ON c.level = m.level AND c.series = m.series AND c.part = m.part AND c.step = m.last_step
;

-- What was observed at the same three levels.
CREATE OR REPLACE TEMP TABLE observed AS
WITH inf AS (SELECT * FROM strata_long WHERE n > 0 AND n < days_in_group)
SELECT 'month' AS level, series, printf('%d-%02d', year_date, month_date) AS part,
       SUM(ext_s) AS ext_days, SUM(match_s) AS k_obs
FROM inf GROUP BY series, year_date, month_date
UNION ALL
SELECT 'year', series, CAST(year_date AS VARCHAR), SUM(ext_s), SUM(match_s)
FROM inf GROUP BY series, year_date
UNION ALL
SELECT 'all', series, 'all', SUM(ext_s), SUM(match_s)
FROM inf GROUP BY series
;

-- The p-value and its companions, per level, part and series. p_value is the upper tail, the
-- probability that luck matches at least as many days; p_below is the lower tail, at most as
-- many, and is what shows a series that AVOIDS the extreme days, which the upper tail can only
-- report as a p near 1. The B20 floor is the case that needed it. sums_to_one checks that every
-- distribution was assembled correctly; it fails immediately if a binomial is missing.
CREATE OR REPLACE TEMP TABLE tested AS
SELECT
    o.level, o.series, o.part, o.ext_days, o.k_obs,
    SUM(d.k * d.p)                                           AS expected,
    sqrt(SUM(d.k * d.k * d.p) - SUM(d.k * d.p) ^ 2)          AS sd,
    SUM(d.p) FILTER (WHERE d.k >= o.k_obs)                   AS p_value,
    SUM(d.p) FILTER (WHERE d.k <= o.k_obs)                   AS p_below,
    SUM(d.p)                                                 AS sums_to_one
FROM observed o
JOIN dist d ON d.level = o.level AND d.series = o.series AND d.part = o.part
GROUP BY o.level, o.series, o.part, o.ext_days, o.k_obs
;


-- The answer, over the whole range. The p-value is the probability that a series unrelated to
-- price, under the weekday-preserving null, matches at least as many extreme days as observed.
-- Expected rows: 4.
SELECT
    series,
    ext_days,
    k_obs                                   AS matches,
    ROUND(100.0 * k_obs / ext_days, 1)      AS pct_matched,
    ROUND(expected, 1)                      AS expected_by_chance,
    ROUND(100.0 * expected / ext_days, 1)   AS pct_by_chance,
    ROUND(sd, 2)                            AS sd,
    ROUND((k_obs - expected) / sd, 2)       AS sd_above_chance,
    p_value,
    p_below,
    ROUND(sums_to_one, 9)                   AS sums_to_one
FROM tested
WHERE level = 'all'
ORDER BY CASE series WHEN 'load' THEN 1 WHEN 'thermal' THEN 2 WHEN 'b20' THEN 3 ELSE 4 END
;

SELECT '--------------------------------' AS separator;

-- By year. Each row rests on that year's informative months only, so on 20 to 182 extreme days.
-- Expected rows: 6.
SELECT
    part                                                                  AS year,
    MAX(ext_days)                                                         AS ext_days,
    MAX(k_obs) FILTER (WHERE series = 'load')                             AS load_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'load'), 1)                AS load_expected,
    MAX(p_value) FILTER (WHERE series = 'load')                           AS p_load,
    MAX(k_obs) FILTER (WHERE series = 'thermal')                          AS th_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'thermal'), 1)             AS th_expected,
    MAX(p_value) FILTER (WHERE series = 'thermal')                        AS p_th,
    MAX(k_obs) FILTER (WHERE series = 'b20')                              AS b20_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'b20'), 1)                 AS b20_expected,
    MAX(p_value) FILTER (WHERE series = 'b20')                            AS p_b20,
    MAX(k_obs) FILTER (WHERE series = 'b20_floor')                        AS floor_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'b20_floor'), 1)           AS floor_expected,
    MAX(p_value) FILTER (WHERE series = 'b20_floor')                      AS p_floor
FROM tested
WHERE level = 'year'
GROUP BY part
ORDER BY part
;

SELECT '--------------------------------' AS separator;

-- By month. A month with one extreme day can at best reach p of about 0.2 for a perfect match,
-- so a high p in a small month is an absence of evidence, not evidence of absence.
-- Expected rows: 43.
SELECT
    part                                                                  AS month,
    MAX(ext_days)                                                         AS n,
    MAX(k_obs) FILTER (WHERE series = 'load')                             AS load_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'load'), 2)                AS load_expected,
    ROUND(MAX(p_value) FILTER (WHERE series = 'load'), 4)                 AS p_load,
    MAX(k_obs) FILTER (WHERE series = 'thermal')                          AS th_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'thermal'), 2)             AS th_expected,
    ROUND(MAX(p_value) FILTER (WHERE series = 'thermal'), 4)              AS p_th,
    MAX(k_obs) FILTER (WHERE series = 'b20')                              AS b20_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'b20'), 2)                 AS b20_expected,
    ROUND(MAX(p_value) FILTER (WHERE series = 'b20'), 4)                  AS p_b20,
    MAX(k_obs) FILTER (WHERE series = 'b20_floor')                        AS floor_matches,
    ROUND(MAX(expected) FILTER (WHERE series = 'b20_floor'), 2)           AS floor_expected,
    ROUND(MAX(p_value) FILTER (WHERE series = 'b20_floor'), 4)            AS p_floor,
    ROUND(MIN(sums_to_one), 9)                                            AS sums_to_one
FROM tested
WHERE level = 'month'
GROUP BY part
ORDER BY part
;

-- How many months clear 0.05, against the 2.15 that 43 tests would throw by luck.
-- Expected rows: 1.
SELECT
    COUNT(*) FILTER (WHERE series = 'load')                       AS months,
    ROUND(0.05 * COUNT(*) FILTER (WHERE series = 'load'), 2)      AS expected_below_05,
    COUNT(*) FILTER (WHERE series = 'load'    AND p_value < 0.05) AS load_below_05,
    COUNT(*) FILTER (WHERE series = 'thermal' AND p_value < 0.05) AS th_below_05,
    COUNT(*) FILTER (WHERE series = 'b20'     AND p_value < 0.05) AS b20_below_05,
    COUNT(*) FILTER (WHERE series = 'b20_floor' AND p_value < 0.05) AS floor_below_05,
    ROUND(MEDIAN(p_value) FILTER (WHERE series = 'load'), 3)      AS load_median_p,
    ROUND(MEDIAN(p_value) FILTER (WHERE series = 'thermal'), 3)   AS th_median_p,
    ROUND(MEDIAN(p_value) FILTER (WHERE series = 'b20'),  3)      AS b20_median_p,
    ROUND(MEDIAN(p_value) FILTER (WHERE series = 'b20_floor'), 3) AS floor_median_p
FROM tested
WHERE level = 'month'
;

SELECT '--------------------------------' AS separator;


-- Where they do not intersect, as dates: the extreme-price days that are in none of the four
-- series' top n. One row per informative group that has at least one such day.
SELECT
    year_date,
    month_date,
    n,
    COUNT(*)                                                          AS missed_by_all,
    string_agg(CAST(day(date_ams) AS VARCHAR), ' ' ORDER BY date_ams) AS days_of_month
FROM ranked
WHERE n > 0 AND n < days_in_group
  AND is_ext_day AND place_load > n AND place_th > n AND place_b20 > n AND place_floor > n
GROUP BY year_date, month_date, n
ORDER BY year_date, month_date
;

SELECT '--------------------------------' AS separator;

-- The mirror image: top-load days on which the price was not extreme. The count is exactly n
-- minus the load match and carries nothing new as a number; it is here for the dates.
SELECT
    year_date,
    month_date,
    n,
    COUNT(*)                                                          AS top_load_not_extreme,
    string_agg(CAST(day(date_ams) AS VARCHAR), ' ' ORDER BY date_ams) AS days_of_month
FROM ranked
WHERE n > 0 AND n < days_in_group
  AND place_load <= n AND NOT is_ext_day
GROUP BY year_date, month_date, n
ORDER BY year_date, month_date
;
