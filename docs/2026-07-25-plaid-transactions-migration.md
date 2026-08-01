# Plaid Transactions Migration

## Locked data model

YNAB is the canonical migration source. Plaid is the future feed.

Before Plaid can become primary, Networth imports the selected YNAB budget's:

- payees, including stable YNAB payee IDs;
- category groups and categories, including hidden/deleted source state;
- transactions, including payee IDs, category IDs, transfer IDs, import IDs,
  and split legs; and
- account identities used to reconcile each Plaid account.

Networth then owns four durable, editable tables in private CloudKit:

- `DurableCanonicalPayee`: the contact/payee directory seeded by YNAB;
- `DurablePayeeAlias`: many pieces of Plaid identity evidence that resolve to
  one contact;
- `DurableCanonicalCategory`: the category directory seeded by YNAB and
  extended by user-created Networth categories; and
- `DurableCanonicalTransactionDecision`: the exact contact, category,
  treatment, and optional split legs confirmed for one Plaid transaction.

Names and categories can be edited locally without writing back to YNAB.
Future YNAB refreshes update their source snapshots but do not overwrite a
user-edited local value. Contacts can be merged, aliases can be reassigned, and
categories can be renamed, regrouped, or hidden.

The former merchant-fingerprint rules and transaction-review overrides are not
part of the active classification path. A one-way local migration deletes that
review output, resets derived Plaid review fields, and forces a full YNAB
transaction/payee replay. Raw cached YNAB and Plaid rows, account mappings, and
user-created categories are preserved.

## Reconciliation

Historical reconciliation starts only after:

1. every active Plaid account has an explicit YNAB match or is marked new;
2. every Plaid historical import reports complete; and
3. the YNAB contact/category directory and transaction cache are present.

Candidates require the same canonical account, exact milliunit amount, and a
date within the posting-delay window. Matching uses a maximum-cardinality
assignment so one plausible row cannot consume another row's only exact
candidate. Ambiguous duplicate candidates remain unconfirmed.

For every automatic historical match, YNAB supplies the exact contact,
category, transfer treatment, and split legs. These rows do not return to
review. Rebuilding local match evidence never deletes durable transaction
decisions, including when the disposable YNAB cache is unavailable.

Plaid evidence is learned as aliases only when all exact historical examples
for that evidence resolve to the same YNAB contact. Evidence includes stable
merchant/counterparty entity IDs, specific merchant/counterparty names, and a
normalized description. Generic labels such as `payment` or `transfer` are not
contacts.

## Future transactions and learning

Every newly posted transaction requires user confirmation before it enters
projection history. A resolved contact and consistent history may prefill the
review, but never approve it.

Each confirmation:

- attaches all useful Plaid identity evidence to the selected contact;
- records one durable transaction decision;
- adds that confirmed decision to future category evidence; and
- leaves the review requirement enabled for later transactions.

When a contact has been used with multiple categories or treatments, Networth
does not choose the most recent one as a global rule. The new transaction
starts without a category preselection unless the relevant confirmed evidence
is consistent.

Apple on-device inference may provide a transient name/category suggestion for
a new unmatched row. Optional Claude fallback is off by default and receives
only privacy-bounded Plaid classification text—never amount, date, balance,
account identifiers, or YNAB history. AI suggestions never create confirmed
contacts, aliases, categories, or decisions by themselves.

Card payments and internal transfers do not require a spending category.
Historical YNAB transfer IDs determine their treatment during reconciliation.
Historical hidden categories remain valid on the exact matched transaction,
but are not offered for unrelated future choices. New manual splits require at
least two active categories and exact milliunit equality with the parent.

## Performance boundaries

- Review counters use `fetchCount`, not full-table `@Query` arrays.
- The review sheet fetches one posted row at a time with `fetchLimit = 1`.
- Review counts remain zero until historical import and the current
  reconciliation version are complete, so a partial import never becomes a
  moving review queue.
- Historical matching runs only after explicit account reconciliation and is
  version-gated.
- Account history is independently paginated.
- Contact/category management searches their durable directory, not every
  transaction.
- Editing a contact/category updates only rows and decisions linked by its
  stable canonical ID.

## Cutover gate

`Make Plaid Primary` is unavailable unless:

- active Plaid financial accounts exist;
- account mappings are complete;
- YNAB-derived contacts and categories exist;
- all historical transaction imports and reconciliation are complete; and
- there are no unresolved contact or transaction reviews.

At cutover, Plaid becomes the balance and future transaction source and the
YNAB PAT is removed. The local YNAB cache remains as read-only migration/audit
history. Loans and the local IBR bridge keep their existing behavior.

## CloudKit deployment

Before a TestFlight build, initialize and deploy these additive record types:

- `DurableCanonicalAccountBinding`
- `DurableCanonicalPayee`
- `DurablePayeeAlias`
- `DurableCanonicalCategory`
- `DurableCanonicalTransactionDecision`

Also deploy the new defaulted/optional fields on `DurableUserSettings`,
`DurablePayeeAlias` (`suppressed`),
`DurableCanonicalTransactionDecision` (`amountSign`),
`CachedTransaction`, and `CachedFinancialTransaction`. Legacy merchant-rule,
custom-category, and override record types remain in the schema for migration
compatibility and one-time cleanup; they are not active classifier inputs.

## Plaid cost and deployment gate

Transactions is a Plaid subscription product billed per connected Item.
Production pricing is account/agreement-specific. This implementation does not
call Transactions Refresh or Recurring Transactions.

Before production deployment:

1. confirm Production Transactions access and the exact per-Item price;
2. deploy the additive CloudKit schema;
3. run Worker tests and type checking;
4. deploy the Worker;
5. sync one institution through historical completion;
6. compare its YNAB/Plaid account mapping and a sample of exact matches; and
7. complete transaction review before making Plaid primary.
