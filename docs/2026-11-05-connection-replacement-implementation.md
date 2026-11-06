# Banking connection replacement implementation

Supersedes the implementation status and open decisions in
`2026-11-05-connection-replacement-design.md`.

## Approved behavior

The user approved holding suspected duplicate accounts outside financial totals
until reviewed, and explicitly approved private-iCloud storage for retained
history after the distinction from the existing local-only provider cache was
explained. No live connection has been consolidated or removed during development.

Banking Connections displays each connection's accounts and has a Review accounts
section for held copies. A held account can be confirmed as separate, or used to
replace an existing account's connection. New linking returns to management so
the review is visible. An entirely replaced banking connection is marked Replaced.

## Preservation and retry behavior

- Canonical account IDs remain stable. Existing card settings, pins, payment
  overrides, and account references continue to resolve.
- Matched transactions retain their original IDs and external decision identities.
  Provider aliases route subsequent modifications and removals to those identities.
- Retained history snapshots include the original review and split state. Current
  durable decisions remain authoritative when reapplied after restoration.
- Existing user work on the incoming copy blocks replacement instead of being
  overwritten. Nickname conflicts also block application. The incoming copy can
  remain held while the conflict is resolved; Keep separate is an explicit decision.
- Unique transaction matches use civil date, signed amount, and normalized source
  description within a user-selected account pair. Identical groups require manual
  mapping. Unmatched incoming activity inside the old history window also requires
  an explicit match/new-activity decision. Empty evidence is never auto-matched.
- Apply recomputes the preview and rejects stale input. Each existing transaction
  may be selected only once.
- Archive and identity mappings save before local cache changes. A failure finishing
  the cache is recoverable on a later sync. This avoids assuming a cross-store save
  is atomic. Reconciliation also handles account mappings arriving through CloudKit
  before their transaction aliases, without retaining both provider and canonical rows.
- Superseded account bindings remain as durable identity records after remote Item
  removal. Replacement chains remain traversable on later reconnections.
- Fully superseded banking Items stop transaction sync. On partially superseded
  Items, obsolete accounts and removal events cannot overwrite preserved accounts.
- Provider removals are distinct from review holds and duplicate suppression.
  Removal tombstones prevent archive replay from resurrecting removed transactions.
- Removal remains an explicit separate action. It is blocked while overlapping
  accounts remain unresolved, local recovery is incomplete, or a partially replaced
  connection still supplies other banking accounts or cached investment accounts.

## Schema and CloudKit

All changes are additive. No existing fields are renamed or removed.

- `DurableCanonicalAccountBinding`: review state, replacement provider account ID,
  and currency. Empty review state on an existing row is evaluated at the next
  banking sync or management visit. A confirmed Separate decision is not re-held.
- `DurableConnectionTransactionIdentity`: new private-CloudKit model registered
  only in the durable and unified schemas. It stores provider-to-canonical identity,
  version-1 retained transaction/review JSON, civil-date metadata, and removal state.
  Future domain model changes must retain a compatible version-1 archive decoder.
- `CachedFinancialAccount`: local hold flag, default false.
- `CachedFinancialTransaction`: local hold flag, source civil date, and provider
  removal flag. Holds use the existing deleted filter to exclude rows consistently
  from current balances, Spending, projections, and review queues. Release restores
  only held rows; actual provider removals remain excluded.

Ordinary provider cache data and live account balances remain local-only. The
explicitly approved archive stores irreplaceable history selected through the
replacement workflow, not a routine copy of every future banking sync.

Legacy cached transactions lack their original provider date string. Their preview
uses the device calendar and requires manual resolution of unmatched overlapping
activity; it never silently widens the date window. New imports retain the provider
civil date independently of device timezone.

## Validation and live rollout boundary

Pure matching tests run through NetworthCore. App-level regression coverage checks
holding/releasing, preservation of identities and notes/settings, retained-history
restoration, stale previews, saved-work conflicts, ambiguous mapping, repeated
replacement, delayed alias arrival, provider removals, and unchanged live balances
on repeated recovery. App tests are compiled with generic-device build-for-testing;
they are not executed because simulator testing was not requested.

Debug and Release builds are required for this additive persistence change. Runtime
SwiftData migration, CloudKit upload/restore, interruption behavior, and the phone UI
remain device acceptance checks. Before applying this to live Chase data, verify
resolved store URLs and take fresh backups of the shared App Group and ordinary app
container. The earlier read-only inspection copies are not a complete rollout backup.

No production connection was disconnected, no phone database was edited, and no
new deployment or commit was performed for this feature.
