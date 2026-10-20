# Architecture Cleanup Plan

Date: 2026-10-19
Status: Proposed for review; implementation has not started.

## Objective

Make Networth easier to maintain while preserving its current financial
behavior, stored data, and interface. Deliver small, independently reviewable
passes rather than one broad refactor.

## Basis and current findings

This plan follows the September 10 architecture audit and a targeted source
inspection on October 18. The audit is historical evidence, not an authoritative
inventory of current defects. Recheck each candidate before changing it.

- Settings, Spending History, and Plaid sync together contain approximately
  19,300 lines. Screens, data aggregation, and other responsibilities remain
  combined in these files.
- Disabled legacy client/sync implementations remain on disk.
- Legacy reimbursement compatibility still participates in active processing;
  it cannot be treated as unused code.
- Projection headline rules remain in the view layer, and Spending still has
  an inline dollars-to-milliunits conversion.
- The audit calls repeated retired-provider purging a defect, but PLAN.md
  explicitly describes per-launch cleanup. Resolve that intent before changing
  startup behavior.

Reference: [Architecture audit](2026-09-10-architecture-audit-hotspot-map.md).

## Proposed sequence

### 1. Confirm the cleanup inventory

- Recheck audit findings against current callers, tests, and persistence needs.
- Classify candidates as unused code, organizational changes, behavior changes,
  or migration work.
- Produce an explicit removal/move list before editing.

Acceptance: each candidate has current evidence and an identified validation
method; historical audit claims are not used as proof of safety.

### 2. Remove verified unused code

- Start with disabled legacy client and sync implementations.
- Remove unused views and helpers only after checking references.
- Preserve persisted compatibility fields, model registrations, and historical
  identifiers pending a separate migration review.

Acceptance: Debug and Release builds pass; active behavior remains unchanged.

### 3. Separate responsibilities in the largest files

- Move transaction-review screens out of Settings.
- Separate Spending's data aggregation from its UI.
- Separate sync, reconciliation, and optional export responsibilities.
- Move database-loading actors into Services, preserving their execution and
  refresh behavior. Do not introduce view models.
- Add app files through Xcode, following the project rules.

Acceptance: navigation, editing, saving, and refresh behavior remain unchanged.
Complete and validate one extraction before starting another.

### 4. Centralize financial decision logic

- Establish one tested source for projection-headline precedence.
- Extract suitable pure financial helpers into NetworthCore.
- Replace inline currency conversion with the shared money implementation.
- Establish existing expected behavior before consolidating logic; review any
  discovered defect separately from the extraction.

Acceptance: focused tests cover existing outcomes and relevant edge cases,
including rounding and competing projection statuses where applicable.

### 5. Review active legacy dependencies

- Identify records and workflows still relying on reimbursement compatibility.
- Plan retirement without changing approved transaction meanings or
  relationships.
- Resolve whether repeated launch cleanup is intentional before changing it.
- Keep necessary persisted-ID compatibility distinct from retired-provider
  classification or runtime behavior.

Acceptance: an explicit compatibility plan precedes implementation. Any needed
data migration becomes a separately reviewed task, with live store locations
and backups verified before destructive operations.

### 6. Strengthen persistence safeguards

- Reduce duplication in model registration while preserving store membership.
- Add targeted checks for cache versus private-CloudKit placement.
- Review safeguards keeping local IBR data out of persisted snapshots.

Acceptance: no unintended schema changes, data movement, or new transmission
paths; Debug and Release builds pass. Document any intentional schema change
and its CloudKit implications before proceeding.

### 7. Address measured performance issues

- Review broad queries and repeated calculations exposed by the cleanup.
- Make targeted improvements only where evidence supports them.
- Keep the category-search investigation paused.

Acceptance: demonstrate reduced work while preserving financial results and
refresh behavior. Do not claim latency improvement without measurement.

## Validation and delivery

- Run relevant NetworthCore tests for domain changes and generic-device builds
  for structural changes.
- Verify both Debug and Release for persistence, security, startup, or
  configuration changes.
- Do not launch or test on an iOS Simulator unless explicitly requested.
- Distinguish app tests that merely compile from tests that actually ran.
- Record specific physical-device checks for affected areas, particularly
  transaction review, reimbursements, Spending, and Projections.
- Keep each pass focused and independently reviewable. Preserve unrelated
  staged work and local artifacts. Do not commit or push without instruction.

## Out of scope

- New product features or visual redesigns.
- Resuming the paused category-search investigation.
- Credential deletion.
- Destructive migrations or automatic changes to live device records.
- Removing compatibility fields or model registrations as routine cleanup.

## Recommended first delivery

Complete the verified inventory and unused-code cleanup, then review the
result before structural extraction. Settings is the recommended first
extraction target.

## Independent review request

Review this plan against the current repository without editing code. Focus on
missing risks, sequencing, unnecessary work, persistence compatibility, and
whether proposed unused-code removals have live callers or data dependencies.
Separate confirmed findings from hypotheses and cite current source locations.
Do not assume the September audit is still accurate or resume paused work.
