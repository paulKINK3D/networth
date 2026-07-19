import SwiftUI

/// Static content model for the in-app tutorial. Pure data — no logic, no IO.
/// Step copy lives here so future edits stay in one place.
struct TutorialStep: Identifiable, Sendable {
    let id: Int
    let icon: NwIcon
    let iconTint: Color
    let title: String
    let lede: String
    let bullets: [String]
    let footnote: String?
}

enum TutorialContent {
    static let steps: [TutorialStep] = [
        TutorialStep(
            id: 0,
            icon: .netWorth,
            iconTint: NwAppColors.primary,
            title: "Welcome to BlueLava Networth",
            lede: "A private financial radar for what you have, what is leaving, and whether upcoming obligations are safely covered.",
            bullets: [
                "Net worth = your YNAB accounts plus any manual assets you add.",
                "Up to 5 years of history reconstructed from your YNAB transactions on first sync.",
                "A forward cash outlook that includes scheduled activity, expected spending, and credit card autopays."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 1,
            icon: .keychain,
            iconTint: NwAppColors.primary,
            title: "How it works with YNAB",
            lede: "YNAB is the source of truth for everything you bank. Networth reads from it — never writes.",
            bullets: [
                "Pulls accounts, transactions, and scheduled transactions read-only.",
                "Stays well under YNAB's 200-requests-per-hour limit using delta sync.",
                "Your token is stored in iCloud-synced Keychain, never logged or exported."
            ],
            footnote: "You'll need an active YNAB subscription with at least one budget."
        ),

        TutorialStep(
            id: 2,
            icon: .keychain,
            iconTint: NwAppColors.accent,
            title: "Step 1 — Add your YNAB token",
            lede: "Generate a Personal Access Token in YNAB, then paste it once in Settings.",
            bullets: [
                "In YNAB: top-left avatar → My Account → Developer Settings → New Token.",
                "Copy the token — YNAB only shows it once.",
                "In Networth: Settings → Add YNAB Token → paste → save.",
                "Tap Sync Now in Settings to pull your first 5 years of history."
            ],
            footnote: "If you ever rotate the token in YNAB, just re-enter it here."
        ),

        TutorialStep(
            id: 3,
            icon: .netWorth,
            iconTint: NwAppColors.primary,
            title: "The Net Worth tab",
            lede: "Your headline number and the trend behind it.",
            bullets: [
                "Scorecard: current net worth, assets, liabilities, and the 30-day change.",
                "Trend: scrub through up to 5 years of history.",
                "Balance Sheet: tap any category to see the accounts and manual assets behind it."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 4,
            icon: .realEstate,
            iconTint: NwAppColors.accent,
            title: "Manual assets — for what YNAB doesn't track",
            lede: "Add anything that contributes to your net worth but isn't a bank account: home, car, retirement, brokerage, crypto, collectibles.",
            bullets: [
                "Settings → Add Manual Asset. Pick a kind, name, and current value.",
                "Each edit saves a dated value snapshot — you keep the full history.",
                "On the 1st of each month the app prompts you to refresh any asset older than 30 days."
            ],
            footnote: "Investment and retirement accounts are easiest as a single monthly balance — no per-symbol tracking needed."
        ),

        TutorialStep(
            id: 5,
            icon: .investment,
            iconTint: NwAppColors.accent,
            title: "The Investments tab",
            lede: "A single portfolio view across YNAB and the investment balances you update manually.",
            bullets: [
                "See total value, the 30-day change, and up to 5 years of reconstructed balance history.",
                "Allocation separates YNAB investments, brokerage, retirement, and crypto.",
                "Tap a holding for its balance history and activity, or to update a manual value."
            ],
            footnote: "Balance movement includes deposits and withdrawals; it is not investment-return attribution."
        ),

        TutorialStep(
            id: 6,
            icon: .projections,
            iconTint: NwAppColors.primary,
            title: "The Projections tab",
            lede: "Your daily answer for whether upcoming obligations are covered and when cash may get tight.",
            bullets: [
                "The headline shows your lowest expected cash balance, its date, and the event behind it.",
                "Known Commitments includes scheduled income, bills, transfers, and full-statement card autopays.",
                "Estimated monthly spending includes scheduled and unscheduled external outflows; the curve adds only spending not already represented by known events.",
                "Tap a card payment or the chart info button to see how the estimate was built.",
                "All forecasts are computed locally — Networth never writes anything back to YNAB."
            ],
            footnote: "Choose which cash accounts count, set your minimum cash buffer, and exclude unusual categories in Settings → Projections."
        ),

        TutorialStep(
            id: 7,
            icon: .creditCard,
            iconTint: NwAppColors.accent,
            title: "Set up your credit cards",
            lede: "For accurate cash timing, tell Networth when each card closes, pays, and which account funds it.",
            bullets: [
                "Settings → Credit Card Statements → tap a card.",
                "Set the statement close day (e.g. 17 for a card that closes on the 17th of each month).",
                "Set the autopay day and choose the checking, savings, or cash account that pays it.",
                "Networth assumes full-statement autopay and includes each expected debit in the cash outlook."
            ],
            footnote: "You only need to revisit this when the issuer changes the cycle or you change the payment account."
        ),

        TutorialStep(
            id: 8,
            icon: .sync,
            iconTint: NwAppColors.primary,
            title: "Get the most out of YNAB",
            lede: "A few habits in YNAB make every Networth number sharper.",
            bullets: [
                "Reconcile your accounts in YNAB regularly — Networth mirrors those balances exactly.",
                "Use scheduled transactions for paychecks and recurring bills — projections rely on them.",
                "Mark transactions as cleared once they hit your bank — the cash-position forecast uses cleared totals.",
                "Keep credit card payments categorised as transfers in YNAB so they net out correctly."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 9,
            icon: .lock,
            iconTint: NwAppColors.primary,
            title: "Security & sync",
            lede: "Your data stays yours, on your devices.",
            bullets: [
                "YNAB token: iCloud-synced Keychain. Never written to disk in plain text.",
                "Manual assets, history, and settings: CloudKit private database — only you can read it.",
                "Cached YNAB data: local-only, re-fetchable any time.",
                "Optional Face ID gate: Settings → Require Face ID."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 10,
            icon: .success,
            iconTint: NwAppColors.positive,
            title: "You're set",
            lede: "One last step to seed your data.",
            bullets: [
                "Settings → Sync Now. First sync takes a few seconds and reconstructs up to 5 years of history.",
                "Add any manual assets you want included.",
                "Choose your projection cash accounts and finish each card's statement and autopay setup.",
                "Re-open this tutorial any time from Settings → Show Tutorial."
            ],
            footnote: nil
        )
    ]
}
