# High-Level App Review

Date: 2026-08-21

## Overall Assessment

Networth is well beyond a prototype. It has a genuinely differentiated core: it models whether cash is safely available after card statements, scheduled obligations, ordinary spending, account-specific funding, and reserves—not merely whether total assets exceed liabilities.

The next level is not more financial features. It is making the existing answers exceptionally trustworthy, proactive, and unified.

## What Is Working Especially Well

- The projection engine is the strongest part of the product. Credit-card cycles, confirmed payment overrides, paychecks, transfers, refunds, spending history, cash buffers, and account-specific shortfalls are handled thoughtfully.
- The app clearly distinguishes spendable cash, reserved money, investments, and net worth.
- Financial arithmetic is precise and unusually well tested.
- Provider credentials and access tokens have appropriate boundaries. Remote Claude access is explicit, encrypted, revocable, and excludes raw provider details and unreviewed transactions.
- Durable personal decisions are separated from replaceable provider data.
- Spending, Goals, Investments, and Net Worth each have coherent internal models rather than superficial dashboard metrics.
- The visual system and interaction patterns are consistent, and expensive calculations generally stay away from the immediate rendering path.

## Highest-Priority Risks

### 1. The Biometric Re-Lock Behavior Does Not Fulfill Its Promise

“Re-lock after” is only applied during a later cold launch. If the app remains alive in memory, returning hours later can still expose it without authentication. Sensitive content may also remain visible in the app switcher. This should be treated as a security-critical fix.

### 2. A Persistence Startup Failure Can Masquerade as a Usable App

If the real stores cannot open, the app falls back to an in-memory preview environment. That risks presenting empty data and accepting changes that will not survive. A financial app should instead stop on an unmistakable recovery screen.

### 3. Some Data-Read Failures Look Like Legitimate Empty Financial Data

Failed reads are frequently converted into empty collections or default values. That can turn “data unavailable” into “zero balance,” “no history,” or an apparently valid forecast. Preserve the last trustworthy result and show an explicit degraded state.

### 4. Forecast Quality Depends on Transaction Review, but That Dependency Is Not Sufficiently Visible Within Projections

Unreviewed transactions are intentionally excluded from important calculations. The review count is prominent in Spending, but the cash outlook does not consistently say when its inputs are incomplete. Add a concise forecast-readiness indicator covering freshness, review backlog, history depth, and missing configuration.

### 5. Remote-Update Cache Freshness Deserves Hardening

Some large screens primarily detect changes through row counts and local-save events. Edits to existing rows arriving through CloudKit may not always invalidate those cached results promptly.

## Product Assessment

The app currently feels like four strong financial tools sharing a tab bar. The opportunity is to turn them into one daily loop:

**Review what changed → understand current spending → see upcoming cash risk → decide what is safely available.**

The first-run tour does not reinforce that loop. It gives substantial attention to net worth and investments while omitting Spending and Goals, even though Spending is the initial tab and the everyday entry point.

Goals is powerful, but it should remain frozen at its current scope. It already introduces substantial conceptual weight through reserve accounts, allocations, automatic remainder behavior, and transaction attribution.

## Best Next Product Move

Create a compact post-sync “Today” or “What Changed” summary that answers:

- How much is safely available, and through what date?
- What event creates the next low point?
- What materially changed since the previous successful sync?
- Is any payment account underfunded?
- Does anything require review before the forecast is fully trustworthy?

This would unify the product without adding another planning system.

After that, expose the same answer proactively through a widget and a narrowly scoped notification for genuine cash risks. A financial radar becomes dramatically more valuable when it warns before the user remembers to open it.

## Engineering Direction

The domain architecture is strong, but several major implementation areas have become very large and tightly packed. Retired-provider scaffolding also remains as non-running historical code and compatibility concepts.

The next maintenance phase should:

- Split large workflows into smaller, clearly owned services and UI components.
- Remove noncompiled historical implementations once migration safety no longer requires them.
- Replace silent defaults with explicit availability and error states.
- Add failure-path tests for store startup, CloudKit changes, partial synchronization, and biometric lifecycle behavior.
- Remove or rewrite disabled legacy tests rather than allowing them to become permanent archaeological layers.

## Recommended Order

1. Fix biometric lifecycle and app-switcher protection.
2. Replace the in-memory production fallback with a safe recovery state.
3. Make read failures and forecast readiness explicit.
4. Harden CloudKit-driven cache invalidation.
5. Add the post-sync “What Changed” daily summary.
6. Add the safe-to-spend widget and material-risk notification.
7. Decompose the largest implementation areas and retire remaining legacy scaffolding.

## Validation

- All 233 core financial tests passed.
- All 15 backend tests and static checks passed.
- Generic-device Debug and Release builds passed.
- The app-level test bundle compiled successfully; simulator execution was intentionally not performed.
- No project changes were made during the review itself.
