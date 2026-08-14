# 2026-08-12 — Networth Review & Direction (Synthesis)

Consolidates two same-day reviews into one reference:
- the UX/product review (`2026-08-12-ux-product-review.md`), and
- the product-focus recommendations (`2026-08-12-product-focus-recommendations.md`).

This document supersedes both for planning purposes. Nothing here is locked
scope — any information-architecture change must be recorded as a separate
decision in `docs/PLAN.md` before implementation.

**Context that shapes priorities:**
- **Single-user app** (the owner). Broad-audience concerns — branding polish,
  newcomer onboarding, wide-audience accessibility — are deprioritized. What
  matters is the owner's daily decisions, the correctness of the numbers they
  read, and the friction they hit.
- **YNAB is a legacy remnant.** Plaid is the real data source. YNAB scaffolding
  should be removed, not merely hidden, even though `PLAN.md` still frames it as
  an active staged migration source.

---

## Thesis

**Make Networth smaller and provably trustworthy before adding another major
product surface.** The next real work is not a new feature — it is making the
cash projection understandable and reproducible top to bottom. New surfaces
earn their place only by making an existing answer clearer, more accurate, or
more actionable.

The app answers four essential questions, in priority order:

1. **Projections** — Am I safe, and what money is coming or leaving? *(primary
   daily workflow)*
2. **Spending** — Where did my money go, and how does it compare with income?
3. **Net Worth** — How is my overall position changing? *(supporting scorecard)*
4. **Goals** — What money have I reserved, and for what?

**Product guardrail:** a new feature should help answer one of these four
questions without introducing another planning system, spending-limit concept,
or parallel source of financial truth.

---

## Overall assessment

Strong, opinionated, architecturally disciplined (off-main data building, a
single design-token system, semantic colors routed properly, real drill-downs
throughout). It genuinely attempts "what can I safely do with my money right
now?" and models the credit-card-timing forecast — the real differentiator —
seriously.

**The central weakness: the app is most articulate exactly when you need it
least, and goes quiet when you need it most.** The interpreted cash answer is
excellent when everything is healthy and degrades to a dead end the moment
there is a problem. Everything below serves fixing that.

---

## The #1 problem — explainability has two broken halves

The north star is an interpreted sentence ("Covered through Aug 18; your low is
$1,240 on Aug 12 after a $2,180 card payment"). It fails in two complementary
ways:

**Half A — the in-the-moment headline (UX).** When cash is healthy the user
gets a clean, tappable "Available $X" answer that drills into a rich explainer.
When cash is tight / negative / an account is underfunded, the same slot
collapses to a one-line status sentence that is **not tappable and has no
drill-down** — and the best causal explanation the app can produce is already
computed and **never rendered** (confirmed dead code, defined once, referenced
nowhere). So in exactly the states the app exists to catch, the user gets a red
sentence with no "why."

**Half B — the deep audit (math).** Beyond the headline, every consequential
number should be independently reproducible: every complete month used for
expected spending, each monthly total and the arithmetic-mean equation, and a
full reconciliation of starting cash → income → scheduled obligations → card
payments → expected ordinary spending → buffer → Safe to Spend, with every
inclusion/exclusion explained. Plus the already-planned local CSV export for
deeper review.

**Fix:** these are one job. Make every projection state give an interpreted
answer *and* a one-tap "why" (wire the existing explanation string; make the
tight/negative/underfunded headlines and shortfall banners tappable). Land that
"why" in a Projection Audit sheet that satisfies Half B. Do both and the
forecast is trustworthy end to end.

---

## Things to REMOVE / reduce

- **All YNAB scaffolding** (now legacy) — "Map YNAB Accounts," "Build YNAB
  Reference," "Find & Reclassify," the token/reference-import section, YNAB-only
  closed-account controls, and the tutorial's "Connect YNAB" step. Keep only what
  is needed to read the retained historical cache, if anything.
- **Migration, resync, reconciliation, and repair tools → an Advanced area** so
  routine Settings expose only routine decisions. (With YNAB gone, most of this
  disappears outright.)
- **Investment-reconciliation controls on ordinary banking accounts** — scope
  them off accounts where they don't apply.
- **Developer diagnostics in the Net Worth "info" screen** — "Possible
  Double-Count," ".live/.backfill" markers, snapshot counts. Move behind a debug
  flag; replace with a plain "what's in this number" explainer.
- **Dead code / stub files** — three "Removed during rebuild" placeholders remain,
  plus the unused explanation string (wire it in per #1, or delete).
- **Redundant components** — two near-identical inline-message components
  ("banner" vs "inline notice"); two near-identical manual-asset editing sheets
  (Settings vs Investments detail). Collapse each pair to one.
- **Duplicated Investments info** — Allocation and Holdings restate each other,
  and the percentage repeats in both the allocation row and each holding row.
- **Residual budget / envelope / spending-limit language** not required to
  explain the projection engine.
- **Keep the higher-spending projection case subordinate** to the arithmetic-mean
  baseline — a supporting scenario, never a competing headline.

---

## Things to IMPROVE

### Projections (core)
- **Answer parity across all states** (see #1) — the biggest single fix.
- **Consolidate the vocabulary.** The app uses "Outlook," "Available," "Spending
  Room," "Extra spending room," "Everyday reserve," "Everyday spending reserve,"
  "Known commitments," "Known account lows," "Cash buffer," "Buffer gap,"
  "Projected low," "Projected cash." Several name the same quantity. One word per
  concept, everywhere — naming drift erodes trust in a forecast.
- **Surface always-visible detail one level up** — the only persistent dated list
  is "Next Cash Activity" (5 items); per-account coverage and the commitment
  ledger are 2–3 taps deep. At minimum, make the chart low-point marker tappable
  to its cause.

### Investments — a correctness/trust issue (not an analytics ask)
- The hero "**balance change over 30 days**" is a *balance delta, not return* —
  deposits/withdrawals inflate it, clarified only in a once-seen tutorial
  footnote. **Fix the label** (and ideally separate contributions from market
  movement). This is correctness; it is *not* an argument for building
  performance analytics, which should stay out of scope.

### Spending — reduce load, surface hidden gestures
- Most overloaded screen — review card, month menu + range picker, hero total
  with two secondary metrics + comparison, a nested pie with a benchmark ring, a
  24-month scrollable bar chart, and a transactions link — three chart idioms
  competing. Lead with one primary visualization; demote the rest.
- **Invisible interactions:** month nav is an unmarked swipe, "reset to all
  spending" is an undiscoverable card tap, group reorder hides in a legend
  context-menu *and* a management sheet, and legend rows have two tap targets
  (name selects a chart; amount opens a sheet) with no visual distinction. Make
  the primary ones visible; give the dual-purpose rows an affordance.

### Goals — lower the vocabulary, freeze the scope
- "Reserve pool," "residual goal gets all unallocated money," "transfer needed"
  reconciliation — a powerful envelope model wrapped in jargon. Soften copy to
  plain outcomes, and reconsider whether bank-transfer matching belongs on the
  Goals screen.
- **Freeze Goals at current scope.** Do not restore contribution schedules,
  coaching, goal types, or additional ledger concepts without a new product
  decision.

### Settings — separate altitudes
- Split everyday controls (Sync Now, cash accounts, buffer, card timing) from
  advanced/data-plumbing tools.
- The **Plaid backend token has no home** in Settings — it only appears
  mid-connect, so there's no path to replace it outside an error state. Give it a
  row.
- **Two "Claude" features** (transaction-classification fallback vs the MCP
  data-sharing opt-in) share the name on different pages. Rename one.

### System-wide
- **Color & dark mode** — the brand "accent" teal and "positive/success" teal are
  nearly identical; semantic colors have no dark-mode tuning (only charts do).
  Differentiate accent from positive; verify contrast on dark surfaces.
- **Dynamic Type** *(personal call, single user)* — the type scale uses fixed
  point sizes and ignores the system text-size setting. Only worth doing if the
  owner wants larger text; otherwise low priority.

---

## Things to ADD (each must pass the product guardrail)

- **"Can I Afford This?" scenario sheet.** Enter an amount and approximate date;
  the existing engine returns whether projected cash stays above buffer, the
  revised Safe to Spend, the revised low point/date, and whether a transfer
  between selected accounts would be required. Lightweight sheet, not a new tab or
  a persistent budgeting system. *(The active form of the daily decision.)*
- **"Safe to spend $X through {date}" Lock/Home Screen widget.** Get the primary
  answer onto glass the owner already looks at, without opening the app. Most
  north-star-aligned addition; surfaces an existing answer, adds no new system.
  *(The passive form of the daily decision.)*
- **Proactive low-point / underfunded-card alert.** One push notification —
  "Checking dips below buffer in 4 days" — turns the app from a radar you must
  open into a radar that warns you.
- **"What Changed?" post-sync summary.** After sync, surface only *actionable*
  changes — a card-payment estimate moved, the projected low point shifted, a
  balance went stale, a new transaction materially changed the outlook. Must not
  become an activity feed. (Also closes the product's own unanswered question,
  "What changed my position?")
- **An uncertainty/confidence signal on the forecast** — the main chart shows a
  single confident line; a light confidence band matches "useful without
  appearing guaranteed."

---

## Open decision — should Investments remain a top-level tab?

Portfolio value, allocation, history, and holdings are components of net worth.
The question is whether Investments supports a genuinely distinct, frequent
decision, or should fold into Net Worth. This touches the locked five-tab
structure and needs an explicit `PLAN.md` decision either way.

**Recommendation: keep it, but slim it** — fix the balance-change label and drop
the allocation-vs-holdings duplication. Holdings drill-down and "how are my
investments doing" is a distinct enough decision that burying it in the balance
sheet costs more than the freed tab slot saves. This is the owner's call.

---

## Recommended order

1. **Projection explainability** — Half A is complete on
   `projection-explainability`: trouble-state answer parity, the wired causal
   explanation, and one-tap access to Projection Details. Half B remains: the
   full Projection Audit and planned local CSV export.
2. **Finish in-flight trust work** — scope investment-reconciliation controls
   correctly, diagnose the Goals transition stall, establish a safe
   stale-balance recovery path for cash.
3. **Remove YNAB; move remaining reconciliation/repair to Advanced.**
4. **"Can I Afford This?"** scenario sheet.
5. **Safe-to-Spend widget + low-point alert** — get the answer onto glass.
6. **"What Changed?"** post-sync summary.
7. **Decide the Investments-tab question; then freeze scope** and evaluate the
   app through sustained real-world use.

Deprioritized given single-user scope: branding mismatch ("BlueLava NetWorth"
vs "Networth"), newcomer onboarding, empty-state CTAs for newcomers,
wide-audience accessibility.
