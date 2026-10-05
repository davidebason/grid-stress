-- Q4_GAIN. What a consumer saves by choosing when to buy.
--
-- Measurables: daily price spread, spread inside the hour, load.
-- Reads: table_h_price_load, b20_thermal_table.
-- Never the fact tables: the grain was fixed in sql/04_hourly_tables.sql.
--
-- Carries a sensitivity across at least three assumptions: how many MWh are shiftable, how
-- much notice a shift needs, and whether it may cross a day boundary.
--
-- G_DOW is added only if the weekend turns out to be a different market.
--
-- One statement per grouping, and no statement groups by two axes at once: that is what
-- leaves 1.67 negative hours per group, where a min, a max and a quintile all return the
-- same number. The expected row count sits above each statement, so a statement that has
-- silently lost most of its data says so.
--
--     duckdb -readonly data/processed/grid.duckdb -c ".read analysis/04_shifting_gain.sql"

SET TimeZone = 'UTC';


-- G_MONTH: month within the dataset. 12 groups, about 4,138 hours in each.
-- Expected rows: 12.



-- G_YEAR: year within the dataset. 6 groups, about 8,712 hours in each.
-- Expected rows: 6.
