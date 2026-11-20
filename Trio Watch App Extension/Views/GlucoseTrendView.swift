import SwiftUI

struct GlucoseTrendView: View {
    let state: WatchState
    let rotationDegrees: Double
    let isWatchStateDated: Bool

    /// Determines the status color based on the time elapsed since the last loop
    /// - Parameter timeString: The time string representing minutes since last loop (format: "X min")
    /// - Returns: A color indicating the status:
    ///   - Green: <= 5 minutes
    ///   - Yellow: 5-10 minutes
    ///   - Red: > 10 minutes or invalid time
    private func statusColor(for timeString: String?) -> Color {
        guard let timeString = timeString,
              timeString != "--",
              let minutes = timeString.split(separator: " ").first.flatMap({ Int($0) })
        else {
            return Color.secondary
        }

        guard !isWatchStateDated else {
            return Color.secondary
        }

        switch minutes {
        case ...5:
            return Color.loopGreen
        case 5 ... 10:
            return Color.loopYellow
        case 11...:
            return Color.loopRed
        default:
            return Color.secondary
        }
    }

    var circleSize: CGFloat {
        switch state.deviceType {
        case .watch40mm:
            return 82
        case .watch41mm,
             .watch42mm:
            return 86
        case .watch44mm:
            return 96
        case .unknown,
             .watch45mm:
            return 103
        case .watch49mm:
            return 105
        }
    }

    var lineWidth: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return 1
        case .unknown,
             .watch45mm:
            return 1.5
        case .watch49mm:
            return 1.5
        }
    }

    var shadowRadius: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm:
            return 8
        case .watch44mm:
            return 9
        case .unknown,
             .watch45mm:
            return 12
        case .watch49mm:
            return 12
        }
    }

    var currentGlucoseFontSize: Font {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm,
             .watch42mm,
             .watch44mm:
            return .title2
        case .unknown,
             .watch45mm:
            return .title
        case .watch49mm:
            return .title
        }
    }

    var minutesAgoFontSize: CGFloat {
        switch state.deviceType {
        case .watch40mm,
             .watch41mm:
            return 9
        case .unknown,
             .watch42mm,
             .watch44mm:
            return 10
        case .watch45mm:
            return 11
        case .watch49mm:
            return 10
        }
    }

    /// Spoken trend for the CGM direction the phone sends ("SingleUp", "Flat", ...).
    private var spokenTrend: String? {
        switch state.trend {
        case "DoubleUp",
             "TripleUp":
            return String(localized: "rising quickly", comment: "Accessibility: glucose trend")
        case "SingleUp":
            return String(localized: "rising", comment: "Accessibility: glucose trend")
        case "FortyFiveUp":
            return String(localized: "rising slowly", comment: "Accessibility: glucose trend")
        case "Flat":
            return String(localized: "steady", comment: "Accessibility: glucose trend")
        case "FortyFiveDown":
            return String(localized: "falling slowly", comment: "Accessibility: glucose trend")
        case "SingleDown":
            return String(localized: "falling", comment: "Accessibility: glucose trend")
        case "DoubleDown",
             "TripleDown":
            return String(localized: "falling quickly", comment: "Accessibility: glucose trend")
        default:
            return nil
        }
    }

    /// "Glucose 120, rising, delta +3", or "Glucose unavailable" when the data is stale.
    private var glucoseAccessibilityLabel: String {
        guard !isWatchStateDated, state.currentGlucose != "--" else {
            return String(localized: "Glucose unavailable", comment: "Accessibility: no fresh glucose")
        }
        var parts = [String(localized: "Glucose", comment: "Accessibility: glucose label") + " " + state.currentGlucose]
        if let trend = spokenTrend { parts.append(trend) }
        if let delta = state.delta, delta != "--", !delta.isEmpty {
            parts.append(String(localized: "delta", comment: "Accessibility: glucose delta") + " " + delta)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(statusColor(for: state.lastLoopTime), lineWidth: lineWidth)
                    .frame(width: circleSize, height: circleSize)
                    .background(Circle().fill(Color.bgDarkBlue))
                    .shadow(color: statusColor(for: state.lastLoopTime), radius: shadowRadius)

                TrendShape(
                    isWatchStateDated: isWatchStateDated,
                    rotationDegrees: rotationDegrees,
                    deviceType: state.deviceType
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: rotationDegrees)
                .shadow(color: Color.black.opacity(0.5), radius: 5)

                VStack(alignment: .center) {
                    Text(isWatchStateDated ? "--" : state.currentGlucose)
                        .fontWeight(.semibold)
                        .font(currentGlucoseFontSize)
                        .foregroundStyle(isWatchStateDated ? Color.secondary : state.currentGlucoseColorString.toColor())

                    if let delta = state.delta {
                        Text(isWatchStateDated ? "--" : delta)
                            .fontWeight(.semibold)
                            .font(.system(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // one element for value, trend and delta, instead of "--" fragments and an unlabelled arrow
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(glucoseAccessibilityLabel))

            Spacer()

            Text(
                isWatchStateDated ?
                    String(localized: "STALE DATA", comment: "Information displayed when watch app data outdated or stale.") :
                    state
                    .lastLoopTime ?? "--"
            )
            .font(.system(size: minutesAgoFontSize))
            .fontWidth(isWatchStateDated ? .expanded : .standard)

            Spacer()

        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
