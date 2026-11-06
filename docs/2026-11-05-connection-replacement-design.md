# Reusable banking connection replacement

Status: design in progress; matching foundation implemented, no live consolidation.

## Problem and outcome

Connecting the same bank accounts again gives them new provider identifiers.
Networth currently creates new canonical accounts and transaction rows, while
the user's reviews and settings remain attached to the originals. Removing the
original connection deletes its cached history without transferring that work.

Replacement must retain the original canonical account and transaction identities,
adopt the new connection as their provider source, preserve older history, and
leave genuinely new accounts intact. This is a reusable workflow, not Chase-specific
cleanup. Chase's authorization selects the complete account set for a connection;
the app must not describe it as an additive selection operation.

## Proposed flow

1. After connecting, identify possible overlaps using institution, mask, account
   type, and currency. These are suggestions, never proof of account identity.
2. Present each possible overlap for review: keep as a separate account, or replace
   the connection for an existing account. Multiple candidates require selection.
3. Preview matched transactions, retained older history, new activity, and conflicts.
   Never overwrite reviews, splits, notes, or settings on either side silently.
4. Resolve ambiguous transaction groups explicitly. Never zip identical purchases
   together by fetch order, identifier order, or whichever record was returned first.
5. Apply a durable replacement mapping and verified history preservation locally.
   Finish and verify this step before offering to retire the old remote connection.
6. Keep remote removal as a separate, explicit action. A failed disconnect must be
   retryable without repeating or reversing the completed local consolidation.

## Identity and persistence requirements

- Preserve existing canonical account IDs so card configuration, payment overrides,
  Spending pins, recurring expectations, and historical account references survive.
- Preserve existing transaction IDs and decision identities. New provider transaction
  IDs need durable aliases to those identities, including for modified/removed sync
  events, pending-to-posted transitions, and full cursor replay.
- Preserve original split-line IDs so reimbursement allocations, Savings assignments,
  Reserve links, and notes continue to resolve.
- Account nickname overrides keyed by provider ID need deliberate reassociation.
- Retain older transactions absent from the replacement feed. Their storage and
  recovery policy must be settled before implementing schema changes: a copy only
  in the disposable cache cannot promise recovery after cache loss or device restore.
- Persist replacement progress so interruption, retry, and CloudKit restoration
  cannot bring back duplicate accounts or double-count transactions.
- Detect edits on both copies and require conflict resolution; do not prefer the
  older copy solely because it is older.
- Block removal if any account unique to the old connection has not been preserved
  or explicitly handled. Do not infer that removing a bank connection affects only
  its transaction product when the Item also supplies investments.
- Keep local cache and durable user-data stores separate. Any additive schema needs
  migration notes and Debug/Release build validation. No field renames/deletions.

## Matching and dates

The pure matching helper accepts explicit provider civil dates, signed milliunit
amounts, and normalized descriptions within an already selected account pair.
It returns unique matches, ambiguous groups, retained history, and new transactions.

The inspected Chase cache contains differently anchored timestamps for the same
provider civil dates. Raw Date equality and current-timezone day conversion are
not reliable matching keys. Preserve original provider date strings for future
imports and explicitly resolve legacy date reconstruction before applying a plan.
Never silently widen matching to adjacent days merely to increase the match count.

## Open product decision

User was asked whether suspected new duplicate accounts should be held outside
financial totals until reviewed, or included immediately and flagged. Pending.
The recommended choice is to hold them for review. This needs consistent handling
in balances, Spending, cash projections, notifications, and account selection.

## Acceptance criteria

- Replacement does not change totals except for genuinely new bank activity or
  explicitly accepted corrections.
- All reviews, splits, notes, reimbursements, account settings, and older history
  survive replacement and subsequent sync.
- New-only accounts remain available.
- Ambiguous matches and conflicting user edits cannot be silently committed.
- Repeated sync, full resync, interrupted apply, failed remote removal, and restore
  do not duplicate or lose records.
- Tests cover account ambiguity, missing identity evidence, transaction ambiguity,
  preserved history, date anchors, durable mapping replay, failures, and retries.
- Before live consolidation, verify resolved store URLs and back up the shared
  App Group and ordinary app container; the earlier inspection copies are not a
  complete pre-migration backup.

## Current work

- Existing connection-management UI now lists account names/masks and exposes the
  existing update-mode flow; uncommitted from earlier work.
- Added `ConnectionReplacementMatching` to NetworthCore, with focused passing tests
  for conservative account suggestions, unambiguous transaction matching, ambiguous
  groups, and retention of older history. Not yet connected to production sync/UI.
- No connection removed, no live account/transaction mapping changed, and no
  persistence schema changed.
