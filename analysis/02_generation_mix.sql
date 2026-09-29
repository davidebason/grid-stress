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
-- One statement per grouping, and no statement groups by two axes at once: that is what
-- leaves 1.67 negative hours per group, where a min, a max and a quintile all return the
-- same number. The expected row count sits above each statement, so a statement that has
-- silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/02_generation_mix.sql"

SET TimeZone = 'UTC';


-- G_MONTH: month within the dataset. 12 groups, about 4,138 hours in each.
-- Expected rows: 120.



-- G_YEAR: year within the dataset. 6 groups, about 8,712 hours in each.
-- Expected rows: 60.
