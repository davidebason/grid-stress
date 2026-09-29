-- Run by `python -m gridstress.load`, inside its transaction, once every fact row is in.
-- Also runnable by hand against an already-loaded database:
--
--     duckdb data/processed/grid.duckdb -c ".read sql/04_hourly_tables.sql"
--
-- It builds the three tables the analysis queries are asked over, at the grains
-- fixed in the analysis plan: one row per hour, one row per hour per production type, one row
-- per Amsterdam local day.

SET TimeZone = 'UTC';

-- CREATE OR REPLACE TABLE table_load AS
-- SELECT
--     f.date_utc,
--     date_ams,
--     hour_date,
--     day_of_week,
--     month_date,
--     year_date,
--     load_mw
-- FROM fact_load f JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
-- ;

CREATE OR REPLACE TABLE table_h_price_load AS
WITH partial_1 AS (
    SELECT
        d.date_utc,
        AVG(price_eur_per_mwh) AS avg_h_price,
        MIN(price_eur_per_mwh) AS min_price,
        MAX(price_eur_per_mwh) - MIN(price_eur_per_mwh) AS spread,
        BOOL_OR(price_eur_per_mwh < 0) AS price_neg
    FROM fact_price f JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
    GROUP BY d.date_utc
),
extreme_price AS (
    SELECT
        quantile_cont(avg_h_price, 0.9) AS extreme_price_value
    FROM partial_1
),
partial_2 AS (
    SELECT
        d.date_utc,
        date_ams,
        hour_date,
        day_of_week,
        month_date,
        year_date,
        AVG(load_mw) AS avg_h_load
    FROM fact_load f JOIN dim_time d ON date_trunc('hour', f.date_utc) = d.date_utc
    GROUP BY d.date_utc, date_ams, hour_date, day_of_week, month_date, year_date
)
SELECT
    p1.date_utc,
    date_ams,
    hour_date,
    day_of_week,
    month_date,
    year_date,
    avg_h_price,
    min_price,
    spread,
    avg_h_load,
    price_neg,
    avg_h_price > extreme_price_value AS extreme_price
FROM partial_1 p1 JOIN partial_2 p2 ON p1.date_utc = p2.date_utc CROSS JOIN extreme_price
;
SELECT * FROM table_h_price_load LIMIT 20;

CREATE OR REPLACE TABLE table_composition AS
WITH pw_h_type AS (
    SELECT
        date_trunc('hour', date_utc) AS date_utc,
        psr_type,
        AVG(power_mw) AS pw_h_gen
    FROM fact_generation
    WHERE direction = 'in'
    GROUP BY 1, 2
)
SELECT
    d.date_utc,
    d.date_ams,
    d.hour_date,
    d.day_of_week,
    d.month_date,
    d.year_date,
    t.psr_type,
    t.pw_h_gen,
    t.pw_h_gen / SUM(t.pw_h_gen) OVER (PARTITION BY t.date_utc) AS share_h
FROM pw_h_type t JOIN dim_time d ON t.date_utc = d.date_utc
;

SELECT * FROM table_composition LIMIT 20;

CREATE OR REPLACE TABLE b20_thermal_table AS
WITH b20_table AS (
    SELECT
        date_ams,
        day_of_week,
        month_date,
        year_date,
        MAX(pw_h_gen) - MIN(pw_h_gen) AS pw_swing_day_b20,
        MIN(pw_h_gen) AS pw_floor_day_b20
    FROM table_composition
    WHERE psr_type = 'B20'
    GROUP BY date_ams, day_of_week, month_date, year_date
),
thermal_table AS (
    SELECT
        date_ams,
        SUM(pw_h_gen) AS day_th_energy_output
    FROM table_composition
    WHERE psr_type = 'B04' OR psr_type = 'B05'
    GROUP BY date_ams
)
SELECT 
    b.date_ams,
    day_of_week,
    month_date,
    year_date,
    pw_swing_day_b20,
    pw_floor_day_b20,
    day_th_energy_output
FROM b20_table b LEFT JOIN thermal_table t ON b.date_ams = t.date_ams;

-- SELECT * FROM b20_thermal_table LIMIT 20;