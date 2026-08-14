import Cocoa

// 请求设备控制 / 辅助功能授权。系统设置入口名称会随 macOS 版本变化，
// 因此只根据实际 AX 信任状态处理，不用入口文案作为逻辑条件。
func requestAccessibilityPermission() {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    let trusted = AXIsProcessTrustedWithOptions(options)
    if !trusted {
        print("⚠️ MacroMouse 尚未获得窗口控制权限。请在“系统设置 → 隐私与安全”中允许设备控制、辅助功能或输入监控，然后在菜单栏选择“检查权限与重新检测”。")
    }
}

requestAccessibilityPermission()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // 不在 Dock 显示，只在菜单栏
app.run()
