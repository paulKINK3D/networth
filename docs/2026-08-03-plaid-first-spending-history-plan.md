# Phase 1 — Plaid-First Financial Core and Spending History

## Summary

Keep the strong pre-budgeting product capabilities, but perform a destructive clean start for stored app data before rebuilding around Plaid. No existing Networth record is migrated or preserved.

The four tabs remain Net Worth · Spending · Projections · Investments. Net Worth, Cash Projections, and Spending History are equal product pillars; Investments and navigation changes are deferred to Phase 2.

## Implementation Changes

- Make Plaid the authoritative external financial-data source. Plaid Transactions supplies banking and credit-card accounts, balances, and transaction activity for Net Worth, Spending History, and Cash Projections. Plaid Investments separately supplies investment accounts, balances, and holdings through the existing reconciliation path. An investment balance represented by both Plaid paths contributes to Net Worth only once. Manual assets cover assets not represented by Plaid, and the local IBR bridge remains authoritative for the linked student loan. A missing required Plaid connection produces a connection state, never a YNAB fallback.
- Reposition YNAB as an optional reference source after the clean start. After Plaid history establishes the available coverage for each reconciled account, an explicit reference import fetches only the corresponding YNAB account and overlapping timeframe. It may seed new Networth-owned payees, category groups, categories, and classification suggestions, but raw YNAB accounts, balances, transactions, budgets, months, schedules, and API responses are not retained after processing and never affect reports. Preserve the existing YNAB token securely in Keychain for future reference imports; token presence never makes YNAB an active financial source.
- Preserve the Net Worth, Accounts, Investments, credit-card forecasting, manual-asset, and IBR product capabilities plus applicable performance and correctness fixes. Preserve none of their existing Networth records: manual assets, value history, snapshots, settings, mappings, decisions, caches, and legacy budget/fund data all start empty.
- Replace the current budget/funds screen with Spending History:
  - Month title with backward/forward arrows; forward stops at the current month.
  - Review card for posted Plaid transactions awaiting approval.
  - Selected-month total and vertical columns by spending category group.
  - Twenty-four-month stacked column chart, with each month stacked by category group.
  - Tapping any group segment opens that month/group detail.
  - Group detail shows categories; each category expands to approved transactions.
  - Current month is MTD; completed months show final totals.
- Count negative ordinary transactions as spending and positive refunds as offsets within the same category. Exclude income, investments, transfers, and credit-card payments from every spending total while retaining them in transaction history.
- Retain only user-authored recurring expectations as authoritative future events. They can be created manually or from an approved transaction; automatic recurring detection is deferred. Split approved history into matched recurring activity and remaining ordinary spending so a dated recurring expectation is never also reserved through the historical ordinary-spending estimate.
- Remove active budget targets, YNAB “Available” values, pace judgments, sinking funds, long-term goals, and coaching language. Keep legacy model registrations only where required for CloudKit/schema compatibility, but delete every legacy row during the clean start.

## Data and Interfaces

- Add a durable, user-owned category-group model with stable identity, display order, chart color, and reporting role: spending, income, investment, or transfer.
- Add an additive stable group reference to existing durable categories. Initial groups/categories may be imported from YNAB, but subsequent names, grouping, ordering, and visibility belong to Networth.
- Extend transaction treatment so investment contributions remain distinguishable from generic exclusions while staying outside spending.
- Track Plaid history coverage independently for every account, including the actual imported start and end dates and any known gaps. Never use one global history window as a substitute for account-specific coverage.
- After explicit Plaid-to-YNAB account reconciliation, fetch YNAB transactions only for that account's overlapping Plaid coverage. Do not import YNAB-only dates or accounts into the reference process.
- Build a local, rebuildable reference table by matching Plaid and YNAB transactions using reconciled account identity, amount, direction, bounded date proximity, merchant/payee evidence, and split structure. Store the matched Plaid and YNAB transaction identities, suggested canonical payee/category, forecast treatment, split suggestion, confidence, and provenance needed to explain and reproduce the suggestion.
- Treat every reference-table match as a suggestion rather than a reviewed decision. Unmatched or ambiguous Plaid transactions remain unreviewed, and only new user decisions made after the clean start are authoritative.
- Keep the reference table in the local re-fetchable tier, never CloudKit. After building it, discard raw YNAB responses and cache rows. A later explicit import may rebuild or extend reference evidence for newly available Plaid account coverage without overwriting confirmed user decisions.
- Add grouped historical review by suggested payee and category. Approving a cluster writes durable user decisions for its individual transactions; rejected or edited clusters become new training evidence.
- Make transaction review type-first. The user first confirms the transaction type, such as income, transfer, expense, refund, investment activity, or card payment. Only then show fields valid for that type: expenses and refunds require a category from a spending group, income requires a category from an income group, investment activity uses an investment group, and transfers or card payments use their applicable account relationship without an ordinary spending category. Do not allow an incompatible type/category combination to be saved.
- Keep new posted transactions in an individual review queue. Pending and unapproved transactions remain outside Spending History, Cash Projections, snapshots shared with Claude, and learning evidence.
- Add a user-owned recurring-expectation model containing account, optional destination account, payee/category, forecast treatment, direction, cadence, next occurrence, and user-entered expected amount.
- Project recurring expectations according to their cash behavior:
  - Checking, savings, and cash-account bills become dated cash outflows.
  - Income becomes a dated cash inflow.
  - Expected credit-card purchases increase the applicable projected statement balance; only the generated card autopay becomes a cash-account outflow.
  - Internal transfers move money between their source and destination accounts without changing aggregate cash.
  - Investment contributions remain outside Spending History but appear as cash outflows in Projections.
  - Credit-card payments remain generated by the existing statement/autopay forecaster and are not modeled as ordinary recurring expectations.
- Match an approved posted transaction to an expected occurrence using its durable account, payee/category, treatment, direction, and a bounded date window. The actual transaction replaces that occurrence, and the expectation advances only after the match or an explicit user action to skip or reschedule it.
- Derive the ordinary-spending reserve from approved Plaid history after removing historical activity matched to active recurring expectations. Add the remaining historical reserve and dated recurring events exactly once. YNAB schedules do not enter projections directly.
- Replace record-by-record migration with a versioned, destructive clean start. Delete every row from both Networth SwiftData stores, including all YNAB and Plaid caches, cursors, settings, account mappings, canonical directories, transaction decisions, merchant rules, manual assets and value history, Net Worth snapshots, investment balance history, projection/card configuration, and budget/fund records. Preserve the existing YNAB PAT in Keychain solely for future explicit reference imports. Do not migrate values from any old data row into the fresh stores.
- Leave only systems outside Networth storage untouched: Plaid Worker Item connections and the external read-only IBR App Group document. Re-fetch Plaid data from the existing Worker connections; require the user to re-enter app settings, card configuration, manual assets, classifications, and other user-owned data.
- Make the clean start idempotent and safe across CloudKit restores and multiple devices. Propagate CloudKit deletions, reject or purge any legacy row that reappears, and mark the fresh-start version complete only after both stores are empty and fresh default settings have been created. Record the first new Net Worth snapshot only after a successful Plaid sync. Net Worth history starts on that date and is never reconstructed from YNAB.
- After the clean start, normal launch and sync never contact YNAB. Only an explicit user-initiated “Build YNAB Reference” action may use the retained token. Determine Plaid coverage per reconciled account first, fetch only the corresponding overlapping YNAB history, build or extend the local reference table, then discard every raw YNAB cache row. Keep token removal independently available.

## Implementation Order

1. Perform the clean reset and establish the Plaid-first data foundation.
2. Build the account-scoped YNAB reference table and type-first transaction review workflow.
3. Build Spending History and its group/category/transaction drill-downs.
4. Add recurring expectations to Cash Projections with exact-once spending treatment.

## Test Plan

- Verify YNAB reference imports use the correct reconciled account and its exact Plaid overlap window, including accounts with different start dates, end dates, and known coverage gaps.
- Verify reference matching across exact and nearby dates, equal-amount collisions, opposite directions, transfers, refunds, card payments, and split transactions; ambiguous and unmatched rows must remain unreviewed.
- Verify YNAB reference imports create Networth-owned suggestions only, persist reference evidence only in the local re-fetchable tier, discard raw cache rows after processing, and cannot change reported balances, spending, Net Worth history, projections, or confirmed user decisions.
- Verify the clean start preserves the existing YNAB token in Keychain while deleting all YNAB-derived app data. Verify that the retained token never triggers automatic YNAB traffic or changes source authority and can be removed independently from Plaid operation.
- Verify users without a stored YNAB token remain fully functional in Plaid-first mode and are prompted for one only when they explicitly request a YNAB reference import.
- Verify grouped approval, edited clusters, individual future reviews, user-decision precedence, and classifier refinement.
- Verify the type-first review flow shows only valid category/account choices for the selected type and cannot persist an incompatible combination.
- Verify pending/unapproved transactions are excluded everywhere required.
- Verify monthly and group/category totals reconcile across refunds, splits, income, investments, transfers, card payments, deleted rows, and month boundaries.
- Verify 24-month chart construction, selected-month navigation, segment drill-down, stable ordering/colors, and timezone-safe grouping.
- Verify Cash Projections use Plaid balances, approved Plaid history, recurring expectations, and existing card forecasts without YNAB scheduled activity.
- Verify recurring activity is counted exactly once across the historical reserve, dated cash events, projected card statements, and generated card autopays.
- Verify actual-occurrence matching, date-window boundaries, skipped and rescheduled occurrences, income, cash-account bills, credit-card purchases, internal transfers, and investment contributions.
- Verify the versioned clean start removes every old local and CloudKit-backed row while preserving the YNAB token, including after interrupted attempts, CloudKit restores, and launches on another updated device.
- Verify no old manual asset, snapshot, setting, mapping, category, payee, transaction decision, investment balance, projection/card configuration, or budget/fund value survives or is copied into the fresh stores.
- Verify existing Plaid Worker connections can repopulate new Plaid caches, external IBR data remains read-only and untouched, and the first successful Plaid sync creates day one of the new Net Worth history.
- Run NetworthCore tests and generic-device Debug and Release builds; do not launch a simulator.

## Assumptions

- Work from the current branch without reverting it; retain cross-app performance and correctness fixes while surgically retiring budget/fund behavior.
- Spending History covers the latest 24 months available from Plaid.
- The tab label remains “Spending,” with “Spending History” as the screen title.
- Accounts remains behind Net Worth, and Investments remains unchanged in Phase 1.
- Goals, sinking funds, automatic recurring detection, and navigation reconsideration belong to Phase 2.
- The existing untracked goals/budget plan remains untouched; the canonical product plan will supersede it.
- The destructive loss of all existing Networth local and CloudKit-backed data is intentional and explicitly accepted; the redesign starts from fresh Plaid data and new user input.
