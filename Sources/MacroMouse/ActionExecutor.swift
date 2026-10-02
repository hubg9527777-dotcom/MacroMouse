import Cocoa
import Carbon
import ApplicationServices

/// 所有手势动作的唯一执行入口。输入事件与窗口操作均建立在辅助功能权限之上。
enum ActionExecutor {
    // AXFullScreen 是公开的辅助功能属性名，但部分 Swift SDK 未导出对应常量。
    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    static func execute(_ action: GestureAction) {
        switch action.kind {
        case .none:
            return
        case .copy:
            postKeyboardShortcut(keyCode: kVK_ANSI_C, flags: .maskCommand)
        case .paste:
            postKeyboardShortcut(keyCode: kVK_ANSI_V, flags: .maskCommand)
        case .cut:
            postKeyboardShortcut(keyCode: kVK_ANSI_X, flags: .maskCommand)
        case .undo:
            postKeyboardShortcut(keyCode: kVK_ANSI_Z, flags: .maskCommand)
        case .redo:
            postKeyboardShortcut(keyCode: kVK_ANSI_Z, flags: [.maskCommand, .maskShift])
        case .randomText:
            let customPath = action.randomTextPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pasteRandomLine(from: customPath.isEmpty ? Config.shared.textFilePath : customPath)
        case .minimizeWindow:
            postKeyboardShortcut(keyCode: kVK_ANSI_M, flags: .maskCommand)
        case .toggleFullScreen:
            toggleFullScreen()
        case .confirm:
            postKeyboardShortcut(keyCode: kVK_Return, flags: [])
        case .keyboardShortcut:
            guard let shortcut = action.shortcut else {
                print("⚠️ 自定义快捷键尚未录制，已跳过")
                return
            }
            postKeyboardShortcut(keyCode: Int(shortcut.keyCode), flags: shortcut.flags)
        }
    }

    /// 文件 I/O 和文本解析在后台完成，主线程仅更新剪贴板并投递快捷键。
    private static func pasteRandomLine(from path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                if let size = attributes[.size] as? NSNumber, size.int64Value > 10 * 1024 * 1024 {
                    throw NSError(domain: "MacroMouse", code: 1, userInfo: [NSLocalizedDescriptionKey: "随机文本文件不能超过 10 MB"])
                }

                let content = try String(contentsOfFile: path, encoding: .utf8)
                // 避免一个异常超长单行占用大量剪贴板或令目标应用短暂失去响应。
                let maximumLineBytes = 64 * 1024
                let lines = content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") && $0.lengthOfBytes(using: .utf8) <= maximumLineBytes }
                guard let selectedLine = lines.randomElement() else {
                    throw NSError(domain: "MacroMouse", code: 2, userInfo: [NSLocalizedDescriptionKey: "文本文件中没有不超过 64 KB 的可用内容"])
                }

                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(selectedLine, forType: .string) else {
                        print("⚠️ 无法写入系统剪贴板")
                        return
                    }
                    postKeyboardShortcut(keyCode: kVK_ANSI_V, flags: .maskCommand)
                }
            } catch {
                // 文件错误的 localizedDescription 可能包含用户配置的完整路径。
                print("⚠️ 随机文本动作失败：无法读取或处理文本文件")
            }
        }
    }

    /// 使用公开的 AXFullScreen 属性；失败时不阻塞鼠标事件线程。
    private static func toggleFullScreen() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard AXIsProcessTrusted() else {
                print("⚠️ 未获得辅助功能权限，无法切换全屏")
                return
            }

            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.1)
            guard let application = copyAXElement(systemWide, attribute: kAXFocusedApplicationAttribute as CFString),
                  let window = copyAXElement(application, attribute: kAXFocusedWindowAttribute as CFString)
            else {
                print("⚠️ 未找到可切换全屏的窗口")
                return
            }
            AXUIElementSetMessagingTimeout(window, 0.1)

            var value: CFTypeRef?
            let readResult = AXUIElementCopyAttributeValue(window, axFullScreenAttribute, &value)
            guard readResult == .success, let currentValue = bool(from: value) else {
                print("⚠️ 当前窗口不支持全屏切换")
                return
            }
            let setResult = AXUIElementSetAttributeValue(
                window,
                axFullScreenAttribute,
                currentValue ? kCFBooleanFalse : kCFBooleanTrue
            )
            if setResult != .success {
                print("⚠️ 全屏切换失败：\(setResult.rawValue)")
            }
        }
    }

    static func postKeyboardShortcut(keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(UInt16(keyCode))
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        // 部分系统级快捷键（尤其是 Control + 方向键）要求收到完整的修饰键按下序列。
        // macOS 将方向键归入功能层键；合成方向键必须带 SecondaryFn，系统才会走与真实键盘一致的快捷键匹配路径。
        // 该补充仅发生在投递阶段，不会污染用户保存或界面显示的“⌃↑”配置。
        var effectiveFlags = flags
        if [kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow].contains(keyCode) {
            effectiveFlags.insert(.maskSecondaryFn)
        }
        let modifierKeys: [(flag: CGEventFlags, keyCode: CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)),
            (.maskAlternate, CGKeyCode(kVK_Option)),
            (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskCommand, CGKeyCode(kVK_Command)),
            (.maskSecondaryFn, CGKeyCode(kVK_Function)),
            (.maskAlphaShift, CGKeyCode(kVK_CapsLock))
        ]
        let requiredModifiers = modifierKeys.filter { effectiveFlags.contains($0.flag) }
        var activeFlags: CGEventFlags = []

        for modifier in requiredModifiers {
            activeFlags.insert(modifier.flag)
            guard let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: true) else { continue }
            modifierDown.flags = activeFlags
            modifierDown.post(tap: .cghidEventTap)
        }

        keyDown.flags = activeFlags
        keyUp.flags = activeFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        for modifier in requiredModifiers.reversed() {
            activeFlags.remove(modifier.flag)
            guard let modifierUp = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: false) else { continue }
            modifierUp.flags = activeFlags
            modifierUp.post(tap: .cghidEventTap)
        }
    }

    private static func copyAXElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func bool(from value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }
}
