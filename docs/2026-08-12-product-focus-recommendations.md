# Product Focus Recommendations

Date: 2026-08-12

Status: Discussion recommendations, not locked scope. Any information-architecture
change must be recorded as a separate decision in `docs/PLAN.md` before implementation.

## Recommendation

Make Networth smaller and more trustworthy before adding another major product
surface. The app's essential questions are:

1. **Projections:** Am I safe, and what money is coming or leaving?
2. **Spending:** Where did my money go, and how does it compare with income?
3. **Net Worth:** How is my overall financial position changing?
4. **Goals:** What money have I reserved, and what is it reserved for?

Treat Projections as the product's primary daily workflow and Net Worth as its
supporting long-term scorecard.

## Candidates to Remove or Reduce

- Hide investment-reconciliation controls on ordinary banking accounts.
- Move migration, resync, reconciliation, and repair tools into an Advanced
  area so routine Settings expose only routine decisions.
- Freeze Goals at its current scope. Do not restore contribution schedules,
  coaching, goal types, or additional ledger concepts without a new product
  decision.
- Keep the higher-spending projection case subordinate to the arithmetic-mean
  baseline rather than presenting it as a competing headline.
- Remove remaining user-facing budget, envelope, or spending-limit concepts
  that are not required to explain the projection engine.
- Avoid adding category budgets, investment-performance analytics, more
  transaction classifications, or another tab for now.

## Information-Architecture Question

Consider folding Investments into Net Worth. Portfolio value, allocation,
history, and holdings are components of net worth; Investments should keep a
top-level tab only if it supports a genuinely distinct and frequently used
decision. This would change the currently locked five-tab structure and
therefore requires an explicit scope decision before implementation.

## Meaningful Feature Candidates

### 1. Projection Audit

Highest priority. Every consequential projection number should be independently
understandable and reproducible.

- Show every complete month used to calculate expected spending.
- Show each monthly total and the arithmetic-mean equation.
- Reconcile starting cash, income, scheduled obligations, card payments,
  expected ordinary spending, cash buffer, and Safe to Spend.
- Explain every inclusion and exclusion.
- Add the already-planned local projection-audit CSV export for deeper review.

This directly improves confidence after the historical-spending calculation
confusion and advances the product's core promise of explainable forecasts.

### 2. Can I Afford This?

Let the user enter an amount and approximate date, then calculate:

- whether projected cash remains above the configured buffer;
- the revised Safe to Spend amount;
- the revised low point and date; and
- whether a transfer between selected accounts would be required.

This should be a lightweight scenario sheet powered by the existing projection
engine, not a new tab or persistent budgeting system.

### 3. What Changed?

After synchronization, provide a compact summary of material changes such as:

- a card-payment estimate changing;
- the projected low point moving;
- an account balance becoming stale; or
- a new transaction materially changing the outlook.

The summary should surface only actionable changes and should not become an
activity feed.

## Recommended Order

1. Finish the existing trust and polish work:
   - scope investment-reconciliation controls correctly;
   - diagnose the Goals transition stall; and
   - establish a safe stale-balance recovery path for Cash Plus.
2. Build the in-app Projection Audit and required local CSV export.
3. Decide whether Investments should remain a top-level tab.
4. Add Can I Afford This?
5. Freeze scope again and evaluate the app through sustained real-world use.

## Product Guardrail

Prefer work that makes an existing answer clearer, more accurate, or more
actionable. A new feature should earn its place by helping answer one of the
four essential questions above without introducing another planning system or
parallel source of financial truth.
