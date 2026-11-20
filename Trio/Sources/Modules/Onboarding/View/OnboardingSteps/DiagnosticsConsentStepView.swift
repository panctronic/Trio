import SwiftUI

/// Onboarding step asking whether Trio may share anonymous usage data. There is no preselected answer: Next stays
/// disabled until the user picks one, and nothing is sent unless they pick "Share".
struct DiagnosticsConsentStepView: View {
    @Bindable var state: Onboarding.StateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TelemetryConsentExplanation()
                .font(.body)
                .foregroundColor(Color.secondary)

            VStack(spacing: 12) {
                option(
                    value: true,
                    title: String(localized: "Share Usage Data"),
                    caption: String(localized: "Send the daily anonymous usage report.", comment: "Onboarding usage data option caption")
                )
                option(
                    value: false,
                    title: String(localized: "Don't Share"),
                    caption: String(localized: "Trio sends no usage data.", comment: "Onboarding usage data option caption")
                )
            }
        }
        .padding(.horizontal)
    }

    private func option(value: Bool, title: String, caption: String) -> some View {
        let isSelected = state.telemetryConsentChoice == value
        return Button {
            state.telemetryConsentChoice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).bold().foregroundColor(.primary)
                    Text(caption).font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color.chart.opacity(0.65))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(caption))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
