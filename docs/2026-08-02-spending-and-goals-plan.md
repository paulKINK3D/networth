# Group Budget and Long-Term Goals System

## Summary

Build one Spending overview with two connected but distinct systems:

- **Monthly general spending:** Networth-owned targets for selected YNAB groups, showing whether each group and the combined plan are on pace, ahead of pace, or over budget.
- **Long-term goals:** Money allocated from a shared pool of cash accounts excluded from Projections, with progress, optional timing, confirmed contributions, and confirmed goal purchases.

YNAB supplies the group/category hierarchy and transaction activity. Networth owns targets and goals. Nothing writes back to YNAB.

## Key Changes

### Monthly spending

- Let the user select which YNAB groups constitute general spending and assign each a monthly target.
- Use recurring targets with effective-month history and optional one-month overrides; unused amounts reset each month.
- Calculate the overview from only the selected groups:
  - **On pace:** spending is at or below the target prorated through today.
  - **Ahead of pace:** above prorated pace but still within the full target.
  - **Over budget:** above the full monthly target.
- Sum included group targets and spending into a monthly hero showing spent, target, remaining, and status.
- Show one compact row per group with spent versus target, progress, and status.
- Tapping a group opens category totals, contributing transactions, and historical actual-versus-target results. Categories do not receive individual budgets.
- Preserve month navigation. Historical months use final target-versus-actual status rather than pace.

### Long-term goals

- Create goals with a name, target amount, one-time or reusable behavior, optional target date, and optional monthly contribution plan.
- Select one or more open, cash-like accounts excluded from Projections as the shared reserve pool.
- Calculate:
  - **Reserve pool:** combined conservative balance of selected accounts.
  - **Allocated:** total active goal balances.
  - **Unallocated:** reserve pool minus allocations.
  - **Shortfall:** allocations exceeding the live reserve pool.
- Confirmed contributions move unallocated reserve money into a goal; planned contributions never increase progress automatically.
- A target date remains optional. When present, calculate the monthly amount needed; without one, show progress and any user-defined monthly plan.
- Never silently reduce allocations when reserve balances fall. Surface a shortfall and block new allocations until resolved.
- Prevent an account from simultaneously backing goals and participating in Projections; changing either setting requires resolving the conflict.
- Rewind goal balances and activity to month-end when browsing prior months.

### Goal purchases

- Suggest eligible posted spending transactions on-device, but require explicit confirmation before connecting one to a goal.
- Support multiple confirmed purchases and partial transaction or split-leg amounts.
- Confirmed goal spending reduces the goal balance and is excluded from ordinary group-budget calculations; any unassigned remainder still counts as general spending.
- Keep goal purchases visible within group detail under a separate planned-purchase section.
- Refunds can be confirmed back into the original goal.
- One-time goals move to history only after explicit completion. Reusable goals remain active after spending; any future deadline is optional and never generated automatically.

## Persistence and Interfaces

- Add a durable, effective-dated group-target model keyed by stable YNAB group identity. A single-month override wins over the latest recurring target effective for that month.
- Add durable reserve-account selections using canonical account identity where available, with YNAB identity retained through Plaid reconciliation.
- Evolve the existing durable goal and ledger records additively to support goal behavior, ledger-entry kind, and optional transaction/split references.
- Preserve any existing goal balances during migration with a one-time adjustment; retain obsolete persisted fields for CloudKit compatibility rather than deleting them.
- Retire the separate shared “Discretionary Budget” interface without deleting its persisted legacy fields or automatically distributing its amount among groups.
- Update the product decision log: group-level targets are now in scope, while category-level budgeting, rollover envelopes, automatic allocations, and financial-provider writes remain out of scope.

## Experience

- Spending overview order:
  1. Selected month and combined spending status.
  2. Included group rows.
  3. Reserve-pool summary and active goal cards.
- First-time setup chooses general-spending groups and targets, then optionally configures reserve accounts and goals.
- Goal cards show allocated versus target, this month’s confirmed contribution versus plan, and optional deadline status.
- Historical views show goal ledger progress as of that month; live reserve availability is only presented as current data to avoid implying reconstructed account balances.
- Use neutral language: “On pace,” “Ahead of pace,” and “Over budget,” without coaching or judgment.

## Test Plan

- Recurring targets, one-month overrides, preserved historical targets, group renames, and monthly reset behavior.
- Pace calculations at month start, mid-month, and month end; exact-target and over-target boundaries.
- Group aggregation across categories, splits, refunds, transfers, income, exclusions, and reviewed Plaid transactions.
- Full and partial goal-purchase exclusions from general spending.
- Goal allocations, reallocation, purchases, refunds, completion, reusable behavior, and month-end historical reconstruction.
- Shared reserve pool with multiple accounts, insufficient unallocated cash, balance drops, closed/disconnected accounts, and projection-account conflicts.
- Migration preserves existing durable goal balances and CloudKit compatibility.
- Persistence failures preserve edits and present actionable errors.
- Run NetworthCore tests plus generic-device Debug and Release builds.

## Assumptions

- Group targets are positive whole-currency amounts and start with the selected effective month.
- The overview initially supports the current month and previous 12 months.
- Reserve-pool values use available balance when supplied; otherwise a conservative current/cleared balance.
- Provider data remains read-only, and the app never initiates transfers between the main account and reserve accounts.
