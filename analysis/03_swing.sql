-- Q3_SWING. Do load, generation and consumption swing at the same times as prices, and do
-- their extreme hours coincide with the extreme price hours.
--
-- Measurables: load, thermal output, daily extremes, hourly price.
-- Reads: table_h_price_load, table_composition, b20_thermal_table.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
-- The grouping must be identical on both sides of the comparison or it means nothing, so
-- price and every other series are profiled in the same statement, not in two.
--
-- One statement per grouping, and no statement groups by two axes at once: that is what
-- leaves 1.67 negative hours per group, where a min, a max and a quintile all return the
-- same number. The expected row count sits above each statement, so a statement that has
-- silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/03_swing.sql"

SET TimeZone = 'UTC';


-- G_HOUR: hour of day within the dataset. 24 groups, about 2,069 hours in each.
-- Expected rows: 24.



-- G_MONTH: month within the dataset. 12 groups, about 4,138 hours in each.
-- Expected rows: 12.
