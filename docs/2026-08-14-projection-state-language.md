# Projection State and Language Plan

**Status:** Planning reference. Account-underfunding copy was approved on
2026-08-16; final user-facing wording for the other scenarios is not yet
approved.

The Projections screen needs to distinguish four fundamentally different kinds of states. Their language and metrics must not be used interchangeably:

1. Setup or incomplete-data states
2. Healthy or buffer-related states
3. Genuine cash-shortage states
4. Account-allocation problems

## Scenario Matrix

| Scenario | What it means | Metric that matters |
| --- | --- | --- |
| No cash accounts selected | Nothing can be calculated | Setup action |
| Card timing missing | Forecast is incomplete | Missing cards |
| Payment account excluded | Card payment cannot be validated | Missing account |
| Limited spending history, obligations covered | Only dated commitments are known | Known low |
| Limited history, obligations go negative | Known bills alone exceed cash | First negative date and deficit |
| Healthy forecast | Cash stays above the buffer | Safe to Spend |
| Exactly at buffer | No extra room, but the buffer is preserved | $0 available |
| Below buffer today | Current cash is below the preferred cushion | Today's buffer gap |
| Above buffer today, below later | The cushion is breached in the future | First breach date |
| Below buffer temporarily, then recovers | The cushion is breached but cash remains positive | Breach window and worst gap |
| Negative today | Selected cash is already negative | Current deficit |
| Turns negative later | Aggregate selected cash becomes insufficient | First negative date and deficit |
| Payment account underfunded, aggregate cash sufficient | Money exists, but it is in the wrong account | Transfer amount and deadline |
| Ordinary cash account goes negative | An individual account is underfunded | Account, amount, and date |
| Multiple accounts become underfunded | More than one transfer or action may be required | Earliest risk plus full list |
| Higher-spending case is worse | The baseline may be safe while the conservative case is not | Scenario difference |
| Income not projected | The forecast excludes expected paychecks | Reason income is absent |
| Data stale or sync failed | The forecast may no longer be current | Last successful update |
| No upcoming dated activity | The forecast is primarily driven by the ordinary-spending assumption | Spending assumption |

## Required Conceptual Distinctions

- **Below buffer** does not mean the user is short of money. It means projected cash is below the user's chosen comfort level.
- **Negative cash** is a genuine projected shortage.
- **Account underfunding** means aggregate cash may be sufficient, but it is held in the wrong account when an obligation is due.
- **Incomplete data** means the app cannot make a confident forecast claim.

## Current Gap Versus Future Gap

These values answer different questions and must be labeled separately:

- **Today's buffer gap:** buffer minus today's selected cash balance.
- **Worst projected buffer gap:** buffer minus the lowest projected future balance.

For example, with a $20,000 buffer, the previously displayed $12,300 represented the worst projected gap on October 8. It did not necessarily represent the gap today. Displaying it beside a headline containing “now” was misleading.

## Consistent Outlook Card Structure

Each state should use the same information hierarchy:

1. **Headline:** What condition exists, and when?
2. **Labeled metric:** Available amount, current gap, future deficit, or transfer needed.
3. **Supporting line:** Lowest balance and date, or the immediate cause.
4. **Why:** The full calculation and contributing events.

## Approved Account-Underfunding Copy

For either a payment account or another individual cash account whose projected
balance falls below zero:

- **Title:** `[Account name] may be overdrawn`
- **Message:** `Projected to fall $X below $0 on [date].`

The amount and date must come from the same projected account low point. Do not
pair the worst-balance amount with the earlier first-breach date.

## Next Product Decision

Choose and approve the exact wording for every remaining scenario before
changing its implementation again. The language must make the distinction
between comfort-level warnings, actual shortages, account-transfer needs, and
incomplete forecasts immediately clear.
