-- Run by `python -m gridstress.load`, before any response is inserted.
--
-- Production types: the psrType codes that arrive in A75 documents, and their names.
--
-- Source: ENTSO-E General Code Lists for Data Interchange, version 36 release 0, 2015-06-09,
-- list 2 StandardAssetTypeList, pages 7 and 8. The link, and the reasoning for keeping codes
-- rather than names in the parser, are in DATA.md.
--
-- Codes B21 to B24 in that list are not production types, so they are not rows here; DATA.md
-- says what they are. No code beyond B24 appears in version 36, so a later code would arrive in
-- the data without a row here.
--
-- name is the code list's own wording. name_sql is the same in lower case with underscores, safe
-- to use as a column or table name without quoting.

CREATE OR REPLACE TABLE dim_production_type (
    psr_type VARCHAR PRIMARY KEY,
    name     VARCHAR NOT NULL,
    name_sql VARCHAR NOT NULL
);

INSERT INTO dim_production_type (psr_type, name, name_sql) VALUES
    ('B01', 'Biomass',                         'biomass'),
    ('B02', 'Fossil Brown coal/Lignite',       'fossil_brown_coal_lignite'),
    ('B03', 'Fossil Coal-derived gas',         'fossil_coal_derived_gas'),
    ('B04', 'Fossil Gas',                      'fossil_gas'),
    ('B05', 'Fossil Hard coal',                'fossil_hard_coal'),
    ('B06', 'Fossil Oil',                      'fossil_oil'),
    ('B07', 'Fossil Oil shale',                'fossil_oil_shale'),
    ('B08', 'Fossil Peat',                     'fossil_peat'),
    ('B09', 'Geothermal',                      'geothermal'),
    ('B10', 'Hydro Pumped Storage',            'hydro_pumped_storage'),
    ('B11', 'Hydro Run-of-river and poundage', 'hydro_run_of_river_and_poundage'),
    ('B12', 'Hydro Water Reservoir',           'hydro_water_reservoir'),
    ('B13', 'Marine',                          'marine'),
    ('B14', 'Nuclear',                         'nuclear'),
    ('B15', 'Other renewable',                 'other_renewable'),
    ('B16', 'Solar',                           'solar'),
    ('B17', 'Waste',                           'waste'),
    ('B18', 'Wind Offshore',                   'wind_offshore'),
    ('B19', 'Wind Onshore',                    'wind_onshore'),
    ('B20', 'Other',                           'other');
