# Data

Every source, unit and cleaning decision, recorded as it is made.

## Sources

### ENTSO-E Transparency Platform

API at `https://web-api.tp.entsoe.eu/api`, HTTPS only. It needs a personal security token: how to obtain one and provide it is under "Running it" in `README.md`.

#### Requests

Every request is an HTTPS `GET` to the base URL, whose query parameters name the dataset, the zone and the window, and always carry the token.

| Parameter | Meaning | Values used here |
|---|---|---|
| `securityToken` | the personal token, see "Running it" in `README.md` | from `ENTSOE_TOKEN` |
| `documentType` | **which dataset**, and therefore which kind of document comes back | `A65`, `A75`, `A44` |
| `processType` | **which version of that dataset**: realised values, or one of the forecasts | `A16` for load and generation; not sent for prices |
| zone parameter(s) | which **bidding zone**, the area that clears at one day-ahead price; the parameter's name depends on the dataset | see the next table |
| `periodStart`, `periodEnd` | the window, `YYYYMMDDHHmm`, in UTC | chosen per call |

The three datasets used:

| Dataset | `documentType` | `processType` | Zone parameter(s) | Document returned | Value in each point | Unit |
|---|---|---|---|---|---|---|
| Actual total load | `A65`, system total load | `A16`, realised | `outBiddingZone_Domain` | `GL_MarketDocument` | `quantity` | `MAW`, megawatts |
| Actual generation per production type | `A75`, actual generation per type | `A16`, realised | `in_Domain` | `GL_MarketDocument`, one `TimeSeries` per production type and direction, see "What a generation response contains" below | `quantity` | `MAW`, megawatts |
| Day-ahead prices | `A44`, price document | none | `in_Domain` and `out_Domain`, both the same zone | `Publication_MarketDocument` | `price.amount` | `EUR` per `MWH` |

The Netherlands is `10YNL----------L`. The client keeps each request to 300 days, below the API's limit of about one year.

**The document type decides the document family.** `A65` and `A75` are physical measurements and come back as `GL_MarketDocument`, carrying power in megawatts; `A44` is a market result and comes back as `Publication_MarketDocument`, carrying prices. Neither holds the other's quantity: `MWH` in a price document is the unit of the price, euros per megawatt hour. A request that cannot be answered with data returns an `Acknowledgement_MarketDocument` instead; every outcome a request can have, and what the client does about it, is in the docstring of `src/gridstress/client.py`.

**How the value and its unit are known.** Two independent sources agree.

1. **Each document states its own unit**, next to its data: `quantity_Measure_Unit.name` in load and generation, `currency_Unit.name` and `price_Measure_Unit.name` in prices. Every fixture under `tests/fixtures/` recorded from the API, fetched on 2026-09-16 and 2026-09-17, reads `MAW` for load and generation and `EUR` with `MWH` for prices. The same fixtures show which element holds the number: load and generation points hold `position` and `quantity`, price points `position` and `price.amount`, and nothing else.
2. **ENTSO-E defines the codes.** The [ENTSO-E General Code Lists for Data Interchange](https://eepublicdownloads.entsoe.eu/clean-documents/EDI/Library/Core/entso-e-code-list-v36r0.pdf), version 36, release 0, 2015-06-09, list 28 `StandardUnitOfMeasureTypeList`, defines `MAW` as "Mega watt", a unit of bulk power flow, and `MWH` as "Mega watt hours", the total amount of bulk energy transferred or consumed. `EUR` is the ISO 4217 code for the euro.

So a load or generation value is a power in megawatts, and a price is euros per megawatt hour of energy. A document reporting another unit would say so in the same elements.

#### How the API treats the requested window

Measured against the live API on 2026-09-18, for the Netherlands.

**Load and generation return exactly the interval requested.** A request for `2020-12-31T23:00Z` to `2021-01-03T23:00Z` came back as one `TimeSeries` with one `Period` of exactly that span, 288 points at `PT15M`. A 300-day `A75` window is answered in full, 20 series, about 50 MB, status `200`, so the client's window length is not near any limit.

**Day-ahead prices come back as whole Amsterdam calendar days, one `TimeSeries` per day.** A 30-day window returned 31 series and a 3-day window 4. Each series is one local day, 23:00Z to 23:00Z in winter and 22:00Z to 22:00Z in summer, with its own resolution, which changes once over the range: see "The resolution of each dataset, and when the price resolution changed" below. Every local day the requested interval touches is returned complete, so a request starting one hour into a day still returns that whole day. The boundary instant belongs to the day that begins at it: a start exactly on a local midnight includes that day, and an end exactly on one excludes the day beginning there. The request above returned exactly three price series, 1 to 3 January.

**Consequences.**

- **Request boundaries are Amsterdam local midnights expressed in UTC**: the previous day at 23:00Z in winter and 22:00Z in summer, switching on the last Sunday of March and of October at 01:00 UTC.
- **Windows are stepped in local days, not in 24-hour blocks**, or a clock change inside the range would move a boundary off local midnight. `window_edges` in `src/gridstress/client.py` does this, and `api_request` sends one request per pair of consecutive edges.
- **Without that alignment consecutive windows overlap**, each returning the local day that contains their shared boundary in full, so a price fetch of seven windows would deliver six duplicated days.
- **A price response has to be read series by series**, since a single-series read returns one day out of however many the window covers.

#### What load, generation and consumption are

All three datasets are published under [Commission Regulation (EU) No 543/2013](https://www.legislation.gov.uk/eur/2013/543/contents/adopted), the Transparency Regulation, whose adopted text gives the definitions below.

**Load** (`A65`) is the electricity used in the bidding zone per **market time unit**, the period one published value covers: a quarter-hour for load and generation, and for prices an hour until 2025-09-30 and a quarter-hour from 2025-10-01. Article 6(1)(a) requires publication of "the total load per market time unit", and [Article 2(27)](https://www.legislation.gov.uk/eur/2013/543/article/2/adopted) defines total load as "including losses without power used for energy storage", equal to "generation and any imports deducting any exports and power used for energy storage". Load says nothing about how the electricity was produced.

**Generation** (`A75`, series carrying `inBiddingZone_Domain`) is what the zone's power plants produce, by production type: [Article 16(1)(b)](https://www.legislation.gov.uk/eur/2013/543/article/16/adopted) requires "aggregated generation output per market time unit and per production type". The regulation does not define production type; the types are the ENTSO-E codes described under "What a generation response contains" below.

**Consumption per production type** (`A75`, series carrying `outBiddingZone_Domain`) is electricity used rather than produced, reported against a production type. The regulation does not mention it, Article 16 saying nothing of consumption or storage, and the only description read is the API parameter note that such series "reflect Consumption values", see "What a generation response contains" below. What it includes, a plant's own running needs or a storage plant charging for example, is not stated in any source read, so the series is used only as what that note says it is.

**Why load and generation differ.** Article 2(27) makes load a balance, per market time unit:

```
total load = generation + imports − exports − power used for energy storage      (grid losses included)
```

Load equals generation only when imports equal exports plus power put into storage. When generation is above load the difference leaves the zone or goes into storage; when it is below, the difference comes in from neighbouring zones. None of the three datasets records imports, exports or storage, so they cannot say which, and the regulation does not say whether the generation in this definition covers exactly the plants published per production type under Article 16(1)(b).

**Why both are needed.** Load gives how much the zone used, generation what it was produced from, and any share of solar or wind can only come from generation.

#### The resolution of each dataset, and when the price resolution changed

Established by `evidence/01_price_resolution.py`, which reads every response in `data/raw/`, fetched on 2026-09-20, covering the Amsterdam local days 2021-01-01 to 2026-08-31.

**Load and generation are `PT15M` throughout the range.** The seven `A65` responses carry one `Period` each and the seven `A75` responses twenty, one per production type, and all 147 are `PT15M`.

**Day-ahead prices change from `PT60M` to `PT15M` exactly once.** The last hourly `Period` begins `2025-09-29T22:00Z` and the first quarter-hourly one `2025-09-30T22:00Z`, the local days 2025-09-30 and 2025-10-01, and no hourly `Period` begins after that instant. Over the range, 1,734 price Periods are `PT60M` and 335 are `PT15M`.

**The change is a European market reform, not a Dutch publication change.** The Market Coupling Steering Committee confirmed the go-live of the 15-minute market time unit in Single Day-Ahead Coupling "on trading day 30 September 2025 for delivery day 1 October 2025", announced on [12 September 2025](https://www.ote-cr.cz/en/about-ote/ote-news/market-coupling-steering-committee-confirms-go-live-of-15-minute-mtu-in-sdac-on-trading-day-30-september-2025-for-delivery-day-1-october-2025), and [Austrian Power Grid reported on 1 October 2025](https://markt.apg.at/en/news-press/sdac-go-live-of-15-minute-market-time-unit-in-day-ahead-market-coupling-successful-as-of-september-30-2025/) that it "was successfully introduced on the trading day of 30 September 2025 for the delivery day of 1 October 2025 in all European bidding zones and across bidding zone borders". Delivery day 1 October 2025 is the first quarter-hourly local day in the data, so the published decision and the responses agree to the day.

**Resolution belongs to each series and has to be read from it.** Both resolutions occur inside one fetched file: the sixth price window, `202502082300` to `202512052300`, holds 234 hourly Periods followed by 66 quarter-hourly ones. No constant derived from the fetch can label a row; `2025-12-05` in particular is only the sixth window edge, 300 days after the fifth, with no meaning in the data.

**Nor can the number of points stand in for it.** Every Period in all three datasets carries `curveType` `A03`, whose block encoding is described under "What a generation response contains" below, so a Period routinely lists fewer points than its interval has positions. Hourly price days carry 17 to 25 points where a complete 23, 24 or 25-hour local day needs 23, 24 or 25; quarter-hourly ones carry 79 to 97 where a complete one needs 92, 96 or 100. The sparsest case is an `A75` series holding a single point for a whole 300-day window. Only the `resolution` element says what a position means.

#### What the generation figures count, and how they are computed

From ENTSO-E's [Detailed Data Descriptions](https://eepublicdownloads.entsoe.eu/clean-documents/Transparency/MoP_Ref2_DDD_v3r4.pdf), version 3 release 4, 15 December 2023, the reference the Manual of Procedures points to for each data item. **Aggregated generation per type** (page 74, Transparency Regulation articles 16.1.b and 16.2.b) is "Actual aggregated Net generation output (MW) per market time unit and per production type", calculated as follows:

> The actual generation shall be computed as the average of all available instantaneous Net generation output values on each market time unit. If a net generation output is not known, it shall be estimated. The actual generation of small-scale units might be estimated if no real-time measurement devices exist

- **Each value is an average over its market time unit**, not a snapshot, which is what makes megawatts the right unit and an hourly mean of quarter-hour values a meaningful quantity.
- **Small units are not excluded by rule.** Where no real-time meter exists the figure may be estimated, so part of the published output, particularly for solar, can be modelled rather than metered.
- **The often-quoted 1 MW threshold belongs to a different data item**, installed generation capacity aggregated (page 62, article 14.1.a), "the sum of generation capacity (MW) installed for all existing production units equaling to or exceeding 1 MW installed generation capacity, per production type". Nothing in the actual generation item sets a size threshold.

Wind and solar generation (article 16.1.c, page 75) is merged into the same data item, with primary owners given as "Owners of generating units and / or DSOs", so distributed generation reaches the platform through the distribution operators where they provide it.

**Not established:** whether the Dutch data provider includes behind-the-meter rooftop solar, and by what estimate. No document read sets a rule either way, so the solar figure cannot be assumed to be all Dutch solar production; what the data itself shows is under "What TenneT publishes per production type, and what it does not" below.

#### Day-ahead prices have a floor and a ceiling, and the floor moved

**Single Day-Ahead Coupling** (SDAC), which clears the coupled European day-ahead markets including the Netherlands, applies a harmonised minimum and maximum clearing price, set under the Harmonised Maximum and Minimum Clearing Prices methodology established under Article 41(1) of [Commission Regulation (EU) 2015/1222](https://www.legislation.gov.uk/eur/2015/1222/contents/adopted), the CACM Regulation.

| Limit | Value | In force | Source |
|---|---|---|---|
| Maximum | +4,000 EUR/MWh | Since 2022, after an automatic increase to +5,000 planned for 20 September 2022 was suspended following the Extraordinary Energy Council of 9 September 2022 | [Nord Pool operational message, 13 September 2022](https://www.nordpoolgroup.com/en/trading/Operational-Message-List/2022/09/no-changes-in-harmonised-maximum-clearing-price-for-sdac-from-20-september-it-remains-at-4000-eurmwh-20220913080000/) |
| Minimum | −500 EUR/MWh | Until 27 May 2026 | [SDAC communication note, 7 May 2026](https://www.nemo-committee.eu/assets/files/harmonised-minimum-clearing-price-for-sdac-to-be-set-to-600-eur-per-mwh-starting-from-the-28th-may-2026-(trading-date).pdf) |
| Minimum | −600 EUR/MWh | From trading date 28 May 2026, delivery date 29 May 2026 | the same note |

**The limits move by rule, not by judgement.** The methodology lowers the minimum by 100 EUR/MWh when the clearing price falls below 70% of the current minimum in at least two market time units, in one or more bidding zones, on at least two different days within 30 rolling days, and the new value applies four weeks after the second such event. Prices for delivery on 26 April 2026 and 1 May 2026 triggered the move to −600.

**What this means for the data.** A price exactly at a limit is the limit binding, so the most extreme prices are partly a property of these rules rather than of supply and demand. Because the minimum changed on 29 May 2026, a minimum, a most-negative value or any statistic of the tail is not comparable across that date without saying so.

#### What a generation response contains

Observed in `tests/fixtures/generation_nl_20260914.xml`, one Netherlands day, `2026-09-13T22:00Z` to `2026-09-14T22:00Z`, fetched on 2026-09-17.

The document holds 20 `TimeSeries`, each one `Period` covering the whole day, all with `curveType` `A03`, `resolution` `PT15M`, unit `MAW`, `businessType` `A01` and `objectAggregation` `A08`. The production type sits in `MktPSRType/psrType`. A series' children come in this order: `mRID`, `businessType`, `objectAggregation`, the domain element, `quantity_Measure_Unit.name`, `curveType`, `MktPSRType`, `Period`.

**Each production type appears twice, once per direction.** Ten series carry `inBiddingZone_Domain.mRID` and ten `outBiddingZone_Domain.mRID`, with the same ten `psrType` codes in each group, and no series carries both. Consumption series exist for every type present, not only for storage, and no storage type (`B10`) appears.

**How the meaning of the two directions is known.** The element a series carries is the only marker of direction, since both hold the same zone code, `10YNL----------L`. The API parameter notes for actual generation per production type state that a series with the `inBiddingZone_Domain` attribute reflects generation values and one with `outBiddingZone_Domain` reflects consumption values. ENTSO-E publishes its RESTful API documentation as a [Postman collection](https://documenter.getpostman.com/view/7009892/2s93JtP3F6); the wording cited is as reproduced in the [entsoe-apy documentation for `ActualGenerationPerProductionType`](https://entsoe-apy.berrisch.biz/ENTSOE/generation/), read on 2026-09-17. The magnitudes agree: fossil gas, nuclear and hard coal run in the thousands of megawatts in `in` and at or near zero in `out`.

| `psrType` | `in`, min to max (MW) | `out`, min to max (MW) |
|---|---|---|
| `B01` biomass | 0 to 0 | 2.819 to 6.745 |
| `B04` fossil gas | 2,847.206 to 8,074.588 | 41.736 to 146.154 |
| `B05` hard coal | 3,224.973 to 3,317.350 | 0 to 0 |
| `B11` hydro run-of-river | 0 to 0 | 0 to 0 |
| `B14` nuclear | 468.523 to 471.472 | 0 to 0 |
| `B16` solar | 0 to 224.436 | 0 to 0.518 |
| `B17` waste | 64.951 to 74.125 | 0 to 0 |
| `B18` wind offshore | 1.546 to 1,532.909 | 0.676 to 35.732 |
| `B19` wind onshore | 0.290 to 185.846 | 0 to 7.703 |
| `B20` other | 33.858 to 550.517 | 237.101 to 265.584 |

A series added up without looking at its direction counts consumption as generation.

**The `A03` block encoding is used in practice.** The day has 1,185 points where 20 series of 96 quarter hours would need 1,920. Under the **`A03` block encoding** a listed value holds until the next listed position or the end of the period, so omitted positions repeat the last value. Three shapes occur:

| Shape | Example | Listed positions |
|---|---|---|
| One value for the whole day | `B14` `out`, and five other series | position 1 only, value `0.0` |
| Gaps in the middle | `B16` `in` | `1`, then `29`, `30`, and so on; positions 2 to 28 omitted |
| Listing stops before the end | `B19` `out` | last listed position `68`, value `0.0`; positions 69 to 96 omitted |

A parser that treats each listed point as one quarter hour, or numbers points by their order in the file rather than by `position`, places values at the wrong times from the first omission onward.

**What the parser does not assume.** Two regularities hold in this response that no ENTSO-E document read for this project states: the Manual of Procedures v2.1, the General Code Lists v36r0, and the API parameter notes for this dataset. The parser therefore takes each series on its own terms.

- **That a production type has both a generation and a consumption series.** A type may appear in either direction or both, and the two are read and returned separately.
- **That all series share the same start, end and resolution.** Each `Period` states its own `timeInterval` and `resolution`, and each series' times are built from its own.

**Production type codes.** The `psrType` codes `B01` to `B20` are the production types defined in the same [General Code Lists](https://eepublicdownloads.entsoe.eu/clean-documents/EDI/Library/Core/entso-e-code-list-v36r0.pdf), list 2 `StandardAssetTypeList`, pages 7 and 8, and `sql/01_dim_production_type.sql` tables each with the code list's own name. Codes `B21` to `B24` are grid assets (AC link, DC link, substation, transformer), not production types, and no code beyond `B24` appears in version 36. The parser keeps the codes as they arrive, see "Production types stay as ENTSO-E codes in the parser" below.

## What the data can and cannot support

Two limits of the datasets themselves, what TenneT does not publish and what no market dataset measures, and two properties of these particular five and a half years, both established by `evidence/06_price_regimes.sql`.

### What TenneT publishes per production type, and what it does not

TenneT states, on the ENTSO-E page for this dataset: *"TenneT NL: The publication represents the generation identifiable per fuel type, if not identifiable the data is published as 'others' or not published."* Two things follow, and both bound what any figure here can mean.

**`B20 Other` is not a fuel.** It is the residue of output whose fuel TenneT could not determine, and for the Netherlands the largest single component of published generation: 4,046 MW mean and 15,643 MW at its highest hour, larger than fossil gas on both counts. Its behaviour separates into two parts that move in opposite seasons. Its **daily swing**, the day's maximum minus its minimum, runs 2,554 MW in December and 8,262 MW in June, the shape of sunlight; its **daily floor**, the day's minimum, runs 2,199 MW in January and 1,034 MW in August, the shape of a heating season. Neither part can be attributed to a named fuel from this source; both can be measured as behaviour.

**`B16 Solar` is therefore not Dutch solar output** but its identifiable part, transmission-connected plant. It follows the seasons, about 9 MW of mean output in December against 101 MW in June, but it does not grow: 47 to 67 MW of mean output in every year from 2021 to 2025 and in 2026 to August, and 428 MW at its highest hour, over a period in which installed Dutch solar capacity more than doubled, from 11.1 GW of panel capacity at the end of 2020 to 28.6 GW at the end of 2024, according to Statistics Netherlands (CBS), [*Hernieuwbare energie in Nederland 2024*](https://www.cbs.nl/nl-nl/longread/rapportages/2025/hernieuwbare-energie-in-nederland-2024/5-zonne-energie), table 5.1.1. A renewable share computed from `B16` understates solar by more than an order of magnitude.

**And "or not published" means summed generation is not total generation.** Every share whose denominator is `SUM(power_mw)` is a share of *published* generation, not of what the Netherlands generated.

**Eleven quarter-hours of `B20` are not physical, and all of them fall in 2023.** They run from 18,471 to 28,237 MW, and seven exceed the highest load the Netherlands recorded in the whole range, 20,718 MW: a single production type cannot out-produce national load by 36%. No other year contains a value above 16,000 MW. `load.py` logs the seven it drops, `evidence/04_generation_identifiability.sql` lists the four that remain, and their treatment is under "Seven generation values are impossible, and are dropped rather than corrected" below.

**Risk accepted.** The renewable share, and **residual load**, defined as `load − solar − wind`, cannot be computed from this source. Excluding and then including `B20` bounds them at 17.8% or 48.8% and at 10,399 MW or 6,353 MW, a range too wide for either to carry a conclusion, so a question needing them is answered from a different measurable or not here. The figures in this section regenerate from `evidence/04_generation_identifiability.sql`.

### Grid congestion is context, not a measured quantity

**Decision.** This analysis does not measure grid congestion. Load, generation per production type and day-ahead prices describe the bidding zone as a whole, and are used to study when prices are negative or extreme and what is produced and consumed then. Congestion appears in the framing, as the reason flexibility has value, and in the caveats, never as a result.

**Reasoning.** The Netherlands is a single bidding zone, so every participant clears at the same day-ahead price whatever the grid inside the zone can carry, and the price cannot express a local limit by construction. Congestion happens on particular lines, substations and regional grids, and all three datasets are national totals with no location in them. What would measure it is published under the same regulation, in [Article 13](https://www.legislation.gov.uk/eur/2013/543/article/13/adopted), "Information relating to congestion management measures": redispatching per market time unit with the network elements concerned, countertrading, and the monthly cost of both. Those are separate datasets with their own document types and grains, the monthly costs cannot sit at an hourly grain at all, and they cover transmission actions rather than the regional grids where Dutch connection queues are longest.

**Risk accepted.** Nothing in this analysis separates an hour of national oversupply from an hour when a particular region could not export what it generated, and no claim in the report may attribute a price to a local grid limit.

### The 2021 and 2022 price level is a gas-market event, and does not compare with the rest of the range

**What the data shows.** The median Dutch hourly day-ahead price by year: 78.3, 217.0, 99.2, 80.0 and 90.4 EUR/MWh for 2021 to 2025, and 108.1 for 2026 to August, 2022 sitting at roughly two and a half times every year after it. The rise is gradual and the fall abrupt: about 50 EUR/MWh through the spring of 2021, 78 in June, 133 in September, 226 in December, a peak of 449 in August 2022 and 139 by that October. The first extreme hours anywhere in the range are five hours in September 2021.

**What caused it is not measured here.** Day-ahead prices follow the gas price because gas-fired plant so often sets them: across the EU in 2022 it set the price 55% of the time while generating 19% of the electricity ([European Commission Joint Research Centre, *The Merit Order and Price-Setting Dynamics in European Electricity Markets*](https://publications.jrc.ec.europa.eu/repository/bitstream/JRC134300/JRC134300_01.pdf)). And 2021-22 was a gas supply crisis. Russian pipeline supplies to the EU fell by 24% year on year in the last quarter of 2021, with storage historically low going into that winter ([European Commission, quarterly market reports for the fourth quarter of 2021](https://commission.europa.eu/news-and-media/news/quarterly-market-reports-highlight-unprecedented-gas-and-power-prices-eu-q4-2021-2022-04-08_en)); after Russia invaded Ukraine on 24 February 2022 they fell by 74% year on year from July to September, and Nord Stream 1 stopped in September ([European Commission, 13 January 2023](https://energy.ec.europa.eu/news/new-reports-highlight-3rd-quarter-impact-gas-supply-cuts-2023-01-13_en)). Two supply problems unrelated to gas compounded 2022: stress-corrosion cracking took several French nuclear reactors offline for tests and repairs, and 2022 was France's second driest year on record, with hydro reserves at historic lows by mid-July ([RTE, *French Electricity Review 2022*](https://analysesetdonnees.rte-france.com/en/electricity-review-keyfindings)). None of this is in the three datasets, which hold no gas price, imports, exports or plant availability, so it is recorded as context and no figure in this project measures it.

**The band does not line up with calendar years**, which matters to anything that excludes it. The first eight months of 2021 hold no extreme hours and the cheapest prices in the range, a median of 61.2 EUR/MWh, with 65 negative hours; January and February 2023 still carry 19 extreme hours and medians of 131 and 132. The elevated period therefore runs 2021-09 to 2023-02, and `evidence/07_extreme_price_period.sql` compares what each candidate cut keeps. The project takes the period from **2023-03-01** onward as `table_h_price_post`. That discards the clean early months of 2021 as well, but leaves the remaining period contiguous, where cutting a band out of the middle would make any month-on-month or year-on-year reading discontinuous.

**Risk accepted.** Any statistic over price *levels* that spans 2022 mixes two regimes, and the extreme-hour flag concentrates in one of them by construction: 4,055 of the 4,956 extreme hours are in 2022 and 641 in 2021, leaving 47 to 80 a year afterwards, and 2021's are almost all in its last four months. A year-on-year count of extreme hours therefore tracks the gas price rather than anything about the Dutch grid. Statistics defined on the *sign* of the price are unaffected, which is part of why the negative flag is a sign test.

**Decision: both ranges, with the whole range as the reference.** Every question file runs over the whole range, and a **post-crisis** version, from 2023-03-01, is reported beside it wherever a finding changes with it. Restricting everything to the post-crisis range was rejected because it would remove most of the evidence some questions rest on: 261 of the 364 extreme days Q3 can test fall in 2021 and 2022. The finding that changes is Q4's period comparison, the **daily price gap**, a day's highest price minus its median, after the move to quarter-hours against the hourly years before it: with the crisis in the base, the before medians are inflated and the market appears to have narrowed by more than it did, by nearly three times in December. `analysis/04_shifting_gain.sql` carries both bases. Q1's extreme-hour findings carry the risk above, and Q2 and Q3 report each year as its own row, so the crisis years are visible rather than pooled.

### Negative hours rise across the range, and this source cannot attribute the rise

**What the data shows.** Negative hours per year: 70, 85, 316, 458, 592, and 449 in the 5,831 hours of a partial 2026. As a share of each year's hours that is 0.8%, 1.0%, 3.6%, 5.2% and 6.8% from 2021 to 2025, a rise in every full year. 2026 is not over, and its January to August, 7.7%, compares with 8.2% over the same months of 2025, from `analysis/01_negative_and_extreme.sql`: those months hold most of a year's negative hours, so a partial year is compared with the same months only. From 2021 to 2025 the mean hourly output of offshore wind (`B18`) doubles, 877 to 1,787 MW, and of the unidentifiable bucket (`B20`) grows 43%, 3,108 to 4,452 MW, while onshore wind (`B19`) peaks in 2023 at 952 MW and falls to 808.

**What cannot be attributed, and why.**

- *Solar growth is invisible.* Published solar's annual mean stays between 47 and 67 MW and its annual peak between 331 and 428 MW, for the reason under "What TenneT publishes per production type, and what it does not" above.
- *`B20`'s growth is not decomposable.* It is a mixture whose floor follows the heating season rather than the sun, and how much of its 43% growth is solar is exactly the quantity that leaves the renewable share bounded, under the same section above.
- *Efficiency cannot be measured.* A **capacity factor**, output as a share of what the installed fleet could produce, needs installed capacity, which none of the three datasets carries, so growing output says nothing about whether the fleet grew or improved.

**Risk accepted.** The rise in negative hours is a measurement; its cause is not. The project may state that negative hours grew and that offshore wind and the unidentifiable bucket grew alongside them while onshore wind did not, and no more. A claim that solar growth drives negative prices is not supportable from this source in either direction; what can be measured is the shift in the generation mix between flagged and unflagged hours, not its level.

## Decisions

### Timestamps stay in UTC until the time dimension

**Decision.** Every timestamp is kept in UTC from the request through parsing. Local Amsterdam time is derived once, in the time dimension, and nowhere earlier.

**Reasoning.** The API speaks UTC in both directions: `periodStart` and `periodEnd` are sent in UTC, and every timestamp in every document ends in `Z`. A UTC day always has 96 quarter hours, so the parser needs no knowledge of clock changes, where an Amsterdam calendar day does not: the day the clocks go forward is 23 hours, 92 quarter hours, and the day they go back is 25 hours, 100 quarter hours, as the fixtures for 2026-03-29 and 2025-10-26 show. Converting in one place handles the irregular days once rather than in every query.

**Risk accepted.** Nothing can be grouped by local hour, weekday or date before the time dimension: on the UTC timestamps a local 18:00 falls at 17:00 in winter and 16:00 in summer.

### Facts are stored at the source's resolution, and the analysis grain is the hour

**Decision.** Each fact table holds one row per market time unit exactly as ENTSO-E published it: load and price one row per market time unit, generation one per market time unit, production type and direction. Nothing is averaged before it is stored. The analysis works on an hourly table derived from those facts, every timestamp is UTC, and hour of day, day of week, month, year and the local labels come from the time dimension, which is also where the 23-hour and 25-hour local days are handled. An hour carries a flag for an event in any market time unit inside it, such as a negative price, computed from the fact rows rather than from the hourly average.

**Reasoning.** The hour is the finest grain the whole range supports, since prices are hourly through the local day 2025-09-30 and quarter-hourly from 2025-10-01, see "The resolution of each dataset, and when the price resolution changed" above: at a finer grain the years before and after would not compare. Averaging works in both directions, because each published value is itself an average over its market time unit, see "What the generation figures count, and how they are computed" above, so an hourly mean of megawatt values is that hour's energy in megawatt hours. Storing the facts unaveraged keeps every figure traceable to what the API returned, allows quarter-hour analysis for the years that support it, and is what makes the event flags correct: an hour with one quarter hour at −50 and three at +20 has a positive average and is still an hour with a negative price. Volume is no reason to aggregate early: five and a half years of all three datasets is on the order of four million rows, which DuckDB handles without effort.

**Risk accepted.** Two tables have to stay in step, and a figure quoted from the hourly table hides what happened inside the hour unless a flag was built for it. Every event definition is therefore decided at the fact grain and carried up deliberately; one that is forgotten silently becomes an hourly-average statement.

### Price is rolled up to the hour before it is profiled

**Decision.** Every statistic over price is computed from one value per hour, the mean of that hour's market time units, never from the market time units directly. The roll-up happens once, where the hourly table is built, before any grouping. Load and generation need no equivalent, being quarter-hourly across the whole range, but are still averaged rather than summed, for the reason under "Power is averaged over time and summed over production types, and energy is one multiplication away" below. Every hour holds four of their market time units, except the seven whose `B20` value was deleted, which hold three.

**Reasoning.** An hour of price is one published row before 2025-10-01 and four after, so a statistic grouped over market time units gives the quarter-hourly period four times the weight per hour. It is not a rounding difference: the mean price by hour of day moves by up to 11.35 EUR/MWh, around 12% of the value, all in the same direction across the middle of the day, which is exactly the shape the first question asks about. The figures regenerate from `evidence/03_hourly_grain.sql`.

Rolling up rather than repeating each hourly price across four quarter hours is a choice between two faithful options. Repeating is exact, since before 2025-10-01 one clearing price applied to every transaction in the hour. What decides it is comparability: a statistic over repeated market time units carries within-hour variation for the 8,040 hours that have any and structurally cannot for the other 41,615, so a year-on-year or month-by-year comparison would measure two different things and report one number.

Nor is the roll-up the chained aggregation the project avoids elsewhere, where unequal inner groups silently re-weight an outer statistic, as a mean of daily means does when days are 23, 24 and 25 hours long. An hour contributes either one published value or four equally weighted ones, so nothing inside it is unevenly weighted and the result is defined the same way across the range. The hourly price also means something on its own, being what it costs to consume flat power for that hour, where a daily median exists only as a description of a day. The roll-up constructs the unit of analysis; the grouping that follows is the single aggregation on top of it.

**Risk accepted.** No hourly statistic can say anything about movement inside an hour, and that movement is real: across the 8,040 quarter-hourly hours a price moves 23.99 EUR/MWh within the hour on average and as much as 549.32. It is not discarded but measured separately, on the part of the range that has it: `analysis/04_shifting_gain.sql` sets each post-change day's quarter-hour price gap against its hourly one.

### Power is averaged over time and summed over production types, and energy is one multiplication away

**Decision.** `load_mw` and `power_mw` are powers in megawatts, not energies, so every roll-up over *time* uses `AVG` and never `SUM`: an hour of load is `AVG(load_mw)`, an hour of one production type `AVG(power_mw)` over that hour's market time units, a day the mean of its hours. Summing is correct over the other axis, across production types at one instant, because powers flowing at the same moment add. The two axes take different functions in the same query, and a figure summed across both is neither a power nor an energy. Where an energy is wanted it is named, carries `mwh` rather than `mw`, and is derived rather than stored.

**Reasoning.** Both sources of the unit say power, see "How the value and its unit are known" under "Requests" above; `MWH` appears in this project only as the denominator of a price. A power is a rate, so adding four quarter-hourly readings gives four times the mean with the unit unchanged: 100 MW held for an hour is 100 MW, not 400. Nor is the divisor reliably four: the seven `B20` hours emptied by the deletion under "Seven generation values are impossible, and are dropped rather than corrected" below hold three market time units, so dividing a sum by a constant 4 is wrong exactly where the data is already thinnest, while `AVG` is right in all 496,550 hours without a special case.

**Energy follows from the same fact without a second measurement.** Each published value is already a mean over its market time unit, "the average of all available instantaneous Net generation output values on each market time unit", so the mean of those means over any window is the mean power over that window, and the energy is that mean times the window's length in hours. Over one hour the multiplier is 1, which is why an hourly mean in MW and the hour's energy in MWh are the same number and constantly confused; over a day it is 24, and over a quarter hour 0.25. Nothing is stored differently for energy; only the column's name and unit change. It is also why a price in EUR/MWh multiplies cleanly against an hourly mean in MW to give the cost of that hour.

**Risk accepted.** A column holding a mean and one holding a sum look identical in a table, and the only guard is the name. A `_mw` suffix on a summed column is a claim the numbers do not support, and it survives every later query silently, since a share whose numerator and denominator were summed the same way still sums to one. `validate.py` checks the derived tables' grain and that shares sum to one, not the units of their columns, so the discipline has to hold in the query that builds each table.

### A negative hour and an extreme hour are two separate flags, and the extreme bar is fixed at 225.00 EUR/MWh

**Decision.** The hourly table carries two independent booleans. An hour is **negative** when any of its market time units cleared below zero, `BOOL_OR(price < 0)`, decided at the fact grain rather than from the hourly mean. An hour is **extreme** when its hourly mean price is above **225.00 EUR/MWh**, the 0.90 quantile of hourly price across the whole range, computed once and then fixed, not recomputed per year or per month. No hour in the range is both, so the two sets are disjoint and never pooled into a single "event" flag.

**Reasoning.** The two ask opposite questions: a negative price is surplus, an hour with more electricity than the country can use, and an extreme price is scarcity. Their generation mixes move in opposite directions, and pooling them nets one against the other: in 2025 `B20`'s share is 46.38 points above its median in negative hours and 8.60 points below it in extreme hours, and a combined figure would report neither. The bar is fixed because a quantile recomputed inside each group defines away the thing being measured: a 0.90 quantile of 2022 and one of 2025 each select a tenth of their year by construction, so the count could never show that one year had more expensive hours than another. The quantile is taken of the hourly mean, for the reason under "Price is rolled up to the hour before it is profiled" above.

**Risk accepted.** A fixed bar lands unevenly, here almost entirely in 2022, as set out under "The 2021 and 2022 price level is a gas-market event, and does not compare with the rest of the range" above. That is a real property of the range, the gas crisis having genuinely produced those prices, but any statistic over extreme hours in a later year rests on a few dozen observations and is reported with its count beside it. The bar and the distribution of the hours it selects regenerate from `evidence/05_extreme_price.sql`. On the negative side, the floor moved from −500 to −600 on 29 May 2026, see "Day-ahead prices have a floor and a ceiling, and the floor moved" above, so the depth of the negative tail does not compare across that date, although the count of negative hours does, the flag being a sign test.

### Production types stay as ENTSO-E codes in the parser

**Decision.** The parser labels each generation and consumption series with its `psrType` code exactly as published, such as `B18`, and does not translate codes into names such as Wind Offshore. The code-to-name table is `sql/01_dim_production_type.sql`.

**Reasoning.** The only list of names read for this project is version 36 of the ENTSO-E code lists, dated 2015-06-09, and whether later versions add production types was not checked. A mapping inside the parser would have to cover every code the API may ever send, and a missing one would either stop the parse or produce an unnamed series, depending on a document that has not arrived yet. Keeping the code loses no information, since it is ENTSO-E's own identifier, and it cannot go out of date; names are presentation, and belong where the data is presented.

**Risk accepted.** Parsed output reads `B18`, not wind offshore, until the codes are joined to names. That join, in the production type dimension or the report, has to keep up with the code list, and a code it does not know shows up there without a name rather than stopping the parse.

### Seven generation values are impossible, and are dropped rather than corrected

**Decision.** `load.py` deletes every `fact_generation` row whose `power_mw` is greater than the largest `load_mw` in `fact_load`, 20,718.046 MW on the responses fetched on 2026-09-20. Seven rows go, all production type `B20` with `direction = 'in'` and all in 2023, Amsterdam local: 2023-04-08 19:00 (21,428.98 MW), 2023-04-11 11:00 (27,325.48), 2023-04-24 19:00 (22,605.90), 2023-04-27 11:00 (27,962.06), 2023-05-10 19:00 (20,994.88), 2023-05-13 11:00 (28,236.93) and 2023-08-27 10:15 (24,622.18). The deletion runs once every file is inserted, since the bound needs the complete load table, and before `validate`, inside the same transaction. The bound is read from the load table rather than written as a number, so it moves if the fetch window changes, and `validate.py` keeps the same rule as an invariant that now confirms the deletion rather than discovering anything.

**Reasoning.** These values are not readings. At 2023-05-13 11:00 one production type reports 28,236.93 MW while the whole country consumes 11,102.86 MW, and the surplus goes nowhere any of the three datasets records. Each is one market time unit wide between smooth neighbours, 4,528 MW then 21,429 MW then 4,032 MW, and generation cannot step up 17 GW and back inside fifteen minutes: commonly used gas-fired and hard-coal plants change output by 1.5% to 4% of their capacity a minute ([Agora Energiewende, *Flexibility in thermal power plants*, 2017](https://www.agora-energiewende.org/fileadmin/Projekte/2017/Flexibility_in_thermal_plants/115_flexibility-report-WEB.pdf), table 1). At those instants no other production type is unusual and load and price are ordinary, so the fault is in one published series rather than in the grid. The rows are deleted rather than corrected because nothing in the response says what the true value was, and interpolating would invent a reading carrying the same provenance as a real one; deleted rather than set null because a missing market time unit is what the data actually supports, so the hour averages the three intervals that were measured and `fact_generation: no null value` stays true.

**Risk accepted.** The bound removes the impossible, not the wrong, and those are not the same set. Of the eleven `B20` spikes of this shape in the 2023 data, the four the bound does not reach are the most extreme by **neighbour ratio**, the value over the larger of its two neighbours, up to 14x, because they sit just under the load maximum: 2023-04-14 03:00 (20,024.0 MW), 2023-04-30 03:00 (18,471.0), 2023-08-24 23:45 (19,772.8) and 2023-08-25 23:45 (19,621.0). A cluster of the same shape sits on 2026-01-06, at about twice its neighbours rather than five times, and how many intervals it contains depends entirely on the threshold: eight exceed 1.7 times the larger neighbour, five exceed 2.0, none exceeds 2.4. One `B17` consumption value of 3,657.9 MW on 2022-08-10 16:45 sits in a stretch where the series is otherwise zero, and one `B04` value of 5,348.5 MW on 2021-10-31 17:00 is three times its neighbours while being an ordinary output for gas. After the deletion the largest `B20` value in the database is 20,024.0 MW, one of the four that remain, so any `B20` statistic a single interval can move, a maximum above all, is still not to be trusted; statistics averaging over many intervals absorb them, seven faults being seven in 3,972,400 rows and the known remainder about twenty. A neighbour-ratio rule would catch the rest and was considered and not adopted: the 2026-01-06 cluster runs continuously from 1.74 up to 2.31 with no gap to cut at, so the threshold separating a fault from a real ramp is a judgement the data does not settle, and a wrong one silently deletes real generation. The seven deleted values are in the log `load.py` writes as it drops them; every other figure in this section regenerates from `evidence/04_generation_identifiability.sql`, section 6.

## What the database holds

Built by `python -m gridstress.load`, which runs every file in `sql/` and inserts every response in `data/raw/` inside a single transaction: the first three files declare the tables, the responses go in, the impossible generation values come out, the remaining three derive the analysis tables, and `validate.py` sees all of it before anything is committed. Built on 2026-10-05 from the responses fetched on 2026-09-20. The actual counts are logged by the loader as it commits; the expected ones come from `evidence/02_expected_row_counts.py`, which derives them from the fetch range and the documents' own metadata without opening the database.

| Table | One row is | Expected | Actual |
|---|---|---|---|
| `dim_production_type` | one ENTSO-E `psrType` code | 20 | 20 |
| `dim_time` | one hour, keyed on the UTC instant | 49,655 | 49,655 |
| `fact_load` | one market time unit | 198,620 | 198,620 |
| `fact_price` | one market time unit | 73,775 | 73,775 |
| `fact_generation` | one market time unit, production type and direction | 3,972,400 | 3,972,393 |
| `table_h_price_load` | one hour: price measures, the two event flags, load | 49,655 | 49,655 |
| `table_composition` | one hour and production type, generating only | 496,550 | 496,550 |
| `b20_thermal_table` | one Amsterdam local day | 2,069 | 2,069 |
| `table_h_price_post` | one hour, from 2023-03-01 | 30,719 | 30,719 |
| `table_price_unit` | one market time unit of price, with its local calendar | 73,775 | 73,775 |

**Where each expectation comes from.** `dim_time` and `fact_load` are the whole hours and the whole quarter hours between the two range boundaries, load being `PT15M` for every date in the range. `fact_price` is 41,615 hourly units through the local day 2025-09-30 plus 32,160 quarter-hourly units from 2025-10-01, split at the change described under "The resolution of each dataset, and when the price resolution changed" above. `fact_generation` is, for each `A75` window, the number of `TimeSeries` it carries times the quarter hours in the window. `dim_production_type` is the twenty production types `B01` to `B20` of code list v36r0.

The five derived tables follow from those. `table_h_price_load` is one row per hour, so it equals `dim_time`. `table_composition` is 49,655 hours times the ten production types the `A75` responses actually carry, generating direction only. `b20_thermal_table` is the Amsterdam local days in the range. `table_h_price_post` is the hours from 2023-03-01, 62% of them, for the reason under "The 2021 and 2022 price level is a gas-market event, and does not compare with the rest of the range" above. `table_price_unit` is `fact_price` row for row, the prices left at the grain they were published at rather than averaged into the hour, with `unit_minutes` read off each series' declared resolution: 60 for every unit through the local day 2025-09-30, 15 from 2025-10-01. It exists for the question of what a consumer gains from shifting load, whose quarter-hour part needs the units whole.

**The one gap, and why it is the expected size.** `fact_generation` holds seven rows fewer than the documents carry, exactly the seven deleted under "Seven generation values are impossible, and are dropped rather than corrected" above. The expectation is what the API published; the table is what survived the check. Every other count matches, which says the parser read every series it was given and the loader inserted every row it parsed.

**What the agreement establishes.** Every expectation was computed before the load and matched to the row, which rules out a window silently missing and rules out the `A03` fill generating too many or too few points. `fact_generation` was published as 1,986,200 rows in each direction, with ten production types on each side, and holds 1,986,193 generating rows after the seven deletions.

**And one question it settles.** No primary key was violated on any of the three fact tables, whose keys are `date_utc`, `date_utc` and `(date_utc, psr_type, direction)`. Consecutive windows therefore do not both return the boundary instant they share, which the behaviour described under "How the API treats the requested window" above left open; had they done so, the load would have failed rather than double-counted.

**The clock changes land where they should.** The per-file counts the loader logs show 28,796 rows for the `A65` window containing a spring change and 28,804 for the one containing an autumn change, against 28,800 for a window containing neither: one hour of quarter hours either way.
