# 2026-08-12 — UX / Product Review

A design and product review of the app against its own north star: **near-term
cash-flow confidence for a single user (the owner), with net worth as the
supporting long-term scorecard.**

**Context that shapes priorities:**
- **Single-user app.** Recommendations that only matter for "other people"
  (broad-audience branding polish, first-run onboarding for strangers,
  wide-age accessibility) are deprioritized. What matters is *your* daily
  decisions, correctness of the numbers *you* read, and friction *you* hit.
- **YNAB is a legacy remnant.** It was the original data source and has been
  superseded by Plaid. Its scaffolding should be removed, not merely hidden.

---

## Overall assessment

Strong, opinionated, and architecturally disciplined (off-main data building,
a single design-token system, semantic colors routed properly, real
drill-downs throughout). The ambition is correct: it tries to answer "what can
I safely do with my money right now?" rather than just draw balances, and it
takes the credit-card-timing forecast — the genuine differentiator — seriously.

**The central problem: the app is most articulate exactly when you need it
least, and goes quiet when you need it most.** That theme recurs across the
product and is where the highest-value work is.

---

## #1 issue — the interpreted answer disappears in trouble states

The north star is an interpreted sentence ("You're covered through Aug 18; your
low is $1,240 on Aug 12 after a $2,180 card payment").

- **Healthy path:** delivered well — a tappable "Available $X" headline that
  drills into a rich "Spending Room" explainer.
- **Trouble path (tight / negative / underfunded card):** the same slot
  collapses to a one-line status sentence ("Cash gets tight on Aug 12") that is
  **not tappable and has no drill-down.**

The app *already computes* the best causal explanation it has — a string that
reads roughly "After a $2,180 card payment. Total cash can cover it, but at
least $X must be in Checking before then" — and **it is dead code, computed and
never rendered** (confirmed: defined once, referenced nowhere). So in exactly
the scenarios the app exists to catch, the user gets a red sentence and a red
dot, and the explanation is one-to-three taps away or unreachable.

**Fix (highest leverage in the app):** every projection state should give an
interpreted answer *and* a one-tap path to "why." Wire up the existing
explanation string; make the tight/negative/underfunded headlines and the
shortfall banners tappable straight to the cause and the fix.

---

## Things to REMOVE

- **All YNAB scaffolding** (now legacy). In everyday Settings this still shows
  "Map YNAB Accounts," "Build YNAB Reference," "Find & Reclassify," the YNAB
  token/reference-import section, and YNAB-only closed-account controls — sitting
  next to a simple "Sync Now." Retire the whole migration surface; keep only what
  is needed to read the retained historical cache (if anything). The tutorial's
  "Connect YNAB" step should go too.
- **Developer diagnostics leaking into the Net Worth "info" screen** — "Possible
  Double-Count," ".live/.backfill" markers, "Backfill marker," snapshot counts.
  Move behind a debug flag; replace the user-facing version with a plain "what's
  in this number" explainer.
- **Dead code / stub files** — three "Removed during rebuild" placeholder files
  remain, plus the unused explanation string (wire it in per #1, or delete).
- **Redundant components** — two near-identical inline-message components
  ("banner" vs "inline notice"), and two near-identical manual-asset editing
  sheets (Settings vs Investments detail) with overlapping Deposit / Withdrawal /
  Update-Total modes. Each pair should be one.
- **Repeated allocation percentages on Investments** — Allocation and Holdings
  restate each other, and the percentage appears in both the allocation row and
  each holding row.

---

## Things to IMPROVE

### Projections (the core)
- **Answer parity across all states** (see #1) — the biggest single fix.
- **Consolidate the vocabulary.** The app currently uses "Outlook,"
  "Available," "Spending Room," "Extra spending room," "Everyday reserve,"
  "Everyday spending reserve," "Known commitments," "Known account lows," "Cash
  buffer," "Buffer gap," "Projected low," "Projected cash." Several name the same
  or adjacent quantities. One word per concept, everywhere — inconsistent naming
  makes a forecast feel less trustworthy.
- **Surface always-visible detail one level up.** The only persistent dated list
  is "Next Cash Activity" (5 items); per-account coverage and the commitment
  ledger are buried 2–3 taps deep. At minimum, make the chart's low-point marker
  tappable to "here's what causes this low."

### Investments — a correctness/trust issue
- The hero "**balance change over 30 days**" is a *balance delta, not return* —
  deposits and withdrawals inflate it, and it's only clarified in a tutorial
  footnote seen once. Relabel honestly and, ideally, split contributions from
  market movement — that's the number that actually informs a decision.

### Spending — reduce load, surface hidden gestures
- Most overloaded screen: review card, month menu + range picker, hero total
  with two secondary metrics and a comparison, a nested pie *with a benchmark
  ring*, a 24-month scrollable bar chart, and a transactions link — three chart
  idioms competing. Lead with one primary visualization; demote the rest.
- **Invisible interactions:** month navigation is an unmarked swipe, "reset to
  all spending" is an undiscoverable card tap, group reorder hides in a legend
  context-menu *and* separately in a management sheet, and legend rows have two
  tap targets (name selects a chart; amount opens a sheet) with no visual
  distinction. Make the primary ones visible; give the dual-purpose rows an
  affordance.

### Goals — lower the vocabulary
- "Reserve pool," "residual goal gets all unallocated money," "transfer needed"
  reconciliation — a powerful envelope model wrapped in jargon. Soften copy to
  plain outcomes, and reconsider whether bank-transfer matching belongs on the
  Goals screen at all.

### Settings — separate altitudes
- Split everyday controls (Sync Now, cash accounts, buffer, card timing) from
  advanced/data-plumbing tools. With YNAB gone, most of the plumbing disappears
  anyway.
- The Plaid backend token has **no home** in Settings — it only appears
  mid-connect, so there's no path to replace it outside an error state. Give it a
  row.
- **Two "Claude" features** (transaction-classification fallback vs the MCP
  data-sharing opt-in) share the name on different pages. Rename one.

### System-wide
- **Color & dark mode:** the brand "accent" teal and the "positive/success" teal
  are nearly identical — brand and success read as the same color. Semantic
  colors (navy, amber, red) have no dark-mode tuning; only charts do.
  Differentiate accent from positive and verify contrast on dark surfaces.
- **Dynamic Type** *(personal call, single user):* the type scale uses fixed
  point sizes and ignores the system text-size setting. Only worth doing if you
  personally want larger text; otherwise low priority.

---

## Things to ADD

- **Lock Screen / Home Screen widget: "Safe to spend $X through {date}."** For an
  app whose primary daily job is cash-flow confidence, the highest-leverage
  addition is getting that one answer onto glass you already look at, without
  opening the app. Most aligned with the north star; doesn't exist yet.
- **Proactive alerts for the low point / underfunded card.** A radar that only
  warns when opened isn't really a radar. One notification — "Checking dips below
  buffer in 4 days" — is the difference between catching a problem and not. (Your
  plan defers "payday-to-bill alerts"; for a single-user daily tool this is worth
  pulling forward.)
- **"What changed my net worth?" attribution.** Your own product questions list
  "What changed my position?" as Q5, but it isn't surfaced. A month-over-month
  bridge (income, spending, market movement, debt paydown) closes that loop.
- **An uncertainty/confidence signal on the forecast** — the main chart shows a
  single confident line; a light confidence band matches the "useful without
  appearing guaranteed" principle.

---

## Suggested order of work

1. **Projection answer-parity + wire the explanation string** — trouble states
   get an interpreted answer and a one-tap "why." This is the product.
2. **Remove YNAB scaffolding** — now pure legacy; simplifies Settings
   dramatically and removes dual-provider leakage.
3. **Relabel the Investments 30-day "change"** — a correctness/trust bug.
4. **Add the Safe-to-Spend widget** — flagship next feature, north-star-aligned.
5. **De-densify Spending and surface its hidden gestures.**
6. Everything else (component consolidation, Settings altitude, color tuning,
   dead-code cleanup) — real but secondary.

Deprioritized given single-user scope: branding mismatch ("BlueLava NetWorth" vs
"Networth"), broad-audience onboarding, empty-state CTAs for newcomers,
wide-audience accessibility.
