-- Q4_GAIN. What a consumer saves by choosing when to buy.
--
-- Measurables: daily price spread, spread inside the hour.
-- Reads: table_price_unit.
-- Never the fact tables: the grain was fixed in sql/06_price_units.sql, which keeps every price
-- at the market time unit it was published at and attaches its Amsterdam local day.
--
-- Carries a sensitivity across at least three assumptions: how many MWh are shiftable, how
-- much notice a shift needs, and whether it may cross a day boundary.
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
