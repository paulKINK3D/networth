# Transaction Review Performance Investigation

## Reported symptom

On a physical iPhone, the Plaid transaction review screen feels laggy. The
`Split transaction` toggle is the clearest reproduction. Amount entry and the
rest of the review screen also feel slow.

The user confirmed that none of the attempted changes below produced a
noticeable on-device improvement.

## Attempts that did not improve performance

### Directory lookup indexing

- Replaced repeated contact/category scans during body evaluation with
  dictionaries prepared when the review screen appears.
- Changed split validation to use indexed category lookups.
- Pre-created the two initial split drafts instead of creating them in the
  toggle's `onChange`.

**Result:** No noticeable improvement on-device.

### Review-screen structural changes

- Kept split and non-split controls alive and switched their visibility instead
  of conditionally rebuilding them.
- Replaced the fixed controls plus nested transaction-history scroll pane with
  one screen-level scroll container.

**Result:** No noticeable improvement on-device.

### Category-picker destination preparation

- Found that `PlaidCategoryPicker.init` grouped and locale-sorted the complete
  category option list.
- Moved grouping and sorting into the one-time directory preparation path.
- Passed precomputed category groups into each picker destination.

**Result:** No noticeable improvement on-device.

### Currency-label formatting

- Replaced per-render currency `NumberFormatter` construction with Foundation
  currency format styles.

**Result:** No noticeable improvement on-device.

## Related input work

The same session added payment-terminal-style currency entry (`83898` becomes
`838.98`) and a UIKit-backed split amount field. The split field uses the
native digit keypad plus a standard `inputAccessoryView` toolbar with a system
`Done` button. The remaining split balance is hidden while an amount field is
active.

These input changes are separate from the unsuccessful performance work, but
the UIKit-backed field is part of the current review-screen render path and
must be included in future profiling.

## Validation completed

- `NetworthCore`: 79 tests passed.
- Generic iPhone Debug builds passed after the changes.
- Simulator performance testing was not performed, per repository guidance.

## Required next step if investigation resumes

Do not make another optimization based only on code inspection.

Measure the physical-device interaction first using Instruments or targeted
signposts around:

1. `PlaidTransactionReviewEditor.body`;
2. split-toggle state mutation and view reconciliation;
3. `NwAccessoryCurrencyTextField.makeUIView` / `updateUIView`;
4. SwiftData `@Query` observation updates; and
5. navigation destination construction.

Use the measurement to identify the blocking main-thread work before changing
the implementation. Revert unsuccessful structural/indexing changes if they
do not support the measured fix.
