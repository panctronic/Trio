import SwiftUI

/// What sharing usage data means, in the words shown wherever Trio asks for consent: the onboarding step and the
/// one-time prompt for users who never chose. Mirrors `TelemetryPrivacyView` and `TelemetryClient.buildPayload()`.
struct TelemetryConsentExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                "Trio can send the Trio team a small, anonymous usage report once a day. It helps the team see which app versions, devices, pumps and CGMs are in use, so testing and support can focus on what people actually run."
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("What is sent").bold()
                Text(
                    "App version and build, device model and iOS version, language and time zone, the paired pump and CGM models, whether Nightscout, Tidepool and Apple Health are set up (yes/no only), a few app settings (units, closed loop on/off, Live Activity, calendar), and random identifiers for this install."
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What is never sent").bold()
                Text(
                    "Glucose, insulin, carbs or any other health data, therapy settings, logs, and your Nightscout, Tidepool or other credentials."
                )
            }

            Text(
                "Nothing is sent unless you agree. You can change this at any time in Settings > Features > App Diagnostics, where you can also see the exact report."
            )
            .font(.footnote)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One-time, dismissible prompt for users who set Trio up before usage data sharing became opt-in. "Not Now" records
/// no choice, so nothing is sent; it puts the Home banner that opened it away for a while (`onNotNow`).
struct TelemetryConsentSheet: View {
    let onChoice: (Bool) -> Void
    let onNotNow: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    TelemetryConsentExplanation()
                        .foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        // Equal weight on purpose: neither answer is the "default" one.
                        Button {
                            onChoice(true)
                            dismiss()
                        } label: {
                            Text("Share Usage Data").frame(maxWidth: .infinity)
                        }
                        Button {
                            onChoice(false)
                            dismiss()
                        } label: {
                            Text("Don't Share").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("Share Usage Data?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") {
                        onNotNow()
                        dismiss()
                    }
                }
            }
        }
    }
}
