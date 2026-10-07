-- What TenneT publishes per production type, and what the unidentifiable bucket does.
--
-- Establishes the figures quoted under "What TenneT publishes per production type, and what it
-- does not" in DATA.md. Run against a database built by `python -m gridstress.load`:
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read evidence/04_generation_identifiability.sql"
--
-- Section 1 sizes each production type. Section 2 splits B20 into the part that follows the sun
-- and the part that does not. Section 3 shows why B16 cannot be a national solar figure.
-- Section 4 bounds the renewable share and residual load by excluding, then including, B20.

SET TimeZone = 'UTC';

-- One row per hour per production type, generation only. Averaging within a series before
-- summing across them is what keeps a quarter-hour from being counted as a separate plant.
CREATE OR REPLACE TEMP TABLE hourly_type AS
SELECT date_trunc('hour', date_utc) AS hour_utc, psr_type, AVG(power_mw) AS mw
FROM fact_generation
WHERE direction = 'in'
GROUP BY 1, 2;

-- 1. Every type present, largest first. Expect B20 Other at the top, above fossil gas.
SELECT h.psr_type, d.name,
       ROUND(MAX(h.mw), 1) AS peak_mw,
       ROUND(AVG(h.mw), 1) AS mean_mw
FROM hourly_type h
JOIN dim_production_type d USING (psr_type)
GROUP BY 1, 2
ORDER BY peak_mw DESC;

-- 2. B20 by month, split into its daily swing and its daily floor. Expect the swing to peak in
--    June at about 8,300 MW and the floor to peak in January at about 2,200 MW: opposite seasons.
WITH b20_daily AS (
    SELECT t.date_ams, t.month_date,
           MAX(h.mw) - MIN(h.mw) AS daily_swing_mw,
           MIN(h.mw)             AS daily_floor_mw
    FROM hourly_type h
    JOIN dim_time t ON h.hour_utc = t.date_utc
    WHERE h.psr_type = 'B20'
    GROUP BY 1, 2
)
SELECT month_date AS month,
       ROUND(AVG(daily_swing_mw), 0) AS mean_daily_swing_mw,
       ROUND(AVG(daily_floor_mw), 0) AS mean_daily_floor_mw
FROM b20_daily
GROUP BY 1
ORDER BY 1;

-- 3. B16 by year, against B20. Expect B16 flat near 50 to 70 MW mean while B20 grows.
SELECT t.year_date AS year,
       ROUND(AVG(CASE WHEN h.psr_type = 'B16' THEN h.mw END), 0) AS b16_mean_mw,
       ROUND(MAX(CASE WHEN h.psr_type = 'B16' THEN h.mw END), 0) AS b16_peak_mw,
       ROUND(AVG(CASE WHEN h.psr_type = 'B20' THEN h.mw END), 0) AS b20_mean_mw
FROM hourly_type h
JOIN dim_time t ON h.hour_utc = t.date_utc
GROUP BY 1
ORDER BY 1;

-- 3b. B16 by month, over the whole range. Expect it to follow the seasons, about 9 MW of mean
--     output in December against about 101 MW in June, while section 3 shows it flat from year
--     to year: the identifiable fleet behaves like solar and does not grow like it.
SELECT t.month_date AS month,
       ROUND(AVG(h.mw), 0) AS b16_mean_mw,
       ROUND(MAX(h.mw), 0) AS b16_peak_mw
FROM hourly_type h
JOIN dim_time t ON h.hour_utc = t.date_utc
WHERE h.psr_type = 'B16'
GROUP BY 1
ORDER BY 1;

-- 4. The renewable share and residual load, computed twice: excluding B20 from the renewables,
--    then including it. Expect 17.8% against 48.8%, and 10,399 MW against 6,353 MW.
WITH per_hour AS (
    SELECT hour_utc,
           SUM(CASE WHEN psr_type IN ('B16', 'B18', 'B19') THEN mw ELSE 0 END) AS labelled_renewable,
           SUM(CASE WHEN psr_type = 'B20' THEN mw ELSE 0 END)                  AS unidentifiable,
           SUM(mw)                                                             AS published_total
    FROM hourly_type
    GROUP BY 1
),
hourly_load AS (
    SELECT date_trunc('hour', date_utc) AS hour_utc, AVG(load_mw) AS load_mw
    FROM fact_load
    GROUP BY 1
)
SELECT
    ROUND(AVG(l.load_mw), 0)                                                        AS mean_load_mw,
    ROUND(100 * AVG(g.labelled_renewable / g.published_total), 1)                   AS renewable_share_excluding_b20_pc,
    ROUND(100 * AVG((g.labelled_renewable + g.unidentifiable) / g.published_total), 1) AS renewable_share_including_b20_pc,
    ROUND(AVG(l.load_mw - g.labelled_renewable), 0)                                 AS residual_load_excluding_b20_mw,
    ROUND(AVG(l.load_mw - g.labelled_renewable - g.unidentifiable), 0)              AS residual_load_including_b20_mw
FROM per_hour g
JOIN hourly_load l USING (hour_utc);

-- 5. Quarter-hours of B20 that exceed any plausible value. Eleven were published, all in 2023;
--    load.py drops the seven above the 20,718 MW peak load and logs each as it does, so expect
--    the four that remain, just under that peak.
SELECT date_utc,
       ROUND(power_mw, 1)                                    AS b20_mw,
       (SELECT ROUND(MAX(load_mw), 1) FROM fact_load)        AS peak_load_mw_anywhere_in_range
FROM fact_generation
WHERE direction = 'in' AND psr_type = 'B20' AND power_mw > 16000
ORDER BY power_mw DESC;

-- 6. The context DATA.md gives for the faults, under "Seven generation values are impossible, and
--    are dropped rather than corrected". Times in Amsterdam local, as DATA.md states them.

-- National load at the largest dropped B20 value, 2023-05-13 11:00. Expect 11,102.86 MW.
SELECT ROUND(load_mw, 2) AS load_mw
FROM fact_load
WHERE date_utc = TIMESTAMPTZ '2023-05-13 11:00:00+02';

-- The neighbours of the dropped 2023-04-08 19:00 value, which is itself gone. Expect 4,528 and
-- 4,032 MW.
SELECT date_utc AT TIME ZONE 'Europe/Amsterdam' AS local_time, ROUND(power_mw, 1) AS b20_mw
FROM fact_generation
WHERE psr_type = 'B20' AND direction = 'in'
  AND date_utc BETWEEN TIMESTAMPTZ '2023-04-08 18:45:00+02' AND TIMESTAMPTZ '2023-04-08 19:15:00+02'
ORDER BY date_utc;

-- The neighbour ratio, each B20 value over the larger of its two neighbours: for the four that
-- remain above 16,000 MW, then for the 2026-01-06 cluster at three thresholds. Expect 4 rows of
-- 6.9 to 14.1, then one row: 8, 5 and 0 intervals, ranging 1.74 to 2.31.
CREATE OR REPLACE TEMP TABLE b20_ratio AS
SELECT date_utc, power_mw,
       power_mw / GREATEST(LAG(power_mw) OVER w, LEAD(power_mw) OVER w) AS ratio
FROM fact_generation
WHERE psr_type = 'B20' AND direction = 'in'
WINDOW w AS (ORDER BY date_utc);

SELECT date_utc AT TIME ZONE 'Europe/Amsterdam' AS local_time, ROUND(power_mw, 1) AS b20_mw,
       ROUND(ratio, 1) AS neighbour_ratio
FROM b20_ratio
WHERE power_mw > 16000
ORDER BY date_utc;

SELECT COUNT(*) FILTER (WHERE ratio > 1.7)          AS above_1_7,
       COUNT(*) FILTER (WHERE ratio > 2.0)          AS above_2_0,
       COUNT(*) FILTER (WHERE ratio > 2.4)          AS above_2_4,
       ROUND(MIN(ratio) FILTER (WHERE ratio > 1.7), 2) AS lowest_above_1_7,
       ROUND(MAX(ratio), 2)                          AS highest
FROM b20_ratio
WHERE CAST(date_utc AT TIME ZONE 'Europe/Amsterdam' AS DATE) = DATE '2026-01-06';

-- The two other suspect values: B17 consumption on 2022-08-10 16:45, and B04 generation on
-- 2021-10-31 17:00 between its neighbours. Expect 3,657.9 MW, then 1,746.1, 5,348.5 and 1,753.3.
SELECT psr_type, direction, date_utc AT TIME ZONE 'Europe/Amsterdam' AS local_time,
       ROUND(power_mw, 1) AS mw
FROM fact_generation
WHERE (psr_type = 'B17' AND direction = 'out' AND date_utc = TIMESTAMPTZ '2022-08-10 16:45:00+02')
   OR (psr_type = 'B04' AND direction = 'in'
       AND date_utc BETWEEN TIMESTAMPTZ '2021-10-31 16:45:00+01'
                        AND TIMESTAMPTZ '2021-10-31 17:15:00+01')
ORDER BY psr_type, date_utc;

-- Rows per direction. Expect 1,986,200 consumption rows and 1,986,193 generation rows: equal
-- as published, until load.py drops the seven.
SELECT direction, COUNT(*) AS rows, COUNT(DISTINCT psr_type) AS production_types
FROM fact_generation
GROUP BY direction
ORDER BY direction;
