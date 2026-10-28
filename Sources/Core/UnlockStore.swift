import Combine
import Foundation

/// StoreKit stub — unlock flags without IAP wiring yet.
final class UnlockStore: ObservableObject {
    static let shared = UnlockStore()

    @Published private(set) var isUnlocked: Bool

    private let key = "kiln.unlocked"

    init() {
        // Dev default: unlocked for local clone.
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        isUnlocked = UserDefaults.standard.bool(forKey: key)
    }

    func setUnlocked(_ value: Bool) {
        isUnlocked = value
        UserDefaults.standard.set(value, forKey: key)
    }
}
