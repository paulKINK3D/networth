import SwiftUI
import NetworthCore

struct PATEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainerController.self) private var container
    @State private var token: String = ""
    @State private var error: String?
    @State private var saving: Bool = false

    var body: some View {
        NwModalLayout(
            title: "YNAB Personal Access Token",
            onClose: { dismiss() },
            onConfirm: save,
            confirmDisabled: token.isEmpty || saving
        ) {
            VStack(alignment: .leading, spacing: NwSpacing.lg) {
                NwInlineNotice(
                    "Read-only access",
                    message: "Networth uses your token to read accounts and transactions. It never writes to YNAB.",
                    tone: .info
                )

                VStack(alignment: .leading, spacing: NwSpacing.sm) {
                    Text("Token")
                        .font(NwTypography.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    SecureField("Paste your token", text: $token, prompt: Text("Paste your token"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(NwTypography.body)
                        .padding(NwSpacing.md)
                        .background(NwAppColors.cardSurface)
                        .clipShape(RoundedRectangle(cornerRadius: NwCornerRadius.md, style: .continuous))
                }

                if let error {
                    NwInlineNotice("Couldn't save", message: error, tone: .warning)
                }

                if container.hasYNABToken {
                    Button(role: .destructive) {
                        Task { await clear() }
                    } label: {
                        Text("Remove Saved Token")
                    }
                    .buttonStyle(NwDestructiveButtonStyle())
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        saving = true
        Task {
            do {
                try await container.saveYNABToken(token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }

    private func clear() async {
        do {
            try await container.clearYNABToken()
            token = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
