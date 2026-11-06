# Connection replacement device acceptance — 2026-11-05

This supplements the implementation snapshot's pre-rollout status.

## Backup and rollout

Before installing the build, both the shared financial App Group and Networth's
ordinary app container were copied locally, including database journals. All
four copied Networth databases passed SQLite quick_check. A local checksum
manifest accompanies the backup; backup contents are excluded from git.
No direct phone database edits were performed.

The user installed the build through Xcode and confirmed normal launch. In
Settings → App & Data → Connections & Sync → Manage Banking Accounts, the user
reviewed overlapping accounts, completed automatic and explicit transaction
matching, and received successful replacement confirmations. Manual review
included one-day date differences and multiple indistinguishable candidates.

The user verified that the surviving connection contained all intended accounts,
removed the connection labeled Replaced, completed Sync Now, and reviewed retained
history and saved work. The user reported that the result looked good.

## Validation limits

- Four pure matching tests passed; generic-device Debug build-for-testing and
  Release build passed before rollout.
- App integration tests compiled but were not executed. No simulator was used.
- Physical-device launch, review, replacement, retired-connection removal,
  subsequent sync, and user review of saved history passed.
- Private-iCloud upload/restore and interrupted-save recovery remain unverified
  on device. Normal launch does not establish complete migration coverage.

The user authorized a scoped documentation/code commit after acceptance; no push
was requested. Unrelated repository changes remain outside this commit.
