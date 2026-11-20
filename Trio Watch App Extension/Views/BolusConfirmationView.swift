import Foundation
import SwiftUI
import WatchKit

struct BolusConfirmationView: View {
    @Binding var navigationPath: NavigationPath
    let state: WatchState
    @Binding var bolusAmount: Double
    @Binding var confirmationProgress: Double

    @FocusState private var isCrownFocused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        let bolusIncrement = Double(truncating: state.bolusIncrement as NSNumber)
        let adjustedBolusAmount = floor(bolusAmount / bolusIncrement) * bolusIncrement

        VStack(spacing: 10) {
            Spacer()

            VStack {
                if state.carbsAmount > 0 {
                    HStack {
                        Text("Carbs:")
                        Spacer()
                        Text("\(state.carbsAmount) g")
                            .bold()
                            .foregroundStyle(.orange)
                    }.padding(.horizontal)
                }

                HStack {
                    Text("Bolus")
                    Spacer()
                    Text(String(format: "%.2f \(String(localized: "U", comment: "Insulin unit"))", adjustedBolusAmount))
                        .bold()
                        .foregroundStyle(Color.insulin)
                }.padding(.horizontal)
            }

            ProgressView(value: confirmationProgress, total: 1.0)
                .tint(confirmationProgress >= 1.0 ? .loopGreen : .gray)
                .padding(.horizontal)
                // VoiceOver uses the crown for navigation, so the bar fills with swipes instead
                .bolusConfirmationAccessibility(
                    progress: $confirmationProgress,
                    step: Self.voiceOverConfirmationStep(confirmBolusFaster: state.confirmBolusFaster),
                    hint: String(
                        localized: "Swipe up repeatedly to fill the bar and enact the bolus. Swipe down to step back.",
                        comment: "Accessibility hint for the watch bolus confirmation bar"
                    )
                )

            Text(
                isVoiceOverEnabled
                    ? String(localized: "To confirm, swipe up on the bar until it is full.", comment: "Watch bolus confirmation with VoiceOver")
                    : String(localized: "To confirm, dial crown.")
            )
            .font(.footnote)

            Spacer()

            Button("Cancel") {
                state.clearEntry()
                navigationPath.removeLast(navigationPath.count)
            }
            .buttonStyle(.bordered)
        }
        .focusable(true)
        .focused($isCrownFocused)
        .digitalCrownRotation(
            $confirmationProgress,
            from: 0.0,
            through: 1.0,
            by: state.confirmBolusFaster ? 0.5 : 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            isCrownFocused = true
        }
        .onChange(of: confirmationProgress) { _, newValue in
            if newValue >= 1.0 {
                WKInterfaceDevice.current().play(.success)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Sends carbs and bolus, or refuses an entry older than 2 min; either way the entry is cleared
                    state.sendConfirmedEntry(bolusAmount: bolusAmount)
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            } else if newValue > 0 {
                WKInterfaceDevice.current().play(.click)
            }
        }
        .navigationTitle("Confirm")
        .background(trioBackgroundColor)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(
                    systemName: Self.crownHintSymbolName(
                        wristLocation: WKInterfaceDevice.current().wristLocation,
                        crownOrientation: WKInterfaceDevice.current().crownOrientation
                    )
                )
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.insulin, Color.primary)
                .symbolEffect(
                    .variableColor.reversing,
                    options: .speed(100).repeating
                )
            }
        }
    }
}

extension BolusConfirmationView {
    /// How far one VoiceOver swipe fills the confirmation bar: four deliberate swipes, or two with "confirm bolus faster",
    /// matching the two crown detents that setting asks for. One swipe on its own can never confirm.
    static func voiceOverConfirmationStep(confirmBolusFaster: Bool) -> Double {
        confirmBolusFaster ? 0.5 : 0.25
    }

    /// SF Symbol shown in the toolbar to hint which way to turn the Digital Crown to confirm the bolus.
    ///
    /// watchOS measures crown turns relative to the screen, so the turn that fills the confirmation bar depends only on
    /// which side of the screen the crown is on, not on the wrist. Both settings are taken so tests can check every
    /// combination of how the watch is worn.
    static func crownHintSymbolName(
        wristLocation _: WKInterfaceDeviceWristLocation,
        crownOrientation: WKInterfaceDeviceCrownOrientation
    ) -> String {
        crownOrientation == .right ? "digitalcrown.arrow.clockwise.fill" : "digitalcrown.arrow.counterclockwise.fill"
    }
}

extension View {
    /// Makes a bolus confirmation bar usable with VoiceOver, which keeps the Digital Crown for itself: the bar reads as
    /// "Bolus confirmation, 25 percent" and fills by `step` per swipe up (back down per swipe down). The bar's own
    /// `onChange` then sends the bolus at 100 percent exactly as it does for the crown, so it still takes several
    /// deliberate gestures and a single tap does nothing.
    func bolusConfirmationAccessibility(progress: Binding<Double>, step: Double, hint: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Bolus confirmation", comment: "Accessibility label for the watch bolus confirmation bar"))
            .accessibilityValue(Text(progress.wrappedValue.formatted(.percent.precision(.fractionLength(0)))))
            .accessibilityHint(Text(hint))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    progress.wrappedValue = min(1.0, progress.wrappedValue + step)
                case .decrement:
                    // a full bar has already sent the bolus; stepping back would only confuse
                    guard progress.wrappedValue < 1.0 else { return }
                    progress.wrappedValue = max(0.0, progress.wrappedValue - step)
                @unknown default:
                    break
                }
            }
    }
}
