-- Q4_GAIN. What a consumer saves by choosing when to buy.
--
-- Measurables: daily price spread, spread inside the hour.
-- Reads: table_price_unit.
-- Never the fact tables: the grain was fixed in sql/06_price_units.sql, which keeps every price
-- at the market time unit it was published at and attaches its Amsterdam local day.
--
-- Carries a sensitivity across two assumptions, how many hours a day are shifted and whether
-- they are shifted in hours or quarter-hours, with notice and the day boundary held fixed.
--
-- G_DOW is in because the weekend is a different market for price: Q1 found Sunday negative in
-- 9.88% of its hours against Wednesday's 2.29%.
--
-- One statement per grouping, and no statement groups by two axes at once: that is what
-- leaves 1.67 negative hours per group, where a min, a max and a quintile all return the
-- same number. The expected row count sits above each statement, so a statement that has
-- silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/04_shifting_gain.sql"

SET TimeZone = 'UTC';

-- One row per Amsterdam local day, per period. The period is read off unit_minutes, the
-- resolution each price series declared, rather than off a date: 60 for every day through
-- 2025-09-30 and 15 from 2025-10-01, and validate.py guarantees no day holds both.
-- Expected rows: 1,734 and 335.
CREATE OR REPLACE TEMP TABLE pre_change AS
SELECT
    date_ams,
    isodow(date_ams) AS dow_num,
    day_of_week,
    month_date,
    year_date,
    MAX(price_eur_per_mwh)
        - PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_eur_per_mwh) AS spread_day
FROM table_price_unit
WHERE unit_minutes = 60
GROUP BY date_ams, day_of_week, month_date, year_date
;

CREATE OR REPLACE TEMP TABLE post_change AS
SELECT
    date_ams,
    isodow(date_ams) AS dow_num,
    day_of_week,
    month_date,
    year_date,
    MAX(price_eur_per_mwh)
        - PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_eur_per_mwh) AS spread_day
FROM table_price_unit
WHERE unit_minutes = 15
GROUP BY date_ams, day_of_week, month_date, year_date
;

-- The daily spread is the day's max - median over its market time units: the unit the consumer
-- escapes against an ordinary unit it lands in, not the single cheapest one, since a sizeable
-- shift cannot all land there. The units are the day's 24 hourly prices before the change and
-- its 96 quarter-hour prices after it, so the two periods are each measured at their own grain.
-- Each group reports the median of its daily spreads. The mean is dragged up by the 2021-22
-- crisis, which puts 2022 at 205 EUR/MWh against 83 to 138 in every other year before the change.

-- Each statement puts the two periods side by side, one row per group, with the change beside
-- them: after minus before, so a positive change is a wider daily spread after the move to
-- quarter-hours. The change is everything that differs between the two periods, the grain
-- included, not the grain alone. days is the number of days behind each median, since the two
-- periods differ fivefold in size and a median over 48 days is a weaker claim than one over 248.

-- G_DOW: day of week within the dataset, 7 groups: about 248 days each before the change and
-- 48 after. isodow numbers Monday 1 to Sunday 7, so the rows come out in calendar order rather
-- than alphabetical. Expected rows: 7.
WITH dow_pre AS (
    SELECT
        dow_num,
        day_of_week,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_pre,
        COUNT(*) AS days_pre
    FROM pre_change
    GROUP BY dow_num, day_of_week
),
dow_post AS (
    SELECT
        dow_num,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_post,
        COUNT(*) AS days_post
    FROM post_change
    GROUP BY dow_num
)
SELECT
    pre.day_of_week,
    pre.med_spread_pre,
    post.med_spread_post,
    post.med_spread_post - pre.med_spread_pre AS change_post_minus_pre,
    pre.days_pre,
    post.days_post
FROM dow_pre pre JOIN dow_post post ON pre.dow_num = post.dow_num
ORDER BY pre.dow_num
;

-- G_MONTH: month within the dataset. Before the change 12 groups of 120 to 155 days, October to
-- December holding one year fewer since 2025's fall after the change; after it 11 groups of one
-- month each, October 2025 to August 2026. LEFT JOIN, so September stays in the table with no
-- after value rather than silently disappearing. Expected rows: 12.
WITH month_pre AS (
    SELECT
        month_date,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_pre,
        COUNT(*) AS days_pre
    FROM pre_change
    GROUP BY month_date
),
month_post AS (
    SELECT
        month_date,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_post,
        COUNT(*) AS days_post
    FROM post_change
    GROUP BY month_date
)
SELECT
    pre.month_date,
    pre.med_spread_pre,
    post.med_spread_post,
    post.med_spread_post - pre.med_spread_pre AS change_post_minus_pre,
    pre.days_pre,
    post.days_post
FROM month_pre pre LEFT JOIN month_post post ON pre.month_date = post.month_date
ORDER BY pre.month_date
;

-- G_YEAR: year within the dataset. Before the change 2021 to 2025, the last ending 30 September;
-- after it 2025 from 1 October and 2026 to 31 August. FULL OUTER JOIN, because each period has a
-- year the other lacks: 2021 to 2024 only before, 2026 only after. No change column: the one year
-- both hold is 2025, and there they cover different months, January to September before and
-- October to December after, so a difference would compare seasons rather than grains.
-- Expected rows: 6.
WITH year_pre AS (
    SELECT
        year_date,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_pre,
        COUNT(*) AS days_pre
    FROM pre_change
    GROUP BY year_date
),
year_post AS (
    SELECT
        year_date,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS med_spread_post,
        COUNT(*) AS days_post
    FROM post_change
    GROUP BY year_date
)
SELECT
    COALESCE(pre.year_date, post.year_date) AS year_date,
    pre.med_spread_pre,
    post.med_spread_post,
    pre.days_pre,
    post.days_post
FROM year_pre pre FULL OUTER JOIN year_post post ON pre.year_date = post.year_date
ORDER BY year_date
;


-- ============================================================================================
-- Grain or period. The before-and-after comparison sets 335 quarter-hourly days against 1,734
-- hourly ones, so its change column holds the finer grain AND everything else that differs
-- between the periods: the years, the price level, the particular months. Measuring the 335
-- post-change days at hourly grain as well, each hour being the mean of its four quarters,
-- separates the two, since the same day at two grains differs only in the grain.
-- ============================================================================================

-- The post-change quarter-hours, each with the UTC hour it belongs to. The hour is keyed on
-- hour_utc, not hour_date: on the autumn clock-change day the local hour 02 occurs twice, and
-- grouping on hour_date would merge two hours into one of eight quarters. Expected rows: 32,160.
CREATE OR REPLACE TEMP TABLE qh AS
SELECT
    date_utc,
    date_trunc('hour', date_utc) AS hour_utc,
    date_ams,
    hour_date,
    isodow(date_ams) AS dow_num,
    day_of_week,
    month_date,
    price_eur_per_mwh AS price
FROM table_price_unit
WHERE unit_minutes = 15
;

-- The same days at hourly grain. Expected rows: 8,040.
CREATE OR REPLACE TEMP TABLE qh_hour AS
SELECT
    hour_utc,
    date_ams,
    hour_date,
    dow_num,
    day_of_week,
    month_date,
    AVG(price) AS price_h
FROM qh
GROUP BY hour_utc, date_ams, hour_date, dow_num, day_of_week, month_date
;

-- One row per post-change day, both grains side by side. Expected rows: 335.
CREATE OR REPLACE TEMP TABLE qh_day AS
WITH q AS (
    SELECT
        date_ams, dow_num, day_of_week, month_date,
        MAX(price)                                            AS max_q,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price)    AS med_q
    FROM qh
    GROUP BY date_ams, dow_num, day_of_week, month_date
),
h AS (
    SELECT
        date_ams,
        MAX(price_h)                                          AS max_h,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_h)  AS med_h
    FROM qh_hour
    GROUP BY date_ams
)
SELECT
    q.*,
    h.max_h,
    h.med_h
FROM q JOIN h ON q.date_ams = h.date_ams
;

-- The decomposition: the comparison's change split into two parts that add up exactly:
--     change = (after at quarter-hour - after at hourly) + (after at hourly - before)
--            =  grain                                    +  period
-- The period part compares like with like, hourly against hourly, so it is the only figure in
-- this file that says whether the market itself offered a wider daily spread after the switch.
-- Each part is a difference between group medians, so the columns add up exactly.
--
-- The period part is given twice, against two bases. The whole-range base, 2021-01-01 to
-- 2025-09-30, includes the 2021-2022 gas-market event, which inflated every spread and so drags
-- the before medians up and the period part down. The post-crisis base starts at 2023-03-01,
-- the boundary table_h_price_post is cut at; see "The 2021 and 2022 price level is a gas-market
-- event" in DATA.md. The grain part needs no second version: it is measured on the after days
-- alone. Both bases are kept because the project reports the whole range as its reference and
-- the post-crisis range wherever a finding changes with it, and this is one that does.
--
-- Expected rows: 7, then 11. No G_YEAR: the post-change period holds 92 days of 2025, all
-- October to December, and 243 of 2026, January to August, so a year row would compare seasons.
WITH pre AS (
    SELECT dow_num, day_of_week,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS before_hourly,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day)
               FILTER (WHERE date_ams >= DATE '2023-03-01')       AS before_postcrisis
    FROM pre_change GROUP BY dow_num, day_of_week
),
post AS (
    SELECT dow_num,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY max_h - med_h) AS after_hourly,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY max_q - med_q) AS after_quarter
    FROM qh_day GROUP BY dow_num
)
SELECT
    pre.day_of_week,
    pre.before_hourly,
    pre.before_postcrisis,
    post.after_hourly,
    post.after_quarter,
    post.after_hourly - pre.before_hourly      AS period,
    post.after_hourly - pre.before_postcrisis  AS period_postcrisis,
    post.after_quarter - post.after_hourly     AS grain,
    post.after_quarter - pre.before_hourly     AS change,
    post.after_quarter - pre.before_postcrisis AS change_postcrisis
FROM pre JOIN post ON pre.dow_num = post.dow_num
ORDER BY pre.dow_num
;

WITH pre AS (
    SELECT month_date,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day) AS before_hourly,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_day)
               FILTER (WHERE date_ams >= DATE '2023-03-01')       AS before_postcrisis
    FROM pre_change GROUP BY month_date
),
post AS (
    SELECT month_date,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY max_h - med_h) AS after_hourly,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY max_q - med_q) AS after_quarter
    FROM qh_day GROUP BY month_date
)
SELECT
    pre.month_date,
    pre.before_hourly,
    pre.before_postcrisis,
    post.after_hourly,
    post.after_quarter,
    post.after_hourly - pre.before_hourly      AS period,
    post.after_hourly - pre.before_postcrisis  AS period_postcrisis,
    post.after_quarter - post.after_hourly     AS grain,
    post.after_quarter - pre.before_hourly     AS change,
    post.after_quarter - pre.before_postcrisis AS change_postcrisis
FROM pre LEFT JOIN post ON pre.month_date = post.month_date
ORDER BY pre.month_date
;


-- The daily spread at hourly grain, every year of the range, like for like: before the switch
-- each hour's single price, after it the mean of its four quarters. The before-and-after
-- comparison above cannot give this, since it measures each period at its own grain, and the
-- memo's level since 2023 and its 2022 comparison rest on it. Expected rows: 6.
WITH hourly AS (
    SELECT
        date_ams,
        year_date,
        date_trunc('hour', date_utc) AS hour_utc,
        AVG(price_eur_per_mwh)       AS price_h
    FROM table_price_unit
    GROUP BY date_ams, year_date, date_trunc('hour', date_utc)
),
daily AS (
    SELECT
        date_ams, year_date,
        MAX(price_h) - PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_h) AS spread_h
    FROM hourly
    GROUP BY date_ams, year_date
)
SELECT
    year_date,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_h), 1) AS med_spread_hourly,
    COUNT(*)                                                         AS days
FROM daily
GROUP BY year_date
ORDER BY year_date
;

-- Is the period part the switch? If moving to quarter-hour prices had itself narrowed the
-- hourly spread, the narrowing would show as a step at October 2025 and in every season alike.
-- This sets each month since the crisis against the same month in other years, all at hourly
-- grain: before the switch each hour's single price, after it the mean of its four quarters,
-- the same series the period part is computed from. One row per year, one column per month,
-- each cell the median daily spread of that month. Months outside the range are NULL.
-- Expected rows: 4, 2023 to 2026.
CREATE OR REPLACE TEMP TABLE month_year_hourly AS
WITH hourly AS (
    SELECT
        date_ams,
        year_date,
        month_date,
        date_trunc('hour', date_utc) AS hour_utc,
        AVG(price_eur_per_mwh)       AS price_h
    FROM table_price_unit
    WHERE date_ams >= DATE '2023-03-01'
    GROUP BY date_ams, year_date, month_date, date_trunc('hour', date_utc)
),
daily AS (
    SELECT
        date_ams, year_date, month_date,
        MAX(price_h) - PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price_h) AS spread_h
    FROM hourly
    GROUP BY date_ams, year_date, month_date
)
SELECT
    year_date,
    month_date,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_h), 0) AS med_spread_hourly
FROM daily
GROUP BY year_date, month_date
;

PIVOT month_year_hourly
ON month_date IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
USING first(med_spread_hourly)
GROUP BY year_date
ORDER BY year_date
;


-- ============================================================================================
-- The sensitivity: from EUR per MWh to EUR per year, which is what a client sets against the
-- cost of the equipment that moves load. Everything is per MW of load the client can move, and
-- over the same 335 post-change days, so every scenario is measured on the same prices.
--
-- Two assumptions, each varied while the other is held:
--   volume      how many hours a day the flexible MW is moved out of: 1, 2 or 4. The k dearest
--               units are escaped, so each further hour is worth less than the one before, which
--               is why volume is varied here rather than multiplied in afterwards.
--   block size  whole hours, or quarter-hours. At quarter-hour grain k hours are 4k quarters of
--               0.25 MWh each per MW.
--
-- Fixed throughout, and stated so they are not mistaken for findings: the consumer knows each
-- day's prices in advance, which day-ahead publication the afternoon before allows; moved load
-- lands within the same day, at its ordinary, median unit, not the cheapest one; the consumer is
-- too small to move the price; and only the wholesale day-ahead price counts, network charges
-- and taxes being flat across the day. Notice and crossing midnight were varied on 2026-10-05
-- and dropped the same day to keep the study simple: a fixed schedule with no notice earned
-- about a third less, and letting load cross midnight changed almost nothing.
--
-- EUR per year is the MEAN daily saving times 365, not the median: a year's saving is a total,
-- and a total is a mean times a count. Every other figure in this file is a median because it
-- describes a typical day.
-- ============================================================================================

-- Each day's units ranked from dearest down, at both grains.
CREATE OR REPLACE TEMP TABLE h_ranked AS
SELECT
    h.date_ams, h.price_h, d.med_h,
    ROW_NUMBER() OVER (PARTITION BY h.date_ams ORDER BY h.price_h DESC, h.hour_utc) AS rk
FROM qh_hour h JOIN qh_day d ON h.date_ams = d.date_ams
;

CREATE OR REPLACE TEMP TABLE q_ranked AS
SELECT
    q.date_ams, q.price, d.med_q,
    ROW_NUMBER() OVER (PARTITION BY q.date_ams ORDER BY q.price DESC, q.date_utc) AS rk
FROM qh q JOIN qh_day d ON q.date_ams = d.date_ams
;

-- One row per block size, day and volume: the EUR saved that day per MW of flexible load.
-- Expected rows: 2,010, which is 2 block sizes times 3 volumes times 335 days.
CREATE OR REPLACE TEMP TABLE scenario_day AS
WITH k AS (SELECT * FROM (VALUES (1), (2), (4)) t(k))
SELECT 'hour' AS block, r.date_ams, k.k, SUM(r.price_h - r.med_h) AS saving
FROM h_ranked r, k WHERE r.rk <= k.k
GROUP BY r.date_ams, k.k
UNION ALL
SELECT 'quarter', r.date_ams, k.k, 0.25 * SUM(r.price - r.med_q)
FROM q_ranked r, k WHERE r.rk <= 4 * k.k
GROUP BY r.date_ams, k.k
;

-- The sensitivity table. eur_per_mwh_1h is the mean saving per MWh moved when one hour a day is
-- moved; the three annual columns are EUR per MW of flexible load per year. Expected rows: 2.
SELECT
    block,
    COUNT(DISTINCT date_ams)                                AS days,
    ROUND(AVG(saving) FILTER (WHERE k = 1), 2)              AS eur_per_mwh_1h,
    ROUND(365 * AVG(saving) FILTER (WHERE k = 1), -2)       AS eur_per_mw_year_1h,
    ROUND(365 * AVG(saving) FILTER (WHERE k = 2), -2)       AS eur_per_mw_year_2h,
    ROUND(365 * AVG(saving) FILTER (WHERE k = 4), -2)       AS eur_per_mw_year_4h
FROM scenario_day
GROUP BY block
ORDER BY block
;
