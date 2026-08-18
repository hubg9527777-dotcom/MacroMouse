import Cocoa
import ApplicationServices

/// 通过公开的辅助功能 API 定位鼠标下的应用和窗口，并在事件送达前请求其成为焦点。
/// 任一环节失败时只返回 false，不阻断用户的原生右键操作。
final class WindowFocusController {
    static let shared = WindowFocusController()

    private let messagingTimeout: Float = 0.025
    private init() {}

    /// 成功时返回本次手势命中的进程 ID，供后续延迟动作重新确认目标应用。
    func focusWindow(at position: CGPoint) -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var element: AXUIElement?
        let hitTestResult = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(position.x),
            Float(position.y),
            &element
        )
        guard hitTestResult == .success, let hitElement = element else { return nil }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hitElement, &pid) == .success, pid != 0, pid != getpid() else {
            return nil
        }
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            return nil
        }

        // 已在前台的原生应用（例如 Teams、Slack、Electron / WebView 客户端）
        // 仍可能把光标放在内部文本编辑器中。重复设置 AXMain / AXFocusedWindow 会使
        // 这类客户端丢失编辑器焦点；此处只记录其 PID，保留原生输入焦点。
        guard !application.isActive, !isNestedInsideFrontmostApplication(application) else { return pid }

        let applicationElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeout)

        // 先请求激活应用，再将命中的窗口提升为 main/focused；不依赖私有 API。
        let activated = application.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        guard let window = nearestWindow(above: hitElement) else {
            return (activated || application.isActive) ? pid : nil
        }

        AXUIElementSetMessagingTimeout(window, messagingTimeout)
        let mainResult = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusedResult = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let appFocusedResult = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            window
        )

        return (application.isActive || mainResult == .success || focusedResult == .success || appFocusedResult == .success) ? pid : nil
    }

    /// 在动作真正投递前再次激活先前快照的应用，缩小延迟窗口中的误投递风险。
    @discardableResult
    func reactivateApplication(pid: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return false }
        guard !application.isActive, !isNestedInsideFrontmostApplication(application) else { return true }
        return application.activate(options: [.activateIgnoringOtherApps])
    }

    /// WebView / Electron 输入元素通常属于嵌套 helper 进程。若其宿主应用已在最前，
    /// 对 helper 的应用级激活会夺走宿主内部编辑器焦点，因而必须将其视为前台目标。
    private func isNestedInsideFrontmostApplication(_ application: NSRunningApplication) -> Bool {
        guard let childPath = application.bundleURL?.standardizedFileURL.path,
              let frontmostPath = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL.path,
              childPath != frontmostPath
        else { return false }
        return childPath.hasPrefix(frontmostPath + "/")
    }

    private func nearestWindow(above element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let candidate = current else { return nil }
            AXUIElementSetMessagingTimeout(candidate, messagingTimeout)

            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String,
               role == (kAXWindowRole as String) || role == (kAXSheetRole as String) || role == (kAXDrawerRole as String) {
                return candidate
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parent = parentValue,
                  CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return nil
    }
}
