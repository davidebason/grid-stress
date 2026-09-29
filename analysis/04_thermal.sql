-- Q4_TH. How much of the price variation thermal output accounts for, and how much it does not.
--
-- Measurables: hourly price, thermal output, B20 daily swing, B20 daily floor.
-- Reads: table_composition, table_h_price_load, b20_thermal_table.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
-- A relationship rather than a profile. The yearly grouping is there to show whether the
-- relationship itself weakens as more of what sets the price stops being burned.
--
-- One statement per grouping, and no statement groups by two axes at once: that is what
-- leaves 1.67 negative hours per group, where a min, a max and a quintile all return the
-- same number. The expected row count sits above each statement, so a statement that has
-- silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/04_thermal.sql"

SET TimeZone = 'UTC';


-- G_YEAR: year within the dataset. 6 groups, about 8,712 hours in each.
-- Expected rows: 6.
