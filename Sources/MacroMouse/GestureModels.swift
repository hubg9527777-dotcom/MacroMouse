import Cocoa

/// 预置的手势触发器。八方向动作、右键短按住和右键双击都可以由用户重新绑定。
enum StandardGesture: String, Codable, CaseIterable, Identifiable {
    case up
    case down
    case left
    case right
    case upLeft
    case downLeft
    case upRight
    case downRight
    case rightShortHold
    case rightDoubleClick
    case middleButton
    case browserBackButton
    case browserForwardButton
    case thumbButton

    var id: String { rawValue }

    /// 仅这四个经实机探测确认的编号允许成为扩展鼠标动作触发器。
    var auxiliaryButtonNumber: Int? {
        switch self {
        case .middleButton: return 2
        case .browserBackButton: return 3
        case .browserForwardButton: return 4
        case .thumbButton: return 5
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .up:               return "上"
        case .down:             return "下"
        case .left:             return "左"
        case .right:            return "右"
        case .upLeft:           return "左上"
        case .downLeft:         return "左下"
        case .upRight:          return "右上"
        case .downRight:        return "右下"
        case .rightShortHold:       return "右键短按住后松开"
        case .rightDoubleClick:     return "右键双击（仅菜单优先模式有效）"
        case .middleButton:         return "中键（鼠标按键 2）"
        case .browserBackButton:    return "网页后退键（鼠标按键 3）"
        case .browserForwardButton: return "网页前进键（鼠标按键 4）"
        case .thumbButton:          return "拇指按键（鼠标按键 5）"
        }
    }

    var symbol: String {
        switch self {
        case .up:               return "↑"
        case .down:             return "↓"
        case .left:             return "←"
        case .right:            return "→"
        case .upLeft:           return "↖"
        case .downLeft:         return "↙"
        case .upRight:          return "↗"
        case .downRight:        return "↘"
        case .rightShortHold:       return "⏱"
        case .rightDoubleClick:     return "⏺⏺"
        case .middleButton:         return "●"
        case .browserBackButton:    return "◀"
        case .browserForwardButton: return "▶"
        case .thumbButton:          return "●"
        }
    }
}

/// 右键菜单呈现策略。“手势优先”会在确认普通点击后补发系统右键事件。
enum ContextMenuBehavior: String, Codable, CaseIterable {
    case smartDelay
    case native

    var title: String {
        switch self {
        case .smartDelay: return "手势优先（松开后显示菜单）"
        case .native:     return "菜单优先（按下立即显示）"
        }
    }
}

/// 可由任何标准手势、右键短按住、右键双击或自定义图案绑定的动作。
enum GestureActionKind: String, Codable, CaseIterable {
    case none
    case copy
    case paste
    case cut
    case undo
    case redo
    case randomText
    case minimizeWindow
    case toggleFullScreen
    case confirm
    case keyboardShortcut

    var title: String {
        switch self {
        case .none:             return "不执行动作"
        case .copy:             return "复制（⌘C）"
        case .paste:            return "粘贴（⌘V）"
        case .cut:              return "剪切（⌘X）"
        case .undo:             return "撤销（⌘Z）"
        case .redo:             return "重做（⌘⇧Z）"
        case .randomText:       return "随机文本"
        case .minimizeWindow:   return "最小化窗口"
        case .toggleFullScreen: return "全屏切换 / 恢复"
        case .confirm:          return "确认（↩）"
        case .keyboardShortcut: return "自定义键盘组合键"
        }
    }
}

/// 用户录制的键盘组合键。仅存储硬件键码和修饰键，不存储按键文本。
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt64

    init(keyCode: UInt16, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifierFlags: UInt64(flags.intersection(.deviceIndependentFlagsMask).rawValue))
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }

    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option)  { result += "⌥" }
        if flags.contains(.shift)   { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + KeyboardShortcut.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "空格", 36: "↩", 48: "⇥", 51: "⌫",
            53: "⎋", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return names[keyCode] ?? "键码\(keyCode)"
    }
}

/// 动作配置。随机文本可选择全局默认文件，也可为每个绑定填写专用文件。
struct GestureAction: Codable, Equatable {
    var kind: GestureActionKind
    var shortcut: KeyboardShortcut?
    var randomTextPath: String?

    init(kind: GestureActionKind, shortcut: KeyboardShortcut? = nil, randomTextPath: String? = nil) {
        self.kind = kind
        self.shortcut = shortcut
        self.randomTextPath = randomTextPath
    }

    static var disabled: GestureAction { GestureAction(kind: .none) }

    var summary: String {
        switch kind {
        case .keyboardShortcut:
            return shortcut.map { "快捷键（\($0.displayString)）" } ?? "快捷键（未设置）"
        case .randomText:
            return randomTextPath?.isEmpty == false ? "随机文本（专用文件）" : "随机文本（默认文件）"
        default:
            return kind.title
        }
    }
}

/// 可序列化的归一化轨迹点。使用 Double 避免 CG 类型的 Codable 兼容问题。
struct GesturePoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// 已识别的常见图案类型。自由图案继续使用模板匹配；圆形使用形状特征匹配。
enum GestureShapeKind: String, Codable, CaseIterable {
    case circle

    var title: String {
        switch self {
        case .circle: return "圆形"
        }
    }
}

/// 用户录制的任意图案模板。
struct CustomGesture: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var points: [GesturePoint]
    /// 可选字段，保证升级后仍能读取旧版已保存的图案。
    var shapeKind: GestureShapeKind?
    var action: GestureAction
    var enabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(), name: String, points: [GesturePoint], shapeKind: GestureShapeKind? = nil, action: GestureAction, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.points = points
        self.shapeKind = shapeKind
        self.action = action
        self.enabled = enabled
        self.createdAt = createdAt
    }

    var shapeSummary: String { shapeKind?.title ?? "自由图案" }
}

extension StandardGesture {
    static var defaultActions: [String: GestureAction] {
        [
            StandardGesture.up.rawValue: GestureAction(kind: .copy),
            StandardGesture.down.rawValue: GestureAction(kind: .paste),
            StandardGesture.left.rawValue: GestureAction(kind: .undo),
            StandardGesture.right.rawValue: GestureAction(kind: .randomText),
            StandardGesture.upLeft.rawValue: GestureAction(kind: .undo),
            StandardGesture.downLeft.rawValue: GestureAction(kind: .minimizeWindow),
            StandardGesture.upRight.rawValue: GestureAction(kind: .toggleFullScreen),
            StandardGesture.downRight.rawValue: GestureAction(kind: .redo),
            // 仅在“手势优先”模式启用；快速普通右键仍会立即显示原生菜单。
            StandardGesture.rightShortHold.rawValue: GestureAction(kind: .confirm),
            // 速度优先：不再为等待双击而延后普通右键菜单，可按需手动启用兼容触发器。
            StandardGesture.rightDoubleClick.rawValue: GestureAction.disabled,
            // 扩展按键默认始终保持设备/系统原生行为；只有用户明确绑定动作后才启用拦截。
            StandardGesture.middleButton.rawValue: GestureAction.disabled,
            StandardGesture.browserBackButton.rawValue: GestureAction.disabled,
            StandardGesture.browserForwardButton.rawValue: GestureAction.disabled,
            StandardGesture.thumbButton.rawValue: GestureAction.disabled
        ]
    }
}
