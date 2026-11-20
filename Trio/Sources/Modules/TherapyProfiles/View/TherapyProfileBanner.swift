import SwiftUI

/// The profile a therapy editor edits.
struct TherapyProfileBannerInfo: Equatable {
    let name: String
    let isActive: Bool

    /// Nil for an editor of the live settings while Default is the only profile.
    static func make(manager: TherapyProfileManager, profileName: String?) -> TherapyProfileBannerInfo? {
        let active = manager.activeProfileName
        if let profileName {
            return TherapyProfileBannerInfo(name: profileName, isActive: profileName == active)
        }
        guard manager.profiles().count > 1 else { return nil }
        return TherapyProfileBannerInfo(name: active, isActive: true)
    }
}

/// The next scheduled start that changes the active profile, for display only. Starts of the profile that is already
/// active change nothing and are skipped; paused starts never run (see `nextOccurrence`).
struct NextTherapyProfileSwitch: Equatable {
    let profileName: String
    let date: Date

    static func find(
        in switches: [ScheduledProfileSwitch],
        activeProfileName: String,
        after now: Date,
        calendar: Calendar = .current
    ) -> NextTherapyProfileSwitch? {
        switches.filter { $0.profileName != activeProfileName }
            .nextOccurrence(after: now, calendar: calendar)
            .map { NextTherapyProfileSwitch(profileName: $0.entry.profileName, date: $0.date) }
    }

    /// "22:00" when it is today, "Sat 22:00" otherwise.
    func shortTimeText(now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Switches to Night at 22:00" / "Switches to Weekend Sat 07:00"
    func text(now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(
                localized: "Switches to \(profileName) at \(shortTimeText(now: now, calendar: calendar))",
                comment: "Next scheduled therapy profile switch today; first %@ is a profile name, second a clock time"
            )
        }
        return String(
            localized: "Switches to \(profileName) \(shortTimeText(now: now, calendar: calendar))",
            comment: "Next scheduled therapy profile switch on another day; first %@ is a profile name, second a weekday and time like \"Sat 07:00\""
        )
    }
}

struct TherapyProfileBanner: View {
    let info: TherapyProfileBannerInfo

    var body: some View {
        HStack {
            Text("Profile \(info.name)")
                .bold()
            Spacer()
            Text(info.isActive ? String(localized: "Active") : String(localized: "Not active"))
                .foregroundStyle(info.isActive ? Color.green : Color.secondary)
        }
        .padding()
        .background(Color.chart.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top)
        .accessibilityElement(children: .combine)
    }
}
