import Cocoa

/// 全局配置。动作与自定义图案以 JSON 存储，既可扩展又兼容旧版 UserDefaults 项。
final class Config {
    static let shared = Config()
    private init() {}

    private let defaults = UserDefaults.standard
    /// 每个模板需要在手势结束时参与匹配；限制数量可避免损坏或异常偏好拖慢事件回调。
    static let maximumCustomGestures = 64
    private static let maximumGestureNameLength = 80

    private enum Key {
        static let textFilePath = "textFilePath"
        static let minimumDist = "minimumDistance"
        static let gestureEnabled = "gestureEnabled"
        static let actionBindings = "gestureActionBindings.v2"
        static let customGestures = "customGestures.v2"
        // v3 将默认策略切换为稳定的原生菜单；旧版延后菜单仍可由用户手动重新启用。
        static let contextMenuBehavior = "contextMenuBehavior.v3"
        static let templateThreshold = "templateThreshold.v2"
    }

    var textFilePath: String {
        get {
            defaults.string(forKey: Key.textFilePath)
                ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/MacroMouse.txt")
        }
        set { defaults.set(newValue, forKey: Key.textFilePath) }
    }

    var minimumDistance: CGFloat {
        get {
            let value = defaults.double(forKey: Key.minimumDist)
            guard value.isFinite, value > 0 else { return 40 }
            return CGFloat(min(max(value, 12), 500))
        }
        set {
            let safeValue = newValue.isFinite ? min(max(newValue, 12), 500) : 40
            defaults.set(Double(safeValue), forKey: Key.minimumDist)
        }
    }

    var gestureEnabled: Bool {
        get {
            if defaults.object(forKey: Key.gestureEnabled) == nil { return true }
            return defaults.bool(forKey: Key.gestureEnabled)
        }
        set { defaults.set(newValue, forKey: Key.gestureEnabled) }
    }

    var contextMenuBehavior: ContextMenuBehavior {
        get {
            guard let raw = defaults.string(forKey: Key.contextMenuBehavior),
                  let behavior = ContextMenuBehavior(rawValue: raw)
            else { return .native }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Key.contextMenuBehavior) }
    }

    /// 自定义图案的最大平均点距离，默认值偏宽松，方便自然绘制。
    var templateThreshold: CGFloat {
        get {
            let value = defaults.double(forKey: Key.templateThreshold)
            guard value.isFinite, value > 0 else { return 0.42 }
            return CGFloat(min(max(value, 0.15), 1.0))
        }
        set {
            let safeValue = newValue.isFinite ? min(max(newValue, 0.15), 1.0) : 0.42
            defaults.set(Double(safeValue), forKey: Key.templateThreshold)
        }
    }

    private var actionBindings: [String: GestureAction] {
        get {
            guard let data = defaults.data(forKey: Key.actionBindings),
                  let decoded = try? JSONDecoder().decode([String: GestureAction].self, from: data)
            else { return StandardGesture.defaultActions }

            // 新增触发器时自动注入默认动作，既不覆盖用户选择，也避免 nil 绑定。
            return StandardGesture.defaultActions.merging(decoded) { _, saved in saved }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.actionBindings)
        }
    }

    func action(for gesture: StandardGesture) -> GestureAction {
        actionBindings[gesture.rawValue] ?? .disabled
    }

    func setAction(_ action: GestureAction, for gesture: StandardGesture) {
        var bindings = actionBindings
        bindings[gesture.rawValue] = action
        actionBindings = bindings
    }

    /// 仅支持已通过实机探测验证的 2–5 号扩展鼠标按钮。
    func action(forAuxiliaryButtonNumber number: Int) -> GestureAction {
        guard let gesture = StandardGesture.allCases.first(where: { $0.auxiliaryButtonNumber == number }) else {
            return .disabled
        }
        return action(for: gesture)
    }

    var hasEnabledAuxiliaryButtonBinding: Bool {
        StandardGesture.allCases
            .filter { $0.auxiliaryButtonNumber != nil }
            .contains { action(for: $0).kind != .none }
    }

    var customGestures: [CustomGesture] {
        get {
            guard let data = defaults.data(forKey: Key.customGestures),
                  let decoded = try? JSONDecoder().decode([CustomGesture].self, from: data)
            else { return [] }
            return Array(decoded.compactMap(sanitizedCustomGesture).prefix(Self.maximumCustomGestures))
        }
        set {
            let safeGestures = Array(newValue.compactMap(sanitizedCustomGesture).prefix(Self.maximumCustomGestures))
            guard let data = try? JSONEncoder().encode(safeGestures) else { return }
            defaults.set(data, forKey: Key.customGestures)
        }
    }

    /// 防御性清理持久化数据：模板必须是有限数值、固定采样点数且拥有可读名称。
    private func sanitizedCustomGesture(_ gesture: CustomGesture) -> CustomGesture? {
        guard gesture.points.count == GestureTemplateRecognizer.sampleCount,
              gesture.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }
        let name = String(gesture.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumGestureNameLength))
        guard !name.isEmpty else { return nil }
        var safeGesture = gesture
        safeGesture.name = name
        return safeGesture
    }

    @discardableResult
    func addCustomGesture(_ gesture: CustomGesture) -> Bool {
        var gestures = customGestures
        guard gestures.count < Self.maximumCustomGestures,
              let safeGesture = sanitizedCustomGesture(gesture)
        else { return false }
        gestures.append(safeGesture)
        customGestures = gestures
        return true
    }

    func updateCustomGesture(_ gesture: CustomGesture) {
        var gestures = customGestures
        guard let index = gestures.firstIndex(where: { $0.id == gesture.id }) else { return }
        gestures[index] = gesture
        customGestures = gestures
    }

    func removeCustomGesture(id: UUID) {
        customGestures.removeAll { $0.id == id }
    }
}
