import Foundation
import SwiftUI

// MARK: - Carbs Input View

struct CarbsInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var carbsAmount: Double = 0.0 // Needs to be Double due to .digitalCrownRotation() stride
    @FocusState private var isCrownFocused: Bool // Manage crown focus

    let state: WatchState
    let continueToBolus: Bool

    private var effectiveCarbsLimit: Double {
        Double(truncating: state.maxCarbs as NSNumber)
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    private func decrementCarbs() {
        if carbsAmount > 0 {
            carbsAmount < 5 ? carbsAmount = 0 : (carbsAmount -= 5)
        }
    }

    private func incrementCarbs() {
        carbsAmount = min(effectiveCarbsLimit, carbsAmount + 5)
    }

    /// "20 grams", plus a warning once the carb limit is reached
    private var carbsSpokenValue: String {
        let amount = String(format: "%.0f", carbsAmount) + " " + String(localized: "grams", comment: "Grams unit")
        guard carbsAmount > 0.0, carbsAmount >= effectiveCarbsLimit else { return amount }
        return amount + ", " + String(localized: "Carbs Limit Reached!")
    }

    var body: some View {
        let buttonLabel = continueToBolus ? String(localized: "Proceed", comment: "Button Label to Proceed to Bolus on Watch") :
            String(localized: "Log Carbs", comment: "Button Label to Log Carbs on Watch")

        // TODO: introduce meal setting fpu enablement to conditional handle FPU
        VStack {
            Spacer()

            HStack {
                // "-" Button
                Button(action: decrementCarbs) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .tint(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(carbsAmount <= 0)
                .accessibilityLabel(Text("Decrease carbs"))
                .accessibilityHint(Text("Subtracts 5 grams", comment: "Accessibility hint for the watch carbs minus button"))

                Spacer()

                // Display the current carb amount
                Text(String(format: "%.0f \(String(localized: "g", comment: "gram of carbs"))", carbsAmount))
                    .fontWeight(.bold)
                    .font(.system(.title2, design: .rounded))
                    .foregroundColor(carbsAmount > 0.0 && carbsAmount >= effectiveCarbsLimit ? .loopRed : .primary)
                    .focusable(true)
                    .focused($isCrownFocused)
                    .digitalCrownRotation(
                        $carbsAmount,
                        from: 0,
                        through: effectiveCarbsLimit,
                        by: 1,
                        sensitivity: .medium,
                        isContinuous: false,
                        isHapticFeedbackEnabled: true
                    )
                    // VoiceOver takes over the crown, so the amount itself is adjustable with swipes
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Carbohydrates"))
                    .accessibilityValue(Text(carbsSpokenValue))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: incrementCarbs()
                        case .decrement: decrementCarbs()
                        @unknown default: break
                        }
                    }

                Spacer()

                // "+" Button
                Button(action: incrementCarbs) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .tint(.orange)
                }
                .buttonStyle(.borderless)
                .disabled(carbsAmount >= effectiveCarbsLimit)
                .accessibilityLabel(Text("Increase carbs"))
                .accessibilityHint(Text("Adds 5 grams", comment: "Accessibility hint for the watch carbs plus button"))
            }.padding(.horizontal)

            Text("Carbohydrates")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom)
                // already spoken as the label of the amount above
                .accessibilityHidden(true)

            Spacer()

            if carbsAmount > 0.0 && carbsAmount >= effectiveCarbsLimit {
                Text("Carbs Limit Reached!")
                    .font(.footnote)
                    .foregroundColor(.loopRed)
            }

            Button(buttonLabel) {
                if continueToBolus {
                    state.carbsAmount = Int(min(carbsAmount, effectiveCarbsLimit))
                    navigationPath.append(NavigationDestinations.bolusInput)
                } else {
                    state.sendCarbsEntry(Int(min(carbsAmount, effectiveCarbsLimit)))
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(!(carbsAmount > 0.0) || carbsAmount > effectiveCarbsLimit)
        }
        .background(trioBackgroundColor)
        // The entry's 2 min clock restarts whenever the user touches it
        .onAppear { state.markEntryEdited() }
        .onChange(of: carbsAmount) { state.markEntryEdited() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "fork.knife")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }
}
