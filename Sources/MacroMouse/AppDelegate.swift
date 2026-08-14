import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let gestureManager = GestureManager.shared
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        gestureManager.startMonitoring()
        setupMenuBar()
        print(gestureManager.isMonitoring ? "✅ MacroMouse 已启动，鼠标监听已建立" : "⚠️ MacroMouse 无法建立鼠标监听；请检查系统隐私与安全中的设备控制或输入监控权限")
    }

    func applicationWillTerminate(_ notification: Notification) {
        gestureManager.stopMonitoring()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "MacroMouse")
            button.toolTip = "MacroMouse - 鼠标手势"
        }

        let menu = NSMenu()
        let stateTitle = gestureManager.isMonitoring ? "MacroMouse 运行中 ✓" : "MacroMouse 鼠标监听未建立 ⚠"
        menu.addItem(NSMenuItem(title: stateTitle, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "检查权限与重新检测…", action: #selector(checkPermissionsAndRetry), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "偏好设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "在访达中打开默认文本文件", action: #selector(openTextFile), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        for item in menu.items where item.action == #selector(openSettings) || item.action == #selector(openTextFile) || item.action == #selector(checkPermissionsAndRetry) {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func checkPermissionsAndRetry() {
        // 不依赖“辅助功能”或“设备控制和数据访问”等随系统变化的入口名称，
        // 而是分别展示实际可用的监听与 AX 控制能力。
        let accessibilityTrusted = AXIsProcessTrusted()
        gestureManager.stopMonitoring()
        gestureManager.startMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let monitoring = self.gestureManager.isMonitoring
            let alert = NSAlert()
            alert.messageText = monitoring ? "MacroMouse 权限检查完成" : "MacroMouse 仍无法建立鼠标监听"
            alert.informativeText = "鼠标监听：\(monitoring ? "已建立" : "未建立")\n窗口控制（设备控制 / 辅助功能）：\(accessibilityTrusted ? "可用" : "未授权或系统尚未生效")\n\n请在“系统设置 → 隐私与安全”中允许 MacroMouse 使用与设备控制、辅助功能或输入监控相关的权限。不同 macOS 版本的入口名称可能不同；无需删除应用记录，授权后返回此处再次点击“检查权限与重新检测”。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            self.setupMenuBar()
        }
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        // 重新打开设置即视为退出上一轮录制，避免隐藏窗口留下无法取消的会话。
        settingsWindowController?.cancelCustomGestureRecordingIfNeeded()
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openTextFile() {
        let path = Config.shared.textFilePath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            let alert = NSAlert()
            alert.messageText = "文本文件不存在"
            alert.informativeText = "路径：\(path)\n\n请前往偏好设置修改路径，或点击“创建示例”。"
            alert.runModal()
        }
    }
}
