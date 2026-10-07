# Brief: Dutch electricity

Scope and framing for this engagement. Findings are in `REPORT.md`; data provenance and modelling decisions in `DATA.md`.

---

## The client and the question

The client is a large industrial consumer or a battery operator in the Netherlands. It buys electricity at the Dutch **day-ahead price**, which is set the day before for every hour, and since October 2025 for every quarter-hour, of the following day, and it can move part of its consumption from one hour to another. It asks:

> *"Electricity prices swing wildly and sometimes go negative. When does that happen, how predictable is the pattern, and what should we do differently?"*

The deliverable is a memo an operations or energy manager could act on: a recommendation with a number attached, and the caveats that qualify it. Not a forecast, not a model.

**The Netherlands also has a grid congestion problem, public, expensive and widely discussed, and the two share a cause without being the same problem.** One is a market problem: at some hours there is more electricity than the country can use, prices collapse or go negative, and at other hours they go extreme. The other is a grid problem: local lines and substations cannot carry what is connected to them, which is what **congestion** names. Both are driven by the growth of solar and wind. This engagement answers the first. The Netherlands is a single **bidding zone**, so every consumer in it pays the same day-ahead price regardless of the local grid, and no measurement in the data used here says where the grid is constrained. Congestion is the reason flexibility is worth money to this client; it is not what we measure.

## The questions

1. **How often are prices negative or extreme, and when?** By hour of day, day of week, season and year. An hour is **negative** when its price is below zero in any of its **market time units**, the hours, or since 1 October 2025 the quarter-hours, the market sets a price for: it marks surplus, more electricity on offer than the country can use. An hour is **extreme** when its average price is above €225 per MWh, the dearest tenth of all hours in the range: it marks scarcity, when **load**, the electricity used across the whole country, presses against what the cheaper plants can supply and the most expensive ones, mostly gas, set the price. The bar is fixed once over the whole range so that every year is measured against the same one.
2. **What is on the system when it happens?** The **generation mix** is the share of the electricity produced in an hour that comes from each source: gas, coal, wind, solar, nuclear, biomass and the rest, as published per production type. The question sets the mix in negative hours, and separately in extreme hours, against the mix in all hours, in percentage points, to show which sources rise and which fall when the price goes to either end. For the Netherlands the largest single entry is output the grid operator cannot attribute to a fuel, published as `B20 Other`, so this is the mix of what was published, not of everything generated, for the reason under "Data" below.
3. **On the days prices go extreme, are load and the burned fleet at their extremes too?** Within each month, the **extreme days**, those with at least one extreme hour, set against the days of highest peak load, of widest **gas-and-coal swing**, the day's highest hourly gas-and-coal output minus its lowest, and of largest swing and highest floor in the output TenneT cannot attribute to a fuel, with how often chance alone would produce each overlap. We ask it day by day, because an hour-of-day profile pools many dates and cannot say whether two series moved together on any actual day. Gas and coal are there because the renewable share cannot be measured from this source: as explained under "Data" below, the published solar figure follows the seasons but stays small and does not grow from year to year, although installed solar capacity more than doubled, while `B20 Other` swings with the sun on a far larger scale. This suggests that most of the added capacity is not published as solar but filed under `B20 Other`, or not published at all. We therefore use gas-and-coal output as an **inverse indicator** of renewables: what is burned is what remains once wind and sun have supplied what they can, so the two move in opposite directions. It is an imperfect one, since imports, nuclear and gas burned for heat move it too, and the answer is bounded by that.
4. **What would a consumer who could shift its consumption actually gain?** A counterfactual in euros, and how much more the move to quarter-hour prices on 2025-10-01 lets them save.

---

## Data

**ENTSO-E Transparency Platform**, `https://web-api.tp.entsoe.eu/api`, HTTPS only. Access requires a registered account and a security token issued on request. The token reaches the code through an environment variable and is never committed.

Confirmed by direct query before work started:

| fact | value | consequence |
|---|---|---|
| Base URL | `https://web-api.tp.entsoe.eu/api` | |
| Netherlands EIC | `10YNL----------L` | Belgium `10YBE----------2`, Germany and Luxembourg `10Y1001A1001A82H` |
| Rate limit | 400 requests per minute, per IP and per token | Backoff is required, not optional |
| Actual total load | `documentType=A65`, `processType=A16` | one TimeSeries |
| Generation per type | `documentType=A75`, `processType=A16` | about 20 TimeSeries per day, one per `psrType` |
| Time format | `YYYYMMDDHHmm`, UTC | the market runs CET/CEST |
| Resolution | `PT15M` for NL load | 96 points in a normal day |
| Curve type | `A03`, variable sized block | a point's value holds until the next point; sparse encoding is legal even where today's data is dense |
| Units | `MAW`, megawatts | power, not energy; cannot be summed without multiplying by interval length |

**Wind and solar appear in the data, but the renewable share cannot be read from it.** The production types include solar (`B16`), offshore wind (`B18`) and onshore wind (`B19`), which suggests renewable output is covered. It is not, because of how TenneT publishes: *"The publication represents the generation identifiable per fuel type, if not identifiable the data is published as 'others' or not published."* Output is attributed to a fuel only where TenneT can identify it, which means plant connected to its own transmission grid; output connected to local distribution networks is either filed under `B20 Other` or not published at all. The published solar figure follows the seasons but stays flat from year to year, at 47 to 67 MW of mean output in every year from 2021 to 2025 and in 2026 to August, a period over which installed Dutch solar capacity more than doubled, from 11.1 GW of panel capacity at the end of 2020 to 28.6 GW at the end of 2024, according to Statistics Netherlands (CBS), [*Hernieuwbare energie in Nederland 2024*](https://www.cbs.nl/nl-nl/longread/rapportages/2025/hernieuwbare-energie-in-nederland-2024/5-zonne-energie), table 5.1.1, while `B20 Other`, the largest single entry in the data, swings with the sun: 8,262 MW across a June day against 2,554 MW in December. Wind is published under the same rule, and how much of it is filed as Other is not established. This is a property of the source, outside the project's control, and it is why we use gas-and-coal output as an inverse indicator of renewables instead of measuring them. The evidence is in `DATA.md`, under "What TenneT publishes per production type, and what it does not".

**The daylight-saving day returns 92 points, not 96.** Verified against 2026-03-29 local, `periodStart=202603282300&periodEnd=202603292200`.

### Known data risks, each settled as a decision in `DATA.md`

- `A03` block encoding: a parser that assumes one point per interval works until the source sends a sparse series.
- UTC in, local out: the API speaks UTC and the market speaks CET/CEST.
- `A75` mixes generation and consumption series, distinguished by `inBiddingZone_Domain` against `outBiddingZone_Domain`; summing blindly counts consumption as generation. No storage type appears in either direction for the Netherlands, so the consumption series is not storage charging.
- Generation is published per fuel type only where TenneT can identify the fuel, as set out above, which makes `B16 Solar` unusable as a national solar figure and makes any share of summed generation a share of what was published.
- Power against energy: `MAW` is instantaneous; anything cumulative needs the interval.
- Data revisions: ENTSO-E restates published values.

---

## Deliverables

- **`REPORT.md`**, the memo: the answer to each question, the recommendation with its savings in euros, and the caveats that qualify it, with a figure wherever one carries a finding.
- **`README.md`**, a one-page overview with one headline figure.
- **`DATA.md`**: every source, unit and decision behind the numbers.
- **A repository that regenerates every number from the public source**: the API client, the database and the checks it must pass before it is saved, one SQL file per question, and the tests.

---

## Scope guards

- **The Netherlands only.**
- **Data from 2021 to the present, for all three datasets:** actual total load, actual generation for every production type, and day-ahead prices. 2021 is when TenneT declared structural congestion in parts of the Dutch high-voltage grid, and negative prices became frequent in the years that followed, so the range covers the period in which the problem took its current form.
