# Data

Every source, unit and cleaning decision, recorded as it is made.

## Sources

### ENTSO-E Transparency Platform

API at `https://web-api.tp.entsoe.eu/api`, HTTPS only.

#### Access

The API requires a personal security token, which is free but issued by hand.

1. Register an account at [transparency.entsoe.eu](https://transparency.entsoe.eu).
2. Email `transparency@entsoe.eu` with the subject `RESTful API access` and the registered email address in the body.
3. Once access is granted, generate the token under the account settings of the Transparency Platform website.

The code reads the token from the environment variable `ENTSOE_TOKEN` and from nowhere else. It is never stored in the repository. One way to provide it on Linux or WSL, keeping the token in a file only your user can read and exporting it in every new terminal:

```bash
mkdir -p ~/.config/entsoe
nano ~/.config/entsoe/token          # paste the token as the file's only content, then save
chmod 600 ~/.config/entsoe/token
echo 'export ENTSOE_TOKEN="$(< ~/.config/entsoe/token)"' >> ~/.bashrc
source ~/.bashrc
```

To confirm it is set without printing it, `echo "${#ENTSOE_TOKEN}"` should print `36`.

If the variable is not set, every fetch stops before sending any request, with `KeyError: 'ENTSOE_TOKEN'`.

The API takes the token as the `securityToken` query parameter, so it is part of every request URL. Do not share logs, tracebacks or screenshots that show a full request URL.

#### Requests

Every request is an HTTPS `GET` to the base URL with query parameters. The parameters say which dataset is wanted, for which zone and over which window; the security token is always one of them.

| Parameter | Meaning | Values used here |
|---|---|---|
| `securityToken` | the personal token, see Access above | from `ENTSOE_TOKEN` |
| `documentType` | **which dataset**, and therefore which kind of document comes back | `A65`, `A75`, `A44` |
| `processType` | **which version of that dataset**: realised values, or one of the forecasts | `A16` for load and generation; not sent for prices |
| zone parameter(s) | which bidding zone; the parameter's name depends on the dataset | see below |
| `periodStart`, `periodEnd` | the window, `YYYYMMDDHHmm`, in UTC | chosen per call |

The three datasets this project uses:

| Dataset | `documentType` | `processType` | Zone parameter(s) | Document returned | Value in each point | Unit |
|---|---|---|---|---|---|---|
| Actual total load | `A65`, system total load | `A16`, realised | `outBiddingZone_Domain` | `GL_MarketDocument` | `quantity` | `MAW`, megawatts |
| Actual generation per production type | `A75`, actual generation per type | `A16`, realised | `in_Domain` | `GL_MarketDocument`, one `TimeSeries` per production type and direction, see below | `quantity` | `MAW`, megawatts |
| Day-ahead prices | `A44`, price document | none | `in_Domain` and `out_Domain`, both the same zone | `Publication_MarketDocument` | `price.amount` | `EUR` per `MWH` |

The Netherlands is `10YNL----------L`. The window of one request is kept to 300 days by the client, below the API's limit of about one year.

**The document type decides the document family.** `A65` and `A75` are physical measurements and come back as `GL_MarketDocument` (generation and load), carrying power in megawatts. `A44` is a market result and comes back as `Publication_MarketDocument`, carrying prices. Neither family carries the other's quantity: a price document holds no energy or power, and `MWH` in it is the unit of the price, euros per megawatt hour. When a request cannot be answered with data, whatever its document type, an `Acknowledgement_MarketDocument` comes back instead, see API errors below.

**How the value and its unit are known.** Two independent sources, which agree.

1. **Each document states its own unit.** Every `TimeSeries` carries a unit element next to its data: `quantity_Measure_Unit.name` in load and generation documents, `currency_Unit.name` and `price_Measure_Unit.name` in price documents. In every fixture under `tests/fixtures/` recorded from the API, fetched on 2026-09-16 and 2026-09-17, these read `MAW` for load and generation, and `EUR` with `MWH` for prices. Which element inside a `Point` carries the number, `quantity` or `price.amount`, was read from the same fixtures: load and generation points hold `position` and `quantity`, price points hold `position` and `price.amount`, and nothing else.
2. **ENTSO-E defines the codes.** The [ENTSO-E General Code Lists for Data Interchange](https://eepublicdownloads.entsoe.eu/clean-documents/EDI/Library/Core/entso-e-code-list-v36r0.pdf), version 36, release 0, 2015-06-09, list 28 `StandardUnitOfMeasureTypeList`, defines `MAW` as "Mega watt", a unit of bulk power flow, and `MWH` as "Mega watt hours", the total amount of bulk energy transferred or consumed. `EUR` is the ISO 4217 code for the euro.

So a load or generation value is a power in megawatts, and a price is euros per megawatt hour of energy. The unit belongs to the document a value came from: a document reporting a different unit code would say so in these same elements.

#### What load, generation and consumption are

All three datasets are published under [Commission Regulation (EU) No 543/2013](https://www.legislation.gov.uk/eur/2013/543/contents/adopted), the Transparency Regulation, whose adopted text is the source for the definitions below.

**Load** (`A65`) is how much electricity is used in the bidding zone, per market time unit. Article 6(1)(a) requires publication of "the total load per market time unit", and [Article 2(27)](https://www.legislation.gov.uk/eur/2013/543/article/2/adopted) defines total load as "including losses without power used for energy storage", equal to "generation and any imports deducting any exports and power used for energy storage". Load says nothing about how the electricity was produced.

**Generation** (`A75`, series carrying `inBiddingZone_Domain`) is how much electricity the zone's power plants produce, split by production type. [Article 16(1)(b)](https://www.legislation.gov.uk/eur/2013/543/article/16/adopted) requires publication of "aggregated generation output per market time unit and per production type". The regulation does not define production type; the types are the ENTSO-E codes tabled under What a generation response contains below.

**Consumption per production type** (`A75`, series carrying `outBiddingZone_Domain`) is electricity used rather than produced, reported against a production type. It is not mentioned in the regulation: Article 16 says nothing about consumption or storage. The only description read for this project is the API parameter note that such series "reflect Consumption values", see the directions below. What it includes, for example a plant's own running needs or a storage plant charging, is not stated in any source read, and the series is used here only as what that note says it is.

**Why load and generation differ.** Article 2(27) makes load a balance, per market time unit:

```
total load = generation + imports − exports − power used for energy storage      (grid losses included)
```

Load equals generation only when imports equal exports plus power put into storage. When generation is above load, the difference is leaving the zone or going into storage; when load is above generation, the difference is coming in from neighbouring zones. None of the three datasets used here records imports, exports or storage, so they cannot say which. The regulation also does not state whether the generation in this definition covers exactly the same plants as the generation published per production type under Article 16(1)(b).

**Why both are needed.** Load gives how much the zone used; generation gives what it was produced from. Any share of solar or wind can only come from generation, since load carries no production type.

#### How the API treats the requested window

Measured against the live API on 2026-09-18, for the Netherlands.

**Load and generation return exactly the interval requested.** A request for `2020-12-31T23:00Z` to `2021-01-03T23:00Z` came back as one `TimeSeries` with one `Period` of exactly that span, 288 points at `PT15M`. A 300-day window of `A75` is answered in full: 20 series, about 50 MB, status `200`, so the window length the client uses is not near any limit.

**Day-ahead prices come back as whole Amsterdam calendar days, one `TimeSeries` per day.** A 30-day window returned 31 series; a 3-day window returned 4. Each series carries one `Period` of one local day, running 23:00Z to 23:00Z in winter and 22:00Z to 22:00Z in summer, and each has its own resolution, which changes once over the range: see The resolution of each dataset below.

**The rule the responses follow:** every local day the requested interval touches is returned complete. A request starting one hour into a day still returns that whole day. The boundary instant belongs to the day that begins at it, so a start exactly on a local midnight includes that day and an end exactly on a local midnight excludes the day beginning there. A request for `2020-12-31T23:00Z` to `2021-01-03T23:00Z` returned exactly three price series, 1 to 3 January.

**Consequences.**

- **Request boundaries are Amsterdam local midnights expressed in UTC**, which is the previous day at 23:00Z in winter and 22:00Z in summer. The offset changes on the last Sunday of March and of October, at 01:00 UTC.
- **Window boundaries are stepped in local days, not in 24-hour blocks**, otherwise a clock change inside the range moves a boundary off local midnight and back into the widening behaviour above. `window_edges` in `src/gridstress/client.py` does this, and `api_request` sends one request per pair of consecutive edges.
- **Without that alignment, consecutive windows overlap**: the local day containing a boundary is returned in full by both windows, so a price fetch of seven windows would deliver six duplicated days.
- **A price response has to be read series by series**, since a single-series read returns one day out of however many the window covers.

#### The resolution of each dataset, and when the price resolution changed

Established by `evidence/01_price_resolution.py`, which reads every response in `data/raw/`, fetched on 2026-09-20, covering the Amsterdam local days 2021-01-01 to 2026-08-31.

**Load and generation are `PT15M` throughout the range.** Each of the seven `A65` responses carries one `Period` and each of the seven `A75` responses carries twenty, one per production type. All 147 of those Periods are `PT15M`, and no resolution change appears anywhere in the range.

**Day-ahead prices change from `PT60M` to `PT15M` exactly once.** The last hourly `Period` begins `2025-09-29T22:00Z` and the first quarter-hourly one begins `2025-09-30T22:00Z`; no hourly `Period` begins after that instant. Those are the local days 2025-09-30 and 2025-10-01. Over the range, 1,734 price Periods are `PT60M` and 335 are `PT15M`.

**The change is a European market reform, not a Dutch publication change.** The Market Coupling Steering Committee confirmed the go-live of the 15-minute market time unit in Single Day-Ahead Coupling "on trading day 30 September 2025 for delivery day 1 October 2025", announced on [12 September 2025](https://www.ote-cr.cz/en/about-ote/ote-news/market-coupling-steering-committee-confirms-go-live-of-15-minute-mtu-in-sdac-on-trading-day-30-september-2025-for-delivery-day-1-october-2025), and [Austrian Power Grid reported on 1 October 2025](https://markt.apg.at/en/news-press/sdac-go-live-of-15-minute-market-time-unit-in-day-ahead-market-coupling-successful-as-of-september-30-2025/) that it "was successfully introduced on the trading day of 30 September 2025 for the delivery day of 1 October 2025 in all European bidding zones and across bidding zone borders". Delivery day 1 October 2025 is the first quarter-hourly local day in the data, so the published decision and the responses agree to the day.

**Resolution is a property of the individual series and has to be read from it.** Both resolutions occur inside a single fetched file: the sixth price window, `202502082300` to `202512052300`, holds 234 hourly Periods followed by 66 quarter-hourly ones. A row therefore cannot be labelled from any constant derived from the fetch, and in particular `2025-12-05` is the sixth window edge, 300 days after the fifth, with no meaning in the data.

**The number of points cannot stand in for the resolution.** Every Period in all three datasets carries `curveType` `A03`, whose block encoding is described under What a generation response contains below, so a Period routinely lists fewer points than its interval has positions. Hourly price days carry 17 to 25 points where a complete 23, 24 or 25-hour local day needs 23, 24 or 25; quarter-hourly price days carry 79 to 97 where a complete one needs 92, 96 or 100. The sparsest case in the range is an `A75` series holding a single point for a whole 300-day window. The `resolution` element is the only source for what a position means.

#### What the generation figures count, and how they are computed

From ENTSO-E's [Detailed Data Descriptions](https://eepublicdownloads.entsoe.eu/clean-documents/Transparency/MoP_Ref2_DDD_v3r4.pdf), version 3 release 4, 15 December 2023, the reference document the Manual of Procedures points to for each data item.

**Aggregated generation per type** (page 74, Transparency Regulation articles 16.1.b and 16.2.b) is described as "Actual aggregated Net generation output (MW) per market time unit and per production type", and its calculation as:

> The actual generation shall be computed as the average of all available instantaneous Net generation output values on each market time unit. If a net generation output is not known, it shall be estimated. The actual generation of small-scale units might be estimated if no real-time measurement devices exist

Three things follow.

- **Each value is an average over its market time unit**, not a snapshot, which is what makes megawatts the right unit and makes the hourly mean of quarter-hour values a meaningful quantity.
- **Small units are not excluded by rule.** Where no real-time meter exists the figure may be an estimate rather than a measurement, so part of the published output, particularly for solar, can be modelled rather than metered.
- **The 1 MW threshold that is often quoted belongs to a different data item.** It appears in installed generation capacity aggregated (page 62, article 14.1.a), "the sum of generation capacity (MW) installed for all existing production units equaling to or exceeding 1 MW installed generation capacity, per production type". Nothing in the actual generation item sets a size threshold.

Wind and solar generation (article 16.1.c, page 75) is merged into the same data item, and its primary owners are given as "Owners of generating units and / or DSOs", so distributed generation reaches the platform through the distribution operators where they provide it.

**What is still not established:** whether the Dutch data provider includes behind-the-meter rooftop solar in these figures, and if so by what estimate. The documents read set no rule either way, which means the solar figure cannot be assumed to be all Dutch solar production. Any statement about solar share carries that qualification until it is settled with the data provider.

#### What TenneT publishes per production type, and what it does not

TenneT states, on the ENTSO-E page for this dataset: *"TenneT NL: The publication represents the generation identifiable per fuel type, if not identifiable the data is published as 'others' or not published."* Two things follow, and both bound what any figure on this page can mean.

**`B20 Other` is not a fuel.** It is the residue of output whose fuel TenneT could not determine, and for the Netherlands it is the largest single component of published generation: 4,046 MW mean and 15,943 MW at its highest hour, larger than fossil gas on both counts. Its behaviour separates into two parts that move in opposite seasons. Its daily swing, the day's maximum minus its minimum, runs 2,554 MW in December and 8,262 MW in June, which is the shape of sunlight. Its daily floor runs the other way, 2,199 MW in January and 1,034 MW in August, which is the shape of a heating season. Neither part can be attributed to a named fuel from this source; both can be measured as behaviour.

**`B16 Solar` is therefore not Dutch solar output.** It is the part that is identifiable, meaning transmission-connected plant: 428 MW at its highest hour across the whole range, and flat at 47 to 67 MW of mean output from 2021 to 2026, a period over which installed Dutch solar capacity roughly doubled. Any renewable share computed from `B16` understates solar by more than an order of magnitude.

**And "or not published" means summed generation is not total generation.** Every share whose denominator is `SUM(power_mw)` is a share of *published* generation, not of what the Netherlands generated.

**Eleven quarter-hours of `B20` are not physical, and all of them fall in 2023.** They run from 18,471 to 28,237 MW, and seven of them exceed the highest load the Netherlands recorded in the whole range, 20,718 MW. A single production type cannot out-produce national demand by 36%. No other year contains a value above 16,000 MW. They are listed by `evidence/04_generation_identifiability.sql`. Those seven are deleted by the loader, for the reasons under Seven generation values are impossible below; the remaining four are still in the data, so any statistic over `B20` that uses a maximum rather than a median still inherits them.

**Risk accepted.** The renewable share, and residual load defined as `load − solar − wind`, cannot be computed from this source. Bounding them by excluding and then including `B20` gives a renewable share of 17.8% or 48.8% and a residual load of 10,399 MW or 6,353 MW, a range too wide for either to carry a conclusion. Any question needing those quantities is answered from a different measurable or is not answered here. The figures in this section regenerate from `evidence/04_generation_identifiability.sql`.

#### Day-ahead prices have a floor and a ceiling, and the floor moved

Day-ahead prices are not free to take any value. Single Day-Ahead Coupling (SDAC), the mechanism that clears the coupled European day-ahead markets including the Netherlands, applies a harmonised minimum and maximum clearing price, set under the Harmonised Maximum and Minimum Clearing Prices methodology, itself established under Article 41(1) of [Commission Regulation (EU) 2015/1222](https://www.legislation.gov.uk/eur/2015/1222/contents/adopted) (the CACM Regulation).

| Limit | Value | In force | Source |
|---|---|---|---|
| Maximum | +4,000 EUR/MWh | Since 2022, after an automatic increase to +5,000 planned for 20 September 2022 was suspended following the Extraordinary Energy Council of 9 September 2022 | [Nord Pool operational message, 13 September 2022](https://www.nordpoolgroup.com/en/trading/Operational-Message-List/2022/09/no-changes-in-harmonised-maximum-clearing-price-for-sdac-from-20-september-it-remains-at-4000-eurmwh-20220913080000/) |
| Minimum | −500 EUR/MWh | Until 27 May 2026 | [SDAC communication note, 7 May 2026](https://www.nemo-committee.eu/assets/files/harmonised-minimum-clearing-price-for-sdac-to-be-set-to-600-eur-per-mwh-starting-from-the-28th-may-2026-(trading-date).pdf) |
| Minimum | −600 EUR/MWh | From trading date 28 May 2026, delivery date 29 May 2026 | the same note |

**The limits move by rule, not by judgement.** The methodology lowers the minimum by 100 EUR/MWh when the clearing price falls below 70% of the current minimum in at least two market time units, in one or more bidding zones, on at least two different days within 30 rolling days, and the new value applies four weeks after the second such event. The move to −600 was triggered by prices reached for delivery on 26 April 2026 and 1 May 2026.

**What this means for the data.** The most extreme prices in the range are partly a property of these rules rather than of supply and demand: a price exactly at a limit is the limit binding. Because the minimum changed on 29 May 2026, the lowest price reachable is not the same throughout the range, so a minimum, a most-negative value, or any statistic of the tail is not comparable across that date without saying so.

#### What a generation response contains

Observed in `tests/fixtures/generation_nl_20260914.xml`, one Netherlands day, `2026-09-13T22:00Z` to `2026-09-14T22:00Z`, fetched on 2026-09-17.

The document holds 20 `TimeSeries`, each with one `Period` covering the whole day. All 20 have `curveType` `A03`, `resolution` `PT15M`, unit `MAW`, `businessType` `A01` and `objectAggregation` `A08`. The production type sits in `MktPSRType/psrType` inside each series. The children of a series come in this order: `mRID`, `businessType`, `objectAggregation`, the domain element, `quantity_Measure_Unit.name`, `curveType`, `MktPSRType`, `Period`.

**On this day, each production type appears twice, once per direction.** Ten series carry `inBiddingZone_Domain.mRID` and ten carry `outBiddingZone_Domain.mRID`, with the same ten `psrType` codes in each group, and no series carries both. In this response, therefore, each of the ten types present has one `in` series and one `out` series. Consumption series exist for every type in the response, not only for storage; no storage type (`B10`) appears on this day.

**How the meaning of the two directions is known.** Two sources.

1. **The documents.** Which element a series carries, and so which direction it is, is read from the fixture above; the element names are the only marker of direction, since both hold the same zone code, `10YNL----------L`.
2. **The API documentation for this dataset.** The parameter notes for actual generation per production type state that a time series with the `inBiddingZone_Domain` attribute reflects generation values, and one with the `outBiddingZone_Domain` attribute reflects consumption values. ENTSO-E publishes its RESTful API documentation as a [Postman collection](https://documenter.getpostman.com/view/7009892/2s93JtP3F6); the wording cited here is as reproduced in the [entsoe-apy documentation for `ActualGenerationPerProductionType`](https://entsoe-apy.berrisch.biz/ENTSOE/generation/), read on 2026-09-17.

The magnitudes are consistent with that reading: fossil gas, nuclear and hard coal run in the thousands of megawatts in `in` and at or near zero in `out`. The two directions differ by orders of magnitude:

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

**The `A03` block encoding is used in practice.** The day has 1,185 points where 20 series of 96 quarter hours would need 1,920. Under `A03` a listed value holds until the next listed position, or until the end of the period, so omitted positions repeat the last value. Three shapes occur:

| Shape | Example | Listed positions |
|---|---|---|
| One value for the whole day | `B14` `out`, and five other series | position 1 only, value `0.0` |
| Gaps in the middle | `B16` `in` | `1`, then `29`, `30`, and so on; positions 2 to 28 omitted |
| Listing stops before the end | `B19` `out` | last listed position `68`, value `0.0`; positions 69 to 96 omitted |

A parser that treats each listed point as one quarter hour, or numbers points by their order in the file rather than by `position`, places values at the wrong times from the first omission onward.

**What the parser does not assume.** Two regularities hold in this response, and neither is stated in any ENTSO-E documentation read for this project: the Manual of Procedures v2.1, the General Code Lists v36r0, and the API parameter notes for this dataset. The parser therefore treats every series on its own terms.

- **That a production type has both a generation and a consumption series.** A type may appear in one direction only, in either, or in both, and the two directions are read and returned separately.
- **That all series share the same start, end and resolution.** Each `Period` states its own `timeInterval` and `resolution`, and each series' times are built from its own.

**Production type codes.** The `psrType` codes are defined in the same [ENTSO-E General Code Lists](https://eepublicdownloads.entsoe.eu/clean-documents/EDI/Library/Core/entso-e-code-list-v36r0.pdf), version 36, release 0, list 2 `StandardAssetTypeList`, pages 7 and 8. Codes `B01` to `B20` are production types, named there as follows:

| Code | Name in the code list | Code | Name in the code list |
|---|---|---|---|
| `B01` | Biomass | `B11` | Hydro Run-of-river and poundage |
| `B02` | Fossil Brown coal/Lignite | `B12` | Hydro Water Reservoir |
| `B03` | Fossil Coal-derived gas | `B13` | Marine |
| `B04` | Fossil Gas | `B14` | Nuclear |
| `B05` | Fossil Hard coal | `B15` | Other renewable |
| `B06` | Fossil Oil | `B16` | Solar |
| `B07` | Fossil Oil shale | `B17` | Waste |
| `B08` | Fossil Peat | `B18` | Wind Offshore |
| `B09` | Geothermal | `B19` | Wind Onshore |
| `B10` | Hydro Pumped Storage | `B20` | Other |

Codes `B21` to `B24` in the same list are grid assets (AC link, DC link, substation, transformer), not production types. No code beyond `B24` appears in version 36. The parser keeps the codes as they arrive and does not translate them to these names; see Decisions below.

#### API errors

What one request can come back as, and what the client does about it. For every outcome other than success the client prints the window, the attempt number and the failure.

**Acceptable.** A `200` carrying a `GL_MarketDocument` (load, generation) or a `Publication_MarketDocument` (prices). A window with no published data arrives instead as an `Acknowledgement_MarketDocument` containing `No matching data found`, and asking again returns the same answer. A window a year in the future, queried on 2026-09-16, came back under a `200`; the same document is also reported under a `400`, so the status code alone does not identify it.

**Retried**, because a later attempt may succeed. The wait doubles between attempts, and none follows the last attempt.

| Failure | How it arrives |
|---|---|
| `ConnectTimeout` | raised: the server did not accept the connection in time |
| `ReadTimeout` | raised: the answer did not finish in time |
| `Timeout` | raised: the base class of the two above |
| `ConnectionError` | raised: DNS failure, connection refused or reset, network unreachable |
| `ChunkedEncodingError` | raised: the connection broke while the body was arriving |
| `ContentDecodingError` | raised: the compressed body could not be unpacked |
| Any `5xx` status | returned: `500`, `502`, `503` and `504`, typically during ENTSO-E maintenance |

**Not retried**, because the same request gives the same answer. The window is not fetched.

| Failure | How it arrives | What to do |
|---|---|---|
| `400` | returned | A parameter is wrong: document type, process type, a zone parameter's name, a date, or a window longer than the API allows. The body names the reason |
| `401` | returned | The token is missing, wrong, or not yet activated. Check `ENTSOE_TOKEN` |
| `403` | returned | Access refused for that data |
| `404` | returned | The base URL is wrong |
| `429` | returned | The limit of 400 requests per minute, per IP and per token, has been passed. ENTSO-E blocks for about ten minutes: wait that long, then run again |
| `SSLError` | raised | Certificate or TLS failure, often a wrong system clock or an intercepting proxy. It is a `ConnectionError`, so it is excluded by name rather than by family |
| `ProxyError` | raised | The proxy refused the connection |
| `TooManyRedirects` | raised | A redirect loop |
| `InvalidURL`, `MissingSchema`, `InvalidSchema`, `InvalidProxyURL`, `InvalidHeader`, `URLRequired` | raised | The request was built wrongly, so the fault is in the client rather than at the far end |

**Before any request is sent.** A missing `ENTSOE_TOKEN` raises `KeyError`. A date that is not twelve digits in `YYYYMMDDHHmm`, a range whose two dates coincide, or an end before its start, is reported as a message and nothing is sent.

**Never printed.** The token travels as the `securityToken` query parameter, so it is part of every request URL. The client prints only the class name of an exception, never `str(err)`, `repr(err)`, `err.request.url` or `response.url`, each of which contains the token.

## What the range itself contains

Two properties of this particular five and a half years, rather than of the datasets. Both are established by `evidence/06_price_regimes.sql`.

### The 2021 and 2022 price level is a gas-market event, and does not compare with the rest of the range

**What the data shows.** The median Dutch hourly day-ahead price by year: 78.3, 217.0, 99.2, 80.0, 90.4 and 108.1 EUR/MWh for 2021 to 2026. 2022 sits at roughly two and a half times every year after it. Month by month the rise is gradual and the fall is abrupt: about 50 EUR/MWh through the spring of 2021, 78 in June, 133 in September, 226 in December, then a peak of 449 in August 2022 and 139 by that October. The first extreme hours anywhere in the range are five hours in September 2021.

**What caused it is not measured here.** Dutch day-ahead prices are set by gas-fired plant at the margin in a large share of hours, so they follow the European gas price, and the 2021–22 period was a gas supply crisis: European storage refilled slowly after the cold 2020–21 winter, Russian pipeline flows fell through the second half of 2021, and Russia invaded Ukraine on 24 February 2022, after which flows were cut further and then halted. Two supply-side problems unrelated to gas compounded 2022: a large part of the French nuclear fleet was offline for stress-corrosion inspections, and a severe European drought reduced hydro output and limited river cooling for thermal plant. None of that is in the three datasets used here — no gas price, no imports, no exports, no plant availability — so it is recorded as context, and no figure in this project measures it.

**Risk accepted.** Any statistic over price *levels* that spans 2022 mixes two regimes, and the extreme-hour flag concentrates in one of them by construction: 4,055 of the 4,956 extreme hours are in 2022 and 641 in 2021, leaving 47 to 80 a year afterwards. A year-on-year comparison of extreme hours therefore tracks the gas price rather than anything about the Dutch grid, and 2021 is not a high year throughout — its extreme hours are almost all in its last four months. Statistics defined on the *sign* of the price, rather than its level, are unaffected, which is part of why the negative flag is a sign test.

### Negative hours rise across the range, and this source cannot attribute the rise

**What the data shows.** Negative hours per year: 70, 85, 316, 458, 592, and 449 in the 5,831 hours of a partial 2026. As a share of each year's hours that is 0.8%, 1.0%, 3.6%, 5.2%, 6.8% and 7.7%, so the rise is monotonic including 2026, which the raw counts hide. Over the same years the mean hourly output of wind offshore (`B18`) doubles, 877 to 1,787 MW, and of the unidentifiable bucket (`B20`) grows 57%, 3,108 to 4,887 MW. Wind onshore (`B19`) does not follow: it peaks in 2023 at 952 MW and falls to 729.

**What cannot be attributed, and why.** Three quantities that would bear on the rise are not available from this source.

*Solar growth is invisible.* `B16 Solar` runs between 47 and 67 MW as an annual mean and its annual peak sits between 331 and 428 MW, flat across six years, for the reason under What TenneT publishes per production type above: `B16` is the transmission-connected remnant and everything distribution-connected is filed elsewhere or not at all.

*`B20`'s growth is not decomposable.* It is a mixture, with a floor that follows the heating season rather than the sun, 2,199 MW in January against 1,034 in August. How much of its 57% growth is solar is exactly the quantity that leaves the renewable share bounded at 17.8% or 48.8%.

*Efficiency cannot be measured at all.* A capacity factor needs installed capacity, and none of the three datasets carries it. Output growing says nothing about whether the fleet grew or improved.

**Risk accepted.** The rise in negative hours is a measurement; its cause is not. This project may state that negative hours grew, that offshore wind and the unidentifiable bucket grew alongside them, and that onshore wind did not — and no more than that. A claim that solar growth drives negative prices is not supportable from this source in either direction, and the contrast that *can* be measured is the composition shift between flagged and unflagged hours, not the level.

## Decisions

### Timestamps stay in UTC until the time dimension

**Decision.** Every timestamp is kept in UTC from the request through parsing. Local Amsterdam time is derived once, in the time dimension, and nowhere earlier.

**Reasoning.** The API speaks UTC in both directions: `periodStart` and `periodEnd` are sent in UTC, and every timestamp in every document ends in `Z`. A UTC day always has 96 quarter hours, so the parser needs no knowledge of clock changes. An Amsterdam calendar day does not: the day the clocks go forward is 23 hours, 92 quarter hours, and the day they go back is 25 hours, 100 quarter hours, as the fixtures for 2026-03-29 and 2025-10-26 show. Converting in one place means the irregular days are handled once rather than in every query.

**Risk accepted.** Until the time dimension exists, nothing in the parsed data can be grouped by local hour, weekday or date. Doing so on the UTC timestamps would put a local 18:00 at 17:00 in winter and 16:00 in summer.

### Facts are stored at the source's resolution, and the analysis grain is the hour

**Decision.** Each fact table holds one row per market time unit exactly as ENTSO-E published it: load and price one row per market time unit, generation one row per market time unit per production type per direction. Nothing is averaged before it is stored. The analysis works on an hourly table derived from those facts, one row per hour, and every timestamp everywhere is UTC. Hour of day, day of week, month, year and the local Amsterdam labels come from the time dimension, which is also where the 23-hour and 25-hour local days are handled. An hour carries a flag for an event that happened in any market time unit inside it, such as a negative price, computed from the fact rows rather than from the hourly average.

**Reasoning.** The hour is the finest grain the whole range supports: Dutch day-ahead prices were published hourly through the local day 2025-09-30 and quarter-hourly from 2025-10-01, as established under The resolution of each dataset above, so at a finer grain the years before and after are not comparable. Averaging is meaningful in both directions, because each published value is itself an average over its market time unit, per the Detailed Data Descriptions entry quoted above, so an hourly mean of megawatt values is the energy of that hour in megawatt hours. Storing the facts unaveraged keeps every figure traceable to what the API returned, allows a later analysis at quarter-hour resolution for the years that support it, and is what makes the event flags correct: an hour containing one quarter hour at −50 and three at +20 has a positive average and is still an hour with a negative price. Volume is not a reason to aggregate early: five and a half years of all three datasets is on the order of four million rows, which DuckDB handles without effort.

**Risk accepted.** Two tables have to stay in step, and any figure quoted from the hourly table hides what happened inside the hour unless a flag was built for it. Every event definition therefore has to be decided at the fact grain and carried up deliberately; one that is forgotten silently becomes an hourly-average statement instead.

### Price is rolled up to the hour before it is profiled

**Decision.** Every statistic over price is computed from one value per hour, the mean of that hour's market time units, and never from the market time units directly. The roll-up happens once, where the hourly table is built, and before any grouping. Load and generation need no equivalent for the same reason, since both are quarter-hourly across the whole range, but they are still averaged rather than summed, for the reason under Power is averaged over time below. Every hour holds four of their market time units except the seven whose `B20` value was deleted, which hold three.

**Reasoning.** An hour of price is one published row before 2025-10-01 and four after, so any statistic grouped over market time units gives the quarter-hourly period four times the weight per hour. It is not a rounding difference: the mean price by hour of day moves by up to 11.35 EUR/MWh, around 12% of the value, and all in the same direction across the middle of the day, which is exactly the shape the first question asks about. The figures are regenerated by `evidence/03_hourly_grain.sql`.

Rolling up rather than repeating each hourly price across four quarter hours is a choice between two faithful options, not between a right and a wrong one. Repeating is exact rather than interpolated, since before 2025-10-01 there was a single clearing price for the whole hour that applied to every transaction in it. What decides it is comparability: a statistic computed over repeated market time units carries within-hour variation for the 8,040 hours that have any and structurally cannot for the other 41,615, so a year-on-year or month-by-year comparison would measure two different things and report one number. The hour is the finest grain the whole range supports, which is why the analysis grain was set there in the first place.

The roll-up is not the chained aggregation this project avoids elsewhere. That hazard is unequal inner groups silently re-weighting an outer statistic, as a mean of daily means does when days are 23, 24 and 25 hours long. An hour contributes either one published value or four equally weighted ones, so nothing inside an hour is unevenly weighted, and the result is defined identically across the whole range. The hourly price also means something on its own terms, being what it costs to consume flat power for that hour, where a daily median exists only as a description of a day. The roll-up constructs the unit of analysis; the grouping that follows is the single aggregation on top of it.

**Risk accepted.** No hourly statistic can say anything about movement inside an hour, and that movement is real: across the 8,040 quarter-hourly hours a price moves by 23.99 EUR/MWh within the hour on average and by as much as 549.32. It is not noise and it is not discarded, but it has to be measured separately and reported as its own finding, on the part of the range that has it, rather than allowed into statistics that span the whole range.

### Power is averaged over time and summed over production types, and energy is one multiplication away

**Decision.** `load_mw` and `power_mw` are powers in megawatts, not energies, so every roll-up over *time* uses `AVG` and never `SUM`: an hour of load is `AVG(load_mw)`, an hour of one production type is `AVG(power_mw)` over that hour's market time units, a day is the mean of its hours. Summing is correct over the other axis, across production types at one instant, because powers flowing at the same moment add. The two axes therefore take different functions in the same query, and a figure that sums across both is neither a power nor an energy. Where an energy is wanted it is named and carries `mwh`, never `mw`, and it is derived rather than stored.

**Reasoning.** The unit is stated twice and both say power. Every `TimeSeries` declares `quantity_Measure_Unit.name` as `MAW`, and ENTSO-E's code list v36r0 defines `MAW` as "Mega watt", a unit of bulk power flow, as against `MWH`, "Mega watt hours", which appears in this project only as the denominator of a price. A power is a rate, so adding four quarter-hourly readings of it produces a number four times the mean with the units unchanged: 100 MW held for an hour is 100 MW, not 400. The divisor is also not reliably four. Seven hours hold three market time units rather than four for `B20`, being the hours the deletion under Seven generation values are impossible emptied, so dividing a sum by a constant 4 is wrong in exactly the places where the data is already thinnest, while `AVG` is right in all 496,550 hours without a special case.

**Energy follows from the same fact without a second measurement.** Each published value is already itself a mean, per the Detailed Data Descriptions calculation quoted above: "the average of all available instantaneous Net generation output values on each market time unit". So the mean of those means over any window is the mean power over that window, and the energy is that mean times the window's length in hours. Over one hour the multiplier is 1, which is why the hourly mean in MW and the hour's energy in MWh are the same number and are constantly confused; over a day it is 24, and over a quarter hour it is 0.25. Nothing needs to be stored differently for energy: the same hourly mean answers both questions, and the only thing that changes is which name and unit the column carries. This is also why a price in EUR/MWh multiplies cleanly against an hourly mean in MW to give the cost of that hour.

**Risk accepted.** A column holding a mean and a column holding a sum look identical once they are in a table, and the only guard is the name. A `_mw` suffix on a summed column is a claim the numbers do not support, and it survives every later query silently, since a share whose numerator and denominator were summed the same way still sums to one and looks correct. Nothing checks this: `validate.py` tests the fact tables, not the derived ones, so the discipline has to hold in the query that builds each table.

### A negative hour and an extreme hour are two separate flags, and the extreme bar is fixed at 225.00 EUR/MWh

**Decision.** The hourly table carries two independent booleans. An hour is **negative** when any of its market time units cleared below zero, `BOOL_OR(price < 0)`, which is decided at the fact grain rather than from the hourly mean. An hour is **extreme** when its hourly mean price is above **225.00 EUR/MWh**, the 0.90 quantile of hourly price across the whole range. The bar is computed once over the whole range and then fixed, not recomputed per year or per month. No hour in the range is both, so the two sets are disjoint and never pooled into a single "event" flag.

**Reasoning.** The two ask opposite questions. A negative price is surplus, an hour when there is more electricity than the country can use; an extreme price is scarcity. Their generation mixes move in opposite directions, and pooling them nets one against the other: in 2025 `B20`'s share is 46.38 points above its median in negative hours and 8.60 points below it in extreme hours, and a combined figure would report neither. Keeping two flags also keeps each one's meaning readable without a second definition to remember. The bar is fixed rather than a per-group quantile because a quantile recomputed inside each group defines away the thing being measured: a 0.90 quantile of 2022 and a 0.90 quantile of 2025 both select a tenth of their year by construction, so the count can never show that one year had more expensive hours than another. A fixed bar lets the years differ, which is what a question about growth needs. The quantile is taken of the hourly mean rather than of market time units, for the reason under Price is rolled up to the hour above.

**Risk accepted.** A fixed bar distributes unevenly, and here it lands almost entirely in one year: of 4,956 extreme hours, 4,055 are in 2022 and 641 in 2021, leaving between 47 and 80 in each of 2023 to 2026. That is a real property of the range, since the 2022 gas crisis genuinely produced those prices, but it means any statistic over extreme hours in a later year rests on a few dozen observations and has to be reported with its count beside it. The figures in this section, the bar and the distribution of the hours it selects, regenerate from `evidence/05_extreme_price.sql`. The negative side carries the separate caveat recorded under Day-ahead prices have a floor and a ceiling: the floor moved from −500 to −600 on 29 May 2026, so the depth of the negative tail is not comparable across that date, although the count of negative hours is unaffected because the flag is a sign test rather than a magnitude.

### Grid congestion is context, not a measured quantity

**Decision.** This analysis does not measure grid congestion. Load, generation per production type and day-ahead prices describe the market in the bidding zone as a whole, and are used to study when prices are negative or extreme and what is being produced and consumed at those times. Congestion appears in the framing, as the reason flexibility has value, and in the caveats, never as a result.

**Reasoning.** The Netherlands is a single bidding zone: every participant clears at the same day-ahead price, whatever the physical grid inside the zone can carry, so the price cannot express a local limit by construction. Congestion happens on particular lines, substations and regional grids, and all three datasets used here are national totals with no location in them. What would measure it is published elsewhere under the same Transparency Regulation, in [Article 13](https://www.legislation.gov.uk/eur/2013/543/article/13/adopted), "Information relating to congestion management measures": redispatching per market time unit with the network elements concerned, countertrading, and the monthly cost of both. Those are separate datasets with their own document types and grains, the monthly costs cannot sit at an hourly grain at all, and they cover transmission actions rather than the regional grids where Dutch connection queues are longest.

**Risk accepted.** A reader looking for when and where the Dutch grid is congested will not find it here. Nothing in this analysis separates an hour of national oversupply from an hour when a particular region could not export what it generated, and no claim in the report may attribute a price to a local grid limit.

### Production types stay as ENTSO-E codes in the parser

**Decision.** The parser labels each generation and consumption series with its `psrType` code exactly as it appears in the document, such as `B18`, and does not translate codes into names such as Wind Offshore. The code-to-name table is kept in this file, under What a generation response contains.

**Reasoning.** The only list of names read for this project is version 36 of the ENTSO-E code lists, dated 2015-06-09, and whether later versions add production types was not checked. A mapping inside the parser would have to be complete for every code the API may ever send: a code missing from it either stops the parse or produces a series with no name, and either failure depends on a document that has not arrived yet. Keeping the code costs nothing in information, since the code is the identifier ENTSO-E itself uses, and it cannot go out of date. Names are a matter of presentation, and belong where the data is presented.

**Risk accepted.** Parsed output is less readable: a series reads `B18`, not wind offshore, until the codes are joined to names. That join, in the production type dimension or in the report, has to be kept in step with the code list, and a code it does not know will show up there without a name rather than stopping the parse.

### Seven generation values are impossible, and are dropped rather than corrected

**Decision.** `load.py` deletes every `fact_generation` row whose `power_mw` is greater than the largest `load_mw` in `fact_load`, which on the responses fetched on 2026-09-20 is 20,718.046 MW. Seven rows go, all of them production type `B20` with `direction = 'in'`, and all in 2023: 2023-04-08 19:00 (21,428.98 MW), 2023-04-11 11:00 (27,325.48), 2023-04-24 19:00 (22,605.90), 2023-04-27 11:00 (27,962.06), 2023-05-10 19:00 (20,994.88), 2023-05-13 11:00 (28,236.93) and 2023-08-27 10:15 (24,622.18), all Amsterdam local. The deletion runs after every file has been inserted, because the bound cannot be computed until `fact_load` is complete, and before `validate` runs, inside the same transaction. The bound is read from the load table rather than written down as a number, so it moves if the fetch window changes. The same rule is kept as an invariant in `validate.py`, where it now confirms the deletion rather than discovering anything.

**Reasoning.** These values are not readings. At 2023-05-13 11:00 one production type reports 28,236.93 MW while the whole country is consuming 11,102.86 MW, in a market whose total installed capacity across every type is around 40 GW; the surplus goes nowhere any of the three datasets records. Each is one market time unit wide with smooth neighbours either side, 4,528 MW then 21,429 MW then 4,032 MW, and generation cannot step up 17 GW and back down inside fifteen minutes when thermal plant ramps over tens of minutes and solar over an hour. At those same instants no other production type is unusual and load and price are ordinary, so whatever happened happened to one published series rather than to the grid. They are deleted rather than corrected because nothing in the response says what the true value was, and interpolating from the neighbours would invent a reading and give it the same provenance columns as a real one. They are deleted rather than set null because a missing market time unit is what the data actually supports: an average over that hour then averages the three intervals that were measured, and `fact_generation: no null value` stays true.

**Risk accepted.** The bound removes the impossible, not the wrong, and those are not the same set. Eleven `B20` spikes of this shape are known to be in the 2023 data; the four the bound does not reach are the most extreme of all of them by neighbour ratio, up to 14x, because they happen to sit just under the load maximum: 2023-04-14 03:00 (20,024.0 MW), 2023-04-30 03:00 (18,471.0), 2023-08-24 23:45 (19,772.8) and 2023-08-25 23:45 (19,621.0). A cluster of the same shape sits on 2026-01-06, at about twice its neighbours rather than five times, and how many intervals it contains depends entirely on where a threshold is put: eight of them exceed 1.7 times the larger neighbour, five exceed 2.0, none exceeds 2.4. One `B17` consumption value of 3,657.9 MW on 2022-08-10 16:45 sits in a stretch where the series is otherwise zero, and one `B04` value of 5,348.5 MW on 2021-10-31 17:00 is three times its neighbours while being an ordinary output for gas. After the deletion the maximum `B20` output in the database is 20,024.0 MW, which is one of the four that remain, so any statistic over `B20` that a single interval can move, a maximum above all, is still not to be trusted. Statistics that average over many intervals absorb them, seven faults being seven in 3,972,400 rows and the known remainder about twenty. A rule catching the rest would have to be that neighbour-ratio test, which was considered and not adopted: the 2026-01-06 cluster is exactly why, since its intervals run continuously from 1.74 up to 2.31 with no gap to cut at, so the threshold separating a fault from a real ramp is a judgement the data does not settle, and a wrong one silently deletes real generation.

## What the database holds

Built by `python -m gridstress.load`, which runs every file in `sql/` and inserts every response in `data/raw/` inside a single transaction: the first three declare the tables, the responses go in, the impossible generation values come out, the last two derive the analysis tables, and `validate.py` sees all of it before anything is committed. Built on 2026-09-29 from the responses fetched on 2026-09-20.

The actual counts are logged by the loader as it commits, so they come from the code that produced the tables. The expected counts come from `evidence/02_expected_row_counts.py`, which derives them from the fetch range and the documents' own metadata without opening the database.

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

**Where each expectation comes from.** `dim_time` and `fact_load` are the whole hours and the whole quarter hours between the two range boundaries, since load is `PT15M` for every date in the range. `fact_price` is 41,615 hourly units through the local day 2025-09-30 plus 32,160 quarter-hourly units from 2025-10-01, split at the market time unit change described above. `fact_generation` is, for each `A75` window, the number of `TimeSeries` it carries times the quarter hours in that window. `dim_production_type` is the twenty production types `B01` to `B20` of code list v36r0.

The four derived tables follow from those. `table_h_price_load` is one row per hour, so it equals `dim_time`. `table_composition` is 49,655 hours times the ten production types the `A75` responses actually carry, generating direction only. `b20_thermal_table` is the Amsterdam local days in the range. `table_h_price_post` is the hours from 2023-03-01, 62% of them, for the reason under The 2021 and 2022 price level is a gas-market event above.

**The one gap, and why it is the expected size.** `fact_generation` holds seven rows fewer than the documents carry, and those are exactly the seven the loader deletes under Seven generation values are impossible above. The expectation is what the API published; the table is what survived the check. Every other count matches, which is what says the parser read every series it was given and the loader inserted every row it parsed.

**What the agreement establishes.** Every expectation was computed before the load and matched to the row, which rules out a window silently missing, and rules out the `A03` fill generating too many or too few points. `fact_generation` splits exactly in half, 1,986,200 rows in each direction with ten production types on each side.

**And one thing that was previously unestablished.** No primary key was violated on any of the three fact tables, whose keys are `date_utc`, `date_utc`, and `(date_utc, psr_type, direction)`. Consecutive windows therefore do not both return the boundary instant they share, which the request-widening behaviour described under How the API treats the requested window left open. Had they done so, the load would have failed rather than double-counted.

**The clock changes land where they should.** The per-file counts the loader logs show 28,796 rows for the `A65` window containing a spring change and 28,804 for the one containing an autumn change, against 28,800 for a window containing neither, which is one hour of quarter hours either way.
