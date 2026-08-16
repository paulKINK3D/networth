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
            lede: "See what you own, what is leaving, and whether cash is covered.",
            bullets: [
                "Track net worth across connected and manual accounts.",
                "See up to five years of balance history.",
                "Look ahead to bills, card payments, and everyday spending."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 1,
            icon: .keychain,
            iconTint: NwAppColors.accent,
            title: "Connect YNAB",
            lede: "Networth reads your YNAB data and never writes back.",
            bullets: [
                "YNAB: My Account → Developer Settings → New Token.",
                "Networth: Settings → Add YNAB Token.",
                "Your token stays in iCloud Keychain."
            ],
            footnote: "Requires an active YNAB subscription and budget."
        ),

        TutorialStep(
            id: 2,
            icon: .accounts,
            iconTint: NwAppColors.primary,
            title: "Net Worth & Accounts",
            lede: "Your current position and the balances behind it.",
            bullets: [
                "See assets, liabilities, and 30-day change.",
                "Scrub the chart to inspect earlier values.",
                "Add homes, cars, and other assets manually."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 3,
            icon: .investment,
            iconTint: NwAppColors.accent,
            title: "Investments",
            lede: "One portfolio across YNAB, Plaid, and manual balances.",
            bullets: [
                "Open Investments from the Net Worth Balance Sheet.",
                "Connect supported institutions through Plaid.",
                "Review connected accounts, then tap a holding for details."
            ],
            footnote: "Balance change includes deposits and withdrawals; it is not investment return."
        ),

        TutorialStep(
            id: 4,
            icon: .projections,
            iconTint: NwAppColors.primary,
            title: "Cash Outlook",
            lede: "See what is safe to spend and when cash gets tight.",
            bullets: [
                "Choose cash accounts and a minimum buffer.",
                "Set each card's close day, autopay day, and payment account.",
                "Confirm deposits so your paycheck is detected, and add recurring bills in Settings."
            ],
            footnote: nil
        ),

        TutorialStep(
            id: 5,
            icon: .lock,
            iconTint: NwAppColors.primary,
            title: "Private by Design",
            lede: "Sensitive data stays in your private stores.",
            bullets: [
                "Tokens stay in Keychain; Plaid credentials stay on the backend.",
                "Assets and settings use your private CloudKit database.",
                "Tap Sync Now in Settings to begin."
            ],
            footnote: nil
        )
    ]
}
