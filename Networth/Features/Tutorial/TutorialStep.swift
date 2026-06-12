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
            lede: "A personal net-worth tracker that turns YNAB into a full financial picture — assets, liabilities, history, and projections.",
            bullets: [
                "Net worth = your YNAB accounts plus any manual assets you add.",
                "Up to 5 years of history reconstructed from your YNAB transactions on first sync.",
                "Forward-looking projections, including credit card statement forecasts."
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
                "Top: current net worth — assets minus liabilities.",
                "Chart: up to 5 years of history with month-over-month deltas.",
                "Breakdown: balances grouped by account type (checking, credit, manual, etc.)."
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
            icon: .projections,
            iconTint: NwAppColors.primary,
            title: "The Projections tab",
            lede: "What your money looks like over the next 90 days.",
            bullets: [
                "Credit card statement forecast — projected balance per card based on scheduled charges and payments.",
                "Cash position chart — solid line uses scheduled transactions; dashed line adds an estimated daily drain from recent variable spending.",
                "Spending by Category — tap chips to focus on a subset like food or transport.",
                "All forecasts are computed locally — Networth never writes anything back to YNAB."
            ],
            footnote: "Tune the lookback window and exclude categories (e.g. investments) from Settings → Projections."
        ),

        TutorialStep(
            id: 6,
            icon: .creditCard,
            iconTint: NwAppColors.accent,
            title: "Set up your credit cards",
            lede: "For accurate statement forecasts, tell Networth when each card closes.",
            bullets: [
                "Settings → Credit Card Statements → tap a card.",
                "Set the statement close day (e.g. 17 for a card that closes on the 17th of each month).",
                "That's it — the projection shows what'll be due on your next statement."
            ],
            footnote: "You only need to do this once per card unless your issuer changes the cycle."
        ),

        TutorialStep(
            id: 7,
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
            id: 8,
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
            id: 9,
            icon: .success,
            iconTint: NwAppColors.positive,
            title: "You're set",
            lede: "One last step to seed your data.",
            bullets: [
                "Settings → Sync Now. First sync takes a few seconds and reconstructs up to 5 years of history.",
                "Add any manual assets you want included.",
                "Open the Projections tab once your cards have close days configured.",
                "Re-open this tutorial any time from Settings → Show Tutorial."
            ],
            footnote: nil
        )
    ]
}
