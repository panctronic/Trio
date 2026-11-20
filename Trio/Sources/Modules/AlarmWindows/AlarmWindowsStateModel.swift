import Observation
import SwiftUI

extension AlarmWindows {
    @Observable final class StateModel: BaseStateModel<Provider> {
        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            units = settingsManager.settings.units
        }
    }
}

extension AlarmWindows.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
