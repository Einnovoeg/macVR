import Foundation
import simd

public struct XrActionSet: @unchecked Sendable {
    public let name: String
    public let localizedName: String
    public var isActive: Bool

    public init(name: String, localizedName: String) {
        self.name = name
        self.localizedName = localizedName
        self.isActive = false
    }
}

public enum XrActionType: Sendable {
    case pose
    case boolean
    case float
    case vector2f
    case vector3f
    case haptic
}

public struct XrPath: @unchecked Sendable, Hashable {
    public let id: UInt32

    public init(_ id: UInt32) {
        self.id = id
    }
}

public final class OpenXRActionManager: @unchecked Sendable {
    private var actionSets: [String: XrActionSet] = [:]
    private var actions: [String: XrAction] = [:]
    private var bindings: [String: [XrPath]] = [:]
    private let lock = NSLock()

    public init() {}

    public struct XrAction: Sendable {
        public let name: String
        public let type: XrActionType
        public let actionSet: String

        public init(name: String, type: XrActionType, actionSet: String) {
            self.name = name
            self.type = type
            self.actionSet = actionSet
        }
    }

    public func createActionSet(name: String, localizedName: String) -> XrActionSet {
        lock.lock()
        defer { lock.unlock() }

        let actionSet = XrActionSet(name: name, localizedName: localizedName)
        actionSets[name] = actionSet
        return actionSet
    }

    public func createAction(name: String, type: XrActionType, actionSetName: String) -> XrAction {
        lock.lock()
        defer { lock.unlock() }

        let action = XrAction(name: name, type: type, actionSet: actionSetName)
        actions[name] = action
        return action
    }

    public func suggestBindings(actionSetName: String, actionName: String, paths: [XrPath]) {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(actionSetName)/\(actionName)"
        bindings[key] = paths
    }

    public func getActionStateBoolean(actionName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return false
    }

    public func getActionStateFloat(actionName: String) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return 0.0
    }

    public func getActionStateVector2(actionName: String) -> SIMD2<Float> {
        lock.lock()
        defer { lock.unlock() }
        return .zero
    }

    public func getActionStatePose(actionName: String) -> (position: SIMD3<Float>, orientation: simd_quatf, isTracked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (.zero, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), false)
    }

    public func applyHaptic(actionName: String, hand: Int, intensity: Float, duration: Double) {
        print("Haptic: action=\(actionName), hand=\(hand), intensity=\(intensity), duration=\(duration)")
    }

    public func getBindings(for actionSetName: String, actionName: String) -> [XrPath] {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(actionSetName)/\(actionName)"
        return bindings[key] ?? []
    }

    public func activateActionSet(name: String) {
        lock.lock()
        defer { lock.unlock() }

        for (key, var actionSet) in actionSets {
            actionSet.isActive = (key == name)
            actionSets[key] = actionSet
        }
    }

    public func deactivateActionSet(name: String) {
        lock.lock()
        defer { lock.unlock() }

        if var actionSet = actionSets[name] {
            actionSet.isActive = false
            actionSets[name] = actionSet
        }
    }

    public func syncActions() {
        lock.lock()
        defer { lock.unlock() }
    }
}

public struct InputProfile: Sendable {
    public let name: String
    public let actions: [OpenXRActionManager.XrAction]

    public init(name: String, actions: [OpenXRActionManager.XrAction]) {
        self.name = name
        self.actions = actions
    }
}

public final class OpenXRInputProfileManager: @unchecked Sendable {
    private var profiles: [String: InputProfile] = [:]
    private let defaultProfile: InputProfile

    public init() {
        let defaultActions: [OpenXRActionManager.XrAction] = [
            OpenXRActionManager.XrAction(name: "trigger_click", type: .boolean, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "trigger_value", type: .float, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "grip_click", type: .boolean, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "grip_value", type: .float, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "trackpad_x", type: .float, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "trackpad_y", type: .float, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "trackpad_click", type: .boolean, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "button_a", type: .boolean, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "button_b", type: .boolean, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "pose", type: .pose, actionSet: "default"),
            OpenXRActionManager.XrAction(name: "haptic", type: .haptic, actionSet: "default"),
        ]

        defaultProfile = InputProfile(name: "default", actions: defaultActions)
        profiles["default"] = defaultProfile
    }

    public func getProfile(_ name: String) -> InputProfile? {
        return profiles[name]
    }

    public func registerProfile(_ profile: InputProfile) {
        profiles[profile.name] = profile
    }
}
