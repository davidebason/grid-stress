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
| Actual generation per production type | `A75`, actual generation per type | `A16`, realised | `in_Domain` | `GL_MarketDocument`, two `TimeSeries` per production type, one per direction, see below | `quantity` | `MAW`, megawatts |
| Day-ahead prices | `A44`, price document | none | `in_Domain` and `out_Domain`, both the same zone | `Publication_MarketDocument` | `price.amount` | `EUR` per `MWH` |

The Netherlands is `10YNL----------L`. The window of one request is kept to 300 days by the client, below the API's limit of about one year.

**The document type decides the document family.** `A65` and `A75` are physical measurements and come back as `GL_MarketDocument` (generation and load), carrying power in megawatts. `A44` is a market result and comes back as `Publication_MarketDocument`, carrying prices. Neither family carries the other's quantity: a price document holds no energy or power, and `MWH` in it is the unit of the price, euros per megawatt hour. When a request cannot be answered with data, whatever its document type, an `Acknowledgement_MarketDocument` comes back instead, see API errors below.

#### What a generation response contains

Observed in `tests/fixtures/generation_nl_20260914.xml`, one Netherlands day, `2026-09-13T22:00Z` to `2026-09-14T22:00Z`, fetched on 2026-09-17.

The document holds 20 `TimeSeries`, each with one `Period` covering the whole day. All 20 have `curveType` `A03`, `resolution` `PT15M`, unit `MAW`, `businessType` `A01` and `objectAggregation` `A08`. The production type sits in `MktPSRType/psrType` inside each series. The children of a series come in this order: `mRID`, `businessType`, `objectAggregation`, the domain element, `quantity_Measure_Unit.name`, `curveType`, `MktPSRType`, `Period`.

**Each production type appears twice, once per direction.** Ten series carry `inBiddingZone_Domain.mRID` and ten carry `outBiddingZone_Domain.mRID`, with the same ten `psrType` codes in each group, and no series carries both. The API guide describes `in` as actual generation, power flowing into the zone, and `out` as actual consumption. Consumption series exist for every type in the response, not only for storage; no storage type (`B10`, `B25`) appears on this day. The two directions differ by orders of magnitude:

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

## Decisions

### Timestamps stay in UTC until the time dimension

**Decision.** Every timestamp is kept in UTC from the request through parsing. Local Amsterdam time is derived once, in the time dimension, and nowhere earlier.

**Reasoning.** The API speaks UTC in both directions: `periodStart` and `periodEnd` are sent in UTC, and every timestamp in every document ends in `Z`. A UTC day always has 96 quarter hours, so the parser needs no knowledge of clock changes. An Amsterdam calendar day does not: the day the clocks go forward is 23 hours, 92 quarter hours, and the day they go back is 25 hours, 100 quarter hours, as the fixtures for 2026-03-29 and 2025-10-26 show. Converting in one place means the irregular days are handled once rather than in every query.

**Risk accepted.** Until the time dimension exists, nothing in the parsed data can be grouped by local hour, weekday or date. Doing so on the UTC timestamps would put a local 18:00 at 17:00 in winter and 16:00 in summer.
