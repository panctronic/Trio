import Observation
import SwiftUI
import Swinject

extension ConfigEditor {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored var file: String = ""
        var configText = ""

        override func subscribe() {
            configText = provider.load(file: file)
        }

        func save() {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()
            provider.save(configText, as: file)
        }
    }
}
