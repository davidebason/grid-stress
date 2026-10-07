-- Q2_MIX. How the generation mix shifts when prices go negative, and how it shifts when
-- they go extreme.
--
-- Measurables: generation share, generation share shift, B20 daily swing, B20 daily floor.
-- Reads: table_composition, table_h_price_load, b20_thermal_table.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
-- One row per group per production type, since the shift is computed per type. Carry the
-- count of negative and of extreme hours behind each figure: the thinnest year rests on 70.
--
-- One statement per grouping, and no statement groups by two axes at once, which would leave too
-- few flagged hours per group to carry a statistic. The expected row count sits above each
-- statement, so a statement that has silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/02_generation_mix.sql"

SET TimeZone = 'UTC';


-- Generation share: which production types carry the largest share of published generation in a
-- typical hour, and by how much. The per-type median, not the maximum, which is a single hour.
--
-- Three rows per group: the leader, the margin and who is behind it. One row hides how narrow
-- the lead is, and ten are mostly near zero.
--
-- QUALIFY is DuckDB and Snowflake. Elsewhere the portable form is to wrap the ranked query in a
-- subquery and put the same condition in a WHERE.
--
-- G_MONTH: month within the dataset. 12 groups, about 4,138 hours in each. The medians are
-- computed once into a TEMP table and read twice: the pivot for the whole composition, the
-- ranking for the leaders and the margins. TEMP rather than a permanent table, so nothing is
-- left in the database file for a later load to disagree with.

CREATE OR REPLACE TEMP TABLE month_medians AS
SELECT
    month_date,
    psr_type,
    ROUND(100*(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h)), 2) AS pct_med_share
FROM table_composition
GROUP BY month_date, psr_type
;

-- The whole composition, one row per month. Expected rows: 12.
PIVOT month_medians ON psr_type USING first(pct_med_share)
GROUP BY month_date
ORDER BY month_date
;

-- The top three and the two margins between them. Expected rows: 12.
WITH place_table AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY month_date ORDER BY pct_med_share DESC) AS place
    FROM month_medians
)
SELECT
    month_date,
    MAX(psr_type)     FILTER (WHERE place = 1) AS leader,
    MAX(pct_med_share) FILTER (WHERE place = 1) AS leader_pct,
    MAX(psr_type)     FILTER (WHERE place = 2) AS runner_up,
    ROUND(MAX(pct_med_share) FILTER (WHERE place = 1)
          - MAX(pct_med_share) FILTER (WHERE place = 2), 2) AS diff_12,
    MAX(psr_type)     FILTER (WHERE place = 3) AS third,
    ROUND(MAX(pct_med_share) FILTER (WHERE place = 2)
          - MAX(pct_med_share) FILTER (WHERE place = 3), 2) AS diff_23
FROM place_table
WHERE place <= 3
GROUP BY month_date
ORDER BY month_date
;

-- A separator, to tell the tables apart in terminal output. It returns one row, so any check
-- that counts rows per statement sees it as a statement.
SELECT '--------------------------------' AS separator;

-- G_YEAR: year within the dataset. 6 groups, about 8,712 hours in each. Same shape as G_MONTH.
CREATE OR REPLACE TEMP TABLE year_medians AS
SELECT
    year_date,
    psr_type,
    ROUND(100 * (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h)), 2) AS pct_med_share
FROM table_composition
GROUP BY year_date, psr_type
;

-- The whole composition, one row per year. Expected rows: 6.
PIVOT year_medians ON psr_type USING first(pct_med_share)
GROUP BY year_date
ORDER BY year_date
;

-- The top three and the two margins between them. Expected rows: 6.
WITH place_table AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY year_date ORDER BY pct_med_share DESC) AS place
    FROM year_medians
)
SELECT
    year_date,
    MAX(psr_type)     FILTER (WHERE place = 1) AS leader,
    MAX(pct_med_share) FILTER (WHERE place = 1) AS leader_pct,
    MAX(psr_type)     FILTER (WHERE place = 2) AS runner_up,
    ROUND(MAX(pct_med_share) FILTER (WHERE place = 1)
          - MAX(pct_med_share) FILTER (WHERE place = 2), 2) AS diff_12,
    MAX(psr_type)     FILTER (WHERE place = 3) AS third,
    ROUND(MAX(pct_med_share) FILTER (WHERE place = 2)
          - MAX(pct_med_share) FILTER (WHERE place = 3), 2) AS diff_23
FROM place_table
WHERE place <= 3
GROUP BY year_date
ORDER BY year_date
;

-- Generation share shift: the median share over the flagged hours minus the median over all
-- hours of the same group, twice, once per flag, in percentage points.
--
-- This first statement is the whole range, which sits outside the granularity list: it is a
-- summary, not a profile, and on the extreme side it is close to a statement about 2022, since
-- 4,055 of the 4,956 extreme hours fall in that one year. The two that follow are the profiles
-- by month and by year.
--
-- Expected rows: 10, one per production type.
SELECT
    psr_type,
    -- The flagged hours minus all hours, in percentage points. The other
    -- way round reverses every sign and says gas rises when prices go negative.
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE price_neg))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS share_shift_neg,
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE extreme_price))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS share_shift_ext
FROM table_composition c JOIN table_h_price_load pl ON c.date_utc = pl.date_utc
GROUP BY psr_type
ORDER BY psr_type
;

-- The shift by month and by year. 120 and 60 values respectively, one per group per production
-- type, pivoted so each is 12 and 6 rows of 10 columns: 120 rows of three columns is a table you
-- page through, not one you read.
--
-- G_MONTH. Expected rows: 12, from 120 values.
CREATE OR REPLACE TEMP TABLE shift_month AS
SELECT
    c.month_date AS month_date,
    psr_type,
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE price_neg))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS shift_neg,
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE extreme_price))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS shift_ext
FROM table_composition c JOIN table_h_price_load pl ON c.date_utc = pl.date_utc
GROUP BY c.month_date, psr_type
;

PIVOT shift_month ON psr_type USING first(shift_neg) GROUP BY month_date ORDER BY month_date;
PIVOT shift_month ON psr_type USING first(shift_ext) GROUP BY month_date ORDER BY month_date;

-- G_YEAR. Expected rows: 6, from 60 values.
CREATE OR REPLACE TEMP TABLE shift_year AS
SELECT
    c.year_date AS year_date,
    psr_type,
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE price_neg))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS shift_neg,
    ROUND(100 * ((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h) FILTER (WHERE extreme_price))
                 - (PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY share_h))), 2) AS shift_ext
FROM table_composition c JOIN table_h_price_load pl ON c.date_utc = pl.date_utc
GROUP BY c.year_date, psr_type
;

PIVOT shift_year ON psr_type USING first(shift_neg) GROUP BY year_date ORDER BY year_date;
PIVOT shift_year ON psr_type USING first(shift_ext) GROUP BY year_date ORDER BY year_date;


-- B20 daily swing and floor, the mean of the daily values. The bucket is a mixture, so its share
-- is not interpretable on its own: the swing is the part that follows the sun and the floor the
-- part that does not, and they peak in opposite seasons.
--
-- G_MONTH. Expected rows: 12.
SELECT
    month_date,
    ROUND(AVG(pw_swing_day_b20), 0) AS avg_swing,
    ROUND(AVG(pw_floor_day_b20), 0) AS avg_floor,
    COUNT(*) AS days
FROM b20_thermal_table
GROUP BY month_date
ORDER BY month_date
;

-- G_YEAR. Expected rows: 6. days is there because 2026 stops at 31 August, so its 243 days
-- exclude the four lowest-swing months and its mean is not comparable with the full years.
SELECT
    year_date,
    ROUND(AVG(pw_swing_day_b20), 0) AS avg_swing,
    ROUND(AVG(pw_floor_day_b20), 0) AS avg_floor,
    COUNT(*) AS days
FROM b20_thermal_table
GROUP BY year_date
ORDER BY year_date
;