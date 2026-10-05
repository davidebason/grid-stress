# Brief: Dutch electricity, from an unfriendly API to a decision

Scope and framing for this engagement. Findings will live in `REPORT.md`; data provenance and modelling decisions in `DATA.md`.

---

## The client and the question

The Netherlands has a grid congestion problem that is public, expensive and widely discussed. The client is a large industrial consumer or a battery operator, asking:

> *"Electricity prices swing wildly and sometimes go negative. When does that happen, how predictable is the pattern, and what should we do differently?"*

The deliverable is a memo an operations or energy manager could act on: a recommendation with a number attached, and the caveats that qualify it. Not a forecast, not a model.

**Two problems share a cause and are not the same problem.** One is a market problem: at some hours there is more electricity than the country can use, prices collapse or go negative, and at other hours they spike. The other is a grid problem: local lines and substations cannot carry what is connected to them, which is what "congestion" names. Both are driven by the growth of solar and wind. This engagement answers the first. The Netherlands is a single bidding zone, so every consumer in it pays the same day-ahead price regardless of the local grid, and no measurement in the data used here says where the grid is constrained. Congestion is the reason flexibility is worth money to this client; it is not what is measured.

## The questions

1. **How often are prices negative or extreme, and when?** By hour of day, day of week, season and year.
2. **What is on the system when it happens?** The generation mix in those hours set against an ordinary hour, and which parts of it move.
3. **On the days prices go extreme, are demand and the burned fleet at their extremes too?** Within each month, the days of extreme price set against the days of highest peak demand, of hardest ramping by gas and coal, and of largest swing and highest floor in the output TenneT cannot attribute to a fuel, with the probability that each overlap is luck. Gas and coal stand in for the renewable share, which this source cannot measure, and the answer is bounded by that. Changed on 2026-10-05: an hour-of-day comparison cannot say whether two series moved together on any actual day; generation and consumption have no usable measure in this source; and the question of how much of the variation the simple story explains was folded in here, so its caveat is now this question's. Superseded wording, kept so the change stays visible: *Do load and generation swing at the same times as prices? The same measures of movement applied to load, generation and consumption, and whether their extreme hours coincide with the extreme price hours.*
4. **What would a consumer who could shift load actually gain?** A counterfactual in euros, and how much more the move to quarter-hour prices on 2025-10-01 lets them save. Renumbered on 2026-10-05, from question 5, and the quarter-hour part added the same day.

---

## Data

**ENTSO-E Transparency Platform**, `https://web-api.tp.entsoe.eu/api`, HTTPS only. Access requires a registered account and a security token issued on request. The token reaches the code through an environment variable and is never committed.

Confirmed by direct query before work started:

| fact | value | consequence |
|---|---|---|
| Base URL | `https://web-api.tp.entsoe.eu/api` | |
| Netherlands EIC | `10YNL----------L` | Belgium `10YBE----------2`, Germany and Luxembourg `10Y1001A1001A82H` |
| Rate limit | 400 requests per minute, per IP **and** per token | Backoff is required, not optional |
| Actual total load | `documentType=A65`, `processType=A16` | one TimeSeries |
| Generation per type | `documentType=A75`, `processType=A16` | about **20** TimeSeries per day, one per `psrType` |
| Time format | `YYYYMMDDHHmm`, **UTC** | the market runs CET/CEST |
| Resolution | `PT15M` for NL load | 96 points in a normal day |
| Curve type | `A03`, variable sized block | a point's value **holds until the next point**; sparse encoding is legal even where today's data is dense |
| Units | `MAW`, megawatts | power, not energy; cannot be summed without multiplying by interval length |

**The daylight-saving day returns 92 points, not 96.** Verified against 2026-03-29 local, `periodStart=202603282300&periodEnd=202603292200`.

### Known data risks, each to be settled as a decision in `DATA.md`

- `A03` block encoding: a parser that assumes one point per interval works until the source sends a sparse series.
- UTC in, local out: the API speaks UTC and the market speaks CET/CEST.
- `A75` mixes generation and consumption series, distinguished by `inBiddingZone_Domain` against `outBiddingZone_Domain`; summing blindly counts consumption as generation. No storage type appears in either direction for the Netherlands, so the consumption series is not storage charging.
- Generation is published per fuel type only where TenneT can identify the fuel. The rest is filed as `B20 Other` or not published at all, which makes `B16 Solar` unusable as a national solar figure and makes any share of summed generation a share of what was published.
- Power against energy: `MAW` is instantaneous; anything cumulative needs the interval.
- Data revisions: ENTSO-E restates published values.

---

## Deliverables

| # | Content | Done when |
|---|---|---|
| 1 | Repository scaffold, packaging, CI green on a trivial test | Green check on `main` |
| 2 | The API client: auth from the environment, time-window pagination, retry with backoff, and windows sized to keep the whole fetch far below the rate limit | The full range fetched in 21 requests against a limit of 400 per minute; recorded fixtures committed |
| 3 | XML into tidy frames, including sparse `A03` handling | Tests pass against both a dense and a hand-built sparse fixture |
| 4 | The star schema in SQL, `DATA.md` started | Row counts documented; grain decision written down |
| 5 | Schema and range validation that fails loudly; the daylight-saving test | A deliberately corrupted fixture turns the suite red |
| 6 | Questions 1 to 3 | Every number regenerated by a numbered file |
| 7 | Question 4, the load-shifting gain in euros | Sensitivity across at least three assumptions |
| 8 | `REPORT.md`, one figure, `README.md` | A non-technical reader can state the recommendation |

One branch and one pull request per deliverable.

---

## Scope guards

- **No forecasting model.**
- **No dbt, no orchestrator, no cloud, no Docker.**
- **Netherlands only**, with Belgium and Germany used solely for cross-border context if question 2 needs it.
- **Data from 2021 to the present, for all three datasets:** actual total load, actual generation for every production type, and day-ahead prices. 2021 is when TenneT declared structural congestion in parts of the Dutch high-voltage grid, and negative prices became frequent in the years that followed, so the range covers the period in which the problem took its current form.
- **If API access fails or is throttled beyond use**, fall back to CBS StatLine OData paired with one other source, within the first two hours.
- **Cut a question rather than doing all four at half depth.** Question 4 must survive; question 3, which now carries the thermal-output question, is the next most valuable.
