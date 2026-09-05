# Demo Mode Planning

## Assessment

Creating a demo mode is a moderate effort, and the current architecture already
provides most of the necessary infrastructure. The app can construct an
in-memory SwiftData container, and its external boundaries already have fake or
recorded implementations.

The main challenge is not activating demo mode. It is producing a coherent,
internally consistent financial scenario across accounts, transactions,
budgets, Savings, Reserves, Goals, credit-card forecasts, investments, and net
worth history.

## Recommended Shape

Use a dedicated demo container that:

- Uses an in-memory database with no persistent store.
- Uses fake services for biometrics, secrets, Plaid, transaction inference, and
  the local IBR bridge.
- Never touches CloudKit, Keychain, the Plaid backend, or real user data.
- Skips Face ID, onboarding, and automatic data refresh.
- Seeds dates relative to the current day so projections and monthly views do
  not become stale.
- Populates all four primary tabs and their important drill-downs.

For development and screenshot use, activate the mode through a debug launch
argument or a separate Xcode scheme. If demo mode must be available in a
TestFlight or Release build, it will need an explicit in-app entry mechanism
while preserving the same strict data and network isolation.

## Suggested Demo Scenario

A useful first scenario should include:

- Checking and savings accounts with realistic available balances.
- At least one credit card with a closed statement, upcoming autopay, current
  activity, and sufficient checking coverage.
- Six to twelve months of approved transactions so Spending Trends and
  projections are meaningful.
- Several Spending groups, repeating monthly targets, one featured group, and
  an automatic-remainder group.
- Savings activity and at least two Reserves with assignments and different
  target states.
- Two or three Goals backed by a designated savings account.
- Retirement and taxable investment accounts with holdings and balance
  history.
- Manual assets or liabilities and twelve months of net worth snapshots.
- A small number of transactions needing review so the review workflow can be
  demonstrated.

All values should be clearly synthetic and deterministic. Stable identifiers
should be used so relationships remain reproducible across tests and UI runs.

## Effort Estimate

- Basic populated four-tab demo: approximately one day.
- Convincing interactive demo with drill-downs and projections: two to four
  days.
- Polished reusable fixture system with edge-case scenarios and dedicated
  tests: four to seven days.

The recommended starting scope is the interactive two-to-four-day version. It
would provide strong visual and interaction coverage without risking real data.

## Likely Implementation Components

1. A single demo-data seeder responsible for constructing the complete
   scenario in dependency order.
2. A demo container factory built on the existing in-memory persistence and
   fake-service wiring.
3. An early launch-mode decision so the production container is never opened
   during a demo session.
4. Explicit suppression of refresh, Plaid Link, backend-token, Claude sync,
   and other external actions while demo mode is active.
5. Focused tests proving that the seeded scenario builds successfully, contains
   the expected records, and remains fully isolated from production storage and
   services.

## Decisions to Make Before Implementation

- Whether demo mode is development-only or must also be accessible from a
  Release/TestFlight build.
- Whether users may edit the synthetic data during a session or the demo is
  strictly read-only.
- Whether one representative scenario is sufficient or multiple named
  scenarios are needed for specific screenshots and edge cases.

