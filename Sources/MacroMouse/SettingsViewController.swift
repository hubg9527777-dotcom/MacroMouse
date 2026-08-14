import Cocoa
import UniformTypeIdentifiers

/// 统一表格表头的左侧留白与文字垂直位置，使标题和各列内容使用同一条视觉基线。
private final class AlignedTableHeaderCell: NSTableHeaderCell {
    override func titleRect(forBounds theRect: NSRect) -> NSRect {
        var rect = super.titleRect(forBounds: theRect)
        rect.origin.x = theRect.minX + 8
        rect.size.width = max(theRect.width - 16, 1)
        rect.origin.y = floor(theRect.midY - rect.height / 2)
        return rect
    }
}

/// NSTableView 在首次创建单元格后才可能确定最终行高；在 layout 阶段再次居中，
/// 避免滚动、复用或系统缩放后轨迹预览贴近单元格上缘。
private final class VerticallyAlignedTableCellView: NSTableCellView {
    override func layout() {
        super.layout()
        guard bounds.height > 0 else { return }
        for subview in subviews where subview is NSTextField || subview is GesturePreviewView {
            var frame = subview.frame
            frame.origin.y = floor((bounds.height - frame.height) / 2)
            subview.frame = frame
        }
    }
}

/// 使用原始左键点击计数驱动编辑，避免 NSTableView 的 doubleAction 在部分 AppKit
/// 焦点组合下未分发的问题。事件在表格完成选中后异步交给控制器处理。
private final class DoubleClickTableView: NSTableView {
    var onRowDoubleClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let isDoubleClick = event.clickCount == 2
        super.mouseDown(with: event)
        guard isDoubleClick, clickedRow >= 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onRowDoubleClick?(clickedRow)
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init() {
        let controller = SettingsViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacroMouse 偏好设置"
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func cancelCustomGestureRecordingIfNeeded() {
        (contentViewController as? SettingsViewController)?.cancelAllTransientInputSessions()
    }

    private func cancelActiveActionEditorIfNeeded() {
        (contentViewController as? SettingsViewController)?.cancelActiveActionEditorIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        cancelCustomGestureRecordingIfNeeded()
        cancelActiveActionEditorIfNeeded()
    }
}

final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let enableToggle = NSButton(checkboxWithTitle: "启用鼠标手势", target: nil, action: nil)
    private let distSlider = NSSlider(value: 40, minValue: 20, maxValue: 180, target: nil, action: nil)
    private let distLabel = NSTextField(labelWithString: "40 px")
    private let menuBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pathField = NSTextField()

    private let standardTable = NSTableView()
    private let customTable = NSTableView()
    private let standardScroll = NSScrollView()
    private let customScroll = NSScrollView()
    private let recordCustomButton = NSButton()
    private let finishRecordingButton = NSButton()
    private let cancelRecordingButton = NSButton()
    private let recordingStateLabel = NSTextField(labelWithString: "")
    private var listDoubleClickMonitor: Any?
    /// 同一时刻仅允许一个非阻塞编辑窗口，避免连续双击创建重叠窗口。
    private var activeActionEditor: ActionEditorWindowController?
    private let standardGestures = StandardGesture.allCases

    private var customGestures: [CustomGesture] { Config.shared.customGestures }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 720))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGeneralSettings()
        setupStandardGestureSection()
        setupCustomGestureSection()
        installListDoubleClickMonitor()
        loadSettings()
    }

    private func setupGeneralSettings() {
        let title = NSTextField(labelWithString: "MacroMouse 手势与动作")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 20, y: 680, width: 400, height: 26)
        view.addSubview(title)

        let description = NSTextField(wrappingLabelWithString: "标准手势、右键短按住和自定义图案都可绑定为内置动作、随机文本或任意键盘组合键。")
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: 20, y: 652, width: 760, height: 20)
        view.addSubview(description)

        enableToggle.frame = NSRect(x: 20, y: 617, width: 150, height: 24)
        enableToggle.target = self
        enableToggle.action = #selector(toggleChanged)
        view.addSubview(enableToggle)

        let distanceTitle = NSTextField(labelWithString: "最小手势距离")
        distanceTitle.frame = NSRect(x: 195, y: 618, width: 90, height: 20)
        view.addSubview(distanceTitle)
        distSlider.frame = NSRect(x: 290, y: 617, width: 190, height: 20)
        distSlider.target = self
        distSlider.action = #selector(sliderChanged)
        view.addSubview(distSlider)
        distLabel.frame = NSRect(x: 490, y: 618, width: 55, height: 20)
        view.addSubview(distLabel)

        let menuTitle = NSTextField(labelWithString: "右键菜单")
        menuTitle.frame = NSRect(x: 565, y: 618, width: 60, height: 20)
        view.addSubview(menuTitle)
        menuBehaviorPopup.frame = NSRect(x: 627, y: 614, width: 170, height: 26)
        ContextMenuBehavior.allCases.forEach { menuBehaviorPopup.addItem(withTitle: $0.title) }
        menuBehaviorPopup.target = self
        menuBehaviorPopup.action = #selector(menuBehaviorChanged)
        view.addSubview(menuBehaviorPopup)

        let pathTitle = NSTextField(labelWithString: "默认随机文本文件")
        pathTitle.frame = NSRect(x: 20, y: 580, width: 110, height: 20)
        view.addSubview(pathTitle)
        pathField.frame = NSRect(x: 135, y: 577, width: 465, height: 24)
        pathField.placeholderString = FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop/MacroMouse.txt"
        view.addSubview(pathField)

        let browse = NSButton(title: "选择…", target: self, action: #selector(browseDefaultTextFile))
        browse.frame = NSRect(x: 610, y: 575, width: 72, height: 28)
        view.addSubview(browse)
        let create = NSButton(title: "创建示例", target: self, action: #selector(createSample))
        create.frame = NSRect(x: 690, y: 575, width: 92, height: 28)
        view.addSubview(create)
    }

    private func setupStandardGestureSection() {
        let title = NSTextField(labelWithString: "标准手势、快速确认与扩展按键")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 540, width: 280, height: 22)
        view.addSubview(title)

        let explanation = NSTextField(labelWithString: "选择一项后点“编辑动作”即可改变默认绑定或录制组合键。")
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 305, y: 541, width: 470, height: 20)
        view.addSubview(explanation)

        // 参照窗口默认可视宽度：触发器列加宽，确保“右键双击（仅菜单优先模式有效）”完整显示。
        configure(table: standardTable, columns: [("gesture", "手势", 270), ("action", "当前动作", 490)])
        standardScroll.documentView = standardTable
        standardScroll.hasVerticalScroller = true
        standardScroll.borderType = .bezelBorder
        standardScroll.frame = NSRect(x: 20, y: 326, width: 780, height: 208)
        view.addSubview(standardScroll)

        let edit = NSButton(title: "编辑动作…", target: self, action: #selector(editSelectedStandard))
        edit.frame = NSRect(x: 20, y: 292, width: 105, height: 28)
        view.addSubview(edit)
        let restore = NSButton(title: "恢复推荐默认值", target: self, action: #selector(restoreStandardDefaults))
        restore.frame = NSRect(x: 133, y: 292, width: 125, height: 28)
        view.addSubview(restore)

        let hint = NSTextField(wrappingLabelWithString: "默认：↑复制、↓粘贴、←撤销、→随机文本、↖撤销、↙最小化、↗全屏/恢复、↘重做。扩展按键 2–5 默认透传，绑定后覆盖原功能。")
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 275, y: 290, width: 520, height: 32)
        view.addSubview(hint)
    }

    private func setupCustomGestureSection() {
        let title = NSTextField(labelWithString: "自定义图案")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 258, width: 120, height: 22)
        view.addSubview(title)

        let explanation = NSTextField(labelWithString: "录制任意轨迹；识别时忽略起点、大小和速度，保留绘制方向与形状。")
        explanation.textColor = .secondaryLabelColor
        explanation.frame = NSRect(x: 145, y: 259, width: 520, height: 20)
        view.addSubview(explanation)

        // 保持图案名称、动作与状态三列的位置和宽度不变；仅压缩行高与预览本身。
        configure(table: customTable, columns: [("preview", "轨迹", 92), ("name", "图案名称", 208), ("action", "动作", 340), ("enabled", "状态", 100)])
        customScroll.documentView = customTable
        customScroll.hasVerticalScroller = true
        customScroll.borderType = .bezelBorder
        customScroll.frame = NSRect(x: 20, y: 147, width: 780, height: 96)
        view.addSubview(customScroll)

        recordCustomButton.title = "录制图案…"
        recordCustomButton.target = self
        recordCustomButton.action = #selector(recordCustomGesture)
        recordCustomButton.frame = NSRect(x: 20, y: 112, width: 98, height: 28)
        view.addSubview(recordCustomButton)

        finishRecordingButton.title = "完成录制"
        finishRecordingButton.target = self
        finishRecordingButton.action = #selector(finishCurrentGestureRecording)
        finishRecordingButton.frame = NSRect(x: 126, y: 112, width: 82, height: 28)
        finishRecordingButton.isHidden = true
        view.addSubview(finishRecordingButton)

        cancelRecordingButton.title = "取消录制"
        cancelRecordingButton.target = self
        cancelRecordingButton.action = #selector(cancelCustomGestureRecording)
        cancelRecordingButton.frame = NSRect(x: 216, y: 112, width: 82, height: 28)
        cancelRecordingButton.isHidden = true
        view.addSubview(cancelRecordingButton)

        recordingStateLabel.textColor = .systemOrange
        recordingStateLabel.frame = NSRect(x: 306, y: 116, width: 180, height: 20)
        recordingStateLabel.isHidden = true
        view.addSubview(recordingStateLabel)

        let edit = NSButton(title: "编辑…", target: self, action: #selector(editSelectedCustom))
        edit.frame = NSRect(x: 494, y: 112, width: 72, height: 28)
        view.addSubview(edit)
        let enable = NSButton(title: "启用 / 停用", target: self, action: #selector(toggleSelectedCustom))
        enable.frame = NSRect(x: 574, y: 112, width: 100, height: 28)
        view.addSubview(enable)
        let remove = NSButton(title: "删除", target: self, action: #selector(deleteSelectedCustom))
        remove.frame = NSRect(x: 682, y: 112, width: 70, height: 28)
        view.addSubview(remove)

        let version = NSTextField(labelWithString: "所有设置会即时保存。默认“菜单优先”按下即显示原生菜单；“手势优先”支持右键短按住后松开。")
        version.font = .systemFont(ofSize: 10)
        version.textColor = .tertiaryLabelColor
        version.frame = NSRect(x: 20, y: 86, width: 760, height: 16)
        view.addSubview(version)
    }

    /// 使用设置窗口的本地左键事件流识别双击；即使表格、行视图或嵌入预览控件先消费事件，
    /// 也会与“编辑动作…” / “编辑…”按钮共用同一条编辑调用链。
    private func installListDoubleClickMonitor() {
        listDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.clickCount == 2, event.window === self.view.window else { return event }
            let location = event.locationInWindow
            if self.scheduleEditorIfDoubleClicked(table: self.standardTable, locationInWindow: location) {
                return event
            }
            _ = self.scheduleEditorIfDoubleClicked(table: self.customTable, locationInWindow: location)
            return event
        }
    }

    private func scheduleEditorIfDoubleClicked(table: NSTableView, locationInWindow: NSPoint) -> Bool {
        let tablePoint = table.convert(locationInWindow, from: nil)
        let row = table.row(at: tablePoint)
        guard row >= 0 else { return false }
        DispatchQueue.main.async { [weak self, weak table] in
            guard let self, let table else { return }
            self.openEditor(for: table, row: row)
        }
        return true
    }

    deinit {
        if let listDoubleClickMonitor {
            NSEvent.removeMonitor(listDoubleClickMonitor)
        }
    }

    private func configure(table: NSTableView, columns: [(String, String, CGFloat)]) {
        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.rowHeight = table === customTable ? 28 : 22
        table.usesAlternatingRowBackgroundColors = true
        columns.forEach { identifier, title, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.headerCell = AlignedTableHeaderCell(textCell: title)
            column.width = width
            column.minWidth = width
            table.addTableColumn(column)
        }
    }

    private func loadSettings() {
        pathField.stringValue = Config.shared.textFilePath
        distSlider.doubleValue = Double(Config.shared.minimumDistance)
        enableToggle.state = Config.shared.gestureEnabled ? .on : .off
        menuBehaviorPopup.selectItem(at: Config.shared.contextMenuBehavior == .smartDelay ? 0 : 1)
        updateDistanceLabel()
        reloadTables()
    }

    private func reloadTables() {
        standardTable.reloadData()
        customTable.reloadData()
    }

    /// 宿主设置窗口关闭时取消独立编辑窗口，保证 GestureManager 的输入隔离一定结束。
    func cancelActiveActionEditorIfNeeded() {
        activeActionEditor?.cancelFromParent()
        activeActionEditor = nil
    }

    @objc private func toggleChanged() {
        Config.shared.gestureEnabled = enableToggle.state == .on
    }

    @objc private func sliderChanged() {
        Config.shared.minimumDistance = CGFloat(distSlider.doubleValue)
        updateDistanceLabel()
    }

    @objc private func menuBehaviorChanged() {
        Config.shared.contextMenuBehavior = menuBehaviorPopup.indexOfSelectedItem == 0 ? .smartDelay : .native
        GestureManager.shared.refreshContextMenuMode()
    }

    private func updateDistanceLabel() {
        distLabel.stringValue = "\(Int(distSlider.doubleValue)) px"
    }

    @objc private func browseDefaultTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            pathField.stringValue = url.path
            Config.shared.textFilePath = url.path
        }
    }

    @objc private func createSample() {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            showAlert(title: "路径不能为空", message: "请先输入或选择默认随机文本文件路径。")
            return
        }
        if FileManager.default.fileExists(atPath: path) {
            let alert = NSAlert()
            alert.messageText = "文件已存在"
            alert.informativeText = "创建示例会覆盖该文件，旧文件将备份为 .bak。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "覆盖")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            do {
                let backup = path + ".bak"
                if FileManager.default.fileExists(atPath: backup) {
                    try FileManager.default.removeItem(atPath: backup)
                }
                try FileManager.default.copyItem(atPath: path, toPath: backup)
            } catch {
                showAlert(title: "备份失败", message: error.localizedDescription)
                return
            }
        }
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try ["# 以 # 开头的行不会参与随机抽取", "示例文本 1", "示例文本 2", "示例文本 3"].joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            Config.shared.textFilePath = path
            showAlert(title: "示例文件已创建", message: path)
        } catch {
            showAlert(title: "创建失败", message: error.localizedDescription)
        }
    }

    private func openEditor(for tableView: NSTableView?, row: Int) {
        guard let tableView, row >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if tableView === standardTable {
            editSelectedStandard()
        } else if tableView === customTable {
            editSelectedCustom()
        }
    }

    @objc private func editSelectedStandard() {
        let row = standardTable.selectedRow
        guard standardGestures.indices.contains(row) else {
            showAlert(title: "请先选择触发器", message: "请在“标准手势、快速确认与扩展按键”列表中选择一项。")
            return
        }
        guard activeActionEditor == nil else {
            activeActionEditor?.showAgain()
            return
        }
        cancelAllTransientInputSessions()
        let gesture = standardGestures[row]
        let editor = ActionEditorWindowController(title: "编辑：\(gesture.symbol) \(gesture.title)", name: nil, action: Config.shared.action(for: gesture))
        activeActionEditor = editor
        editor.present(attachedTo: view.window) { [weak self] result in
            guard let self else { return }
            self.activeActionEditor = nil
            guard let result else { return }
            Config.shared.setAction(result.action, for: gesture)
            GestureManager.shared.refreshAuxiliaryButtonBindings()
            self.reloadTables()
        }
    }

    @objc private func restoreStandardDefaults() {
        let alert = NSAlert()
        alert.messageText = "恢复推荐默认值？"
        alert.informativeText = "这会恢复八方向和右键短按住的推荐动作，并将扩展按键 2–5 恢复为原生透传；不会影响自定义图案、随机文本文件或菜单模式。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "恢复")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        StandardGesture.allCases.forEach { gesture in
            Config.shared.setAction(StandardGesture.defaultActions[gesture.rawValue] ?? .disabled, for: gesture)
        }
        GestureManager.shared.refreshAuxiliaryButtonBindings()
        reloadTables()
    }

    @objc private func recordCustomGesture() {
        let alert = NSAlert()
        alert.messageText = "录制自定义图案"
        alert.informativeText = "点击“开始录制”后，请在任意位置按住右键画出图案并松开。若个别应用未上报抬键，可返回此窗口点击“完成录制”。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "开始录制")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let didStart = GestureManager.shared.beginCustomGestureRecording(completion: { [weak self] points in
            self?.finishCustomGestureRecording(points)
        })
        guard didStart else {
            showAlert(title: "无法开始录制", message: "全局鼠标监听未启动。请确认 MacroMouse 已在“系统设置 → 隐私与安全性 → 设备控制和数据访问”中获授权，然后退出并重新打开应用。")
            return
        }
        setRecordingUI(active: true)
    }

    @objc private func finishCurrentGestureRecording() {
        guard GestureManager.shared.finishCustomGestureRecording() else {
            showAlert(title: "尚未采集到足够轨迹", message: "请按住右键移动至少一小段距离后再松开；若仍未自动结束，再点击“完成录制”。")
            return
        }
        setRecordingUI(active: false)
    }

    @objc private func cancelCustomGestureRecording() {
        GestureManager.shared.cancelCustomGestureRecording()
        setRecordingUI(active: false)
    }

    func cancelCustomGestureRecordingIfNeeded() {
        guard GestureManager.shared.isCustomGestureRecording else { return }
        cancelCustomGestureRecording()
    }

    func cancelAllTransientInputSessions() {
        cancelCustomGestureRecordingIfNeeded()
    }

    private func setRecordingUI(active: Bool) {
        recordCustomButton.isHidden = active
        finishRecordingButton.isHidden = !active
        cancelRecordingButton.isHidden = !active
        recordingStateLabel.stringValue = active ? "正在录制：右键松开自动完成" : ""
        recordingStateLabel.isHidden = !active
    }

    private func finishCustomGestureRecording(_ points: [CGPoint]) {
        setRecordingUI(active: false)
        guard let window = view.window else { return }
        let normalized = GestureTemplateRecognizer.normalizedPoints(from: points)
        guard normalized.count == GestureTemplateRecognizer.sampleCount else {
            window.makeKeyAndOrderFront(nil)
            showAlert(title: "图案过短", message: "请画出更长、更清晰的轨迹后再试。")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let defaultName = "自定义图案 \(customGestures.count + 1)"
        guard activeActionEditor == nil else {
            activeActionEditor?.showAgain()
            return
        }
        let editor = ActionEditorWindowController(
            title: "保存自定义图案",
            name: defaultName,
            action: .disabled,
            previewPoints: normalized,
            shapeKind: GestureTemplateRecognizer.detectedShape(for: normalized)
        )
        activeActionEditor = editor
        editor.present(attachedTo: window) { [weak self] result in
            guard let self,
                  let result,
                  let name = result.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { self?.activeActionEditor = nil; return }
            self.activeActionEditor = nil
            let detectedShape = GestureTemplateRecognizer.detectedShape(for: normalized)
            let newGesture = CustomGesture(name: name, points: normalized, shapeKind: detectedShape, action: result.action)
            if let conflict = self.closestCustomGesture(to: newGesture.points), conflict.distance <= Config.shared.templateThreshold * 0.75 {
                let alert = NSAlert()
                alert.messageText = "图案与“\(conflict.gesture.name)”非常相似"
                alert.informativeText = "相似图案可能造成误触。仍然保存吗？"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "仍然保存")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            guard Config.shared.addCustomGesture(newGesture) else {
                self.showAlert(
                    title: "无法保存图案",
                    message: "自定义图案最多可保存 \(Config.maximumCustomGestures) 个。请删除不再使用的图案后重试。"
                )
                return
            }
            self.reloadTables()
        }
    }

    @objc private func editSelectedCustom() {
        let row = customTable.selectedRow
        guard customGestures.indices.contains(row) else {
            showAlert(title: "请先选择图案", message: "请在“自定义图案”列表中选择一项。")
            return
        }
        guard activeActionEditor == nil else {
            activeActionEditor?.showAgain()
            return
        }
        cancelAllTransientInputSessions()
        let gesture = customGestures[row]
        let editor = ActionEditorWindowController(
            title: "编辑自定义图案",
            name: gesture.name,
            action: gesture.action,
            previewPoints: gesture.points,
            shapeKind: gesture.shapeKind ?? GestureTemplateRecognizer.detectedShape(for: gesture.points)
        )
        activeActionEditor = editor
        editor.present(attachedTo: view.window) { [weak self] result in
            guard let self else { return }
            self.activeActionEditor = nil
            guard let result,
                  let name = result.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return }
            var updatedGesture = gesture
            updatedGesture.name = name
            updatedGesture.action = result.action
            Config.shared.updateCustomGesture(updatedGesture)
            self.reloadTables()
        }
    }

    @objc private func toggleSelectedCustom() {
        let row = customTable.selectedRow
        guard customGestures.indices.contains(row) else { return }
        var gesture = customGestures[row]
        gesture.enabled.toggle()
        Config.shared.updateCustomGesture(gesture)
        reloadTables()
    }

    @objc private func deleteSelectedCustom() {
        let row = customTable.selectedRow
        guard customGestures.indices.contains(row) else { return }
        let gesture = customGestures[row]
        let alert = NSAlert()
        alert.messageText = "删除“\(gesture.name)”？"
        alert.informativeText = "该操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Config.shared.removeCustomGesture(id: gesture.id)
        reloadTables()
    }

    private func closestCustomGesture(to points: [GesturePoint]) -> (gesture: CustomGesture, distance: CGFloat)? {
        customGestures.compactMap { gesture -> (CustomGesture, CGFloat)? in
            guard let distance = GestureTemplateRecognizer.distance(points, gesture.points) else { return nil }
            return (gesture, distance)
        }.min { $0.1 < $1.1 }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === standardTable ? standardGestures.count : customGestures.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cellIdentifier = NSUserInterfaceItemIdentifier("Cell.\(identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? VerticallyAlignedTableCellView ?? VerticallyAlignedTableCellView()
        cell.identifier = cellIdentifier

        if tableView === customTable, identifier.rawValue == "preview" {
            let gesture = customGestures[row]
            let preview: GesturePreviewView
            if let existing = cell.subviews.compactMap({ $0 as? GesturePreviewView }).first {
                preview = existing
            } else {
                // 28 pt 紧凑行高内： (28 - 20) / 2 = 4。布局阶段会按最终行高再次精确居中。
                preview = GesturePreviewView(frame: NSRect(x: 8, y: 4, width: 76, height: 20))
                preview.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
                cell.addSubview(preview)
            }
            // 立即设置与 layout 双重保障，确保复用单元格和首次布局均保持上下居中。
            preview.frame = NSRect(x: 8, y: max(floor((cell.bounds.height - 20) / 2), 0), width: 76, height: 20)
            preview.points = gesture.points
            return cell
        }

        let text: String
        if tableView === standardTable {
            let gesture = standardGestures[row]
            text = identifier.rawValue == "gesture" ? "\(gesture.symbol)  \(gesture.title)" : Config.shared.action(for: gesture).summary
        } else {
            let gesture = customGestures[row]
            switch identifier.rawValue {
            case "name": text = "\(gesture.name)  ·  \(gesture.shapeSummary)"
            case "action": text = gesture.action.summary
            default: text = gesture.enabled ? "已启用" : "已停用"
            }
        }

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            // 表头和内容统一使用 8 pt 左边距；布局阶段按实际行高锁定文字视觉中心。
            label.frame = NSRect(x: 8, y: tableView === customTable ? 5 : 2, width: tableColumn.width - 16, height: 18)
            label.autoresizingMask = [.width]
            cell.textField = label
            cell.addSubview(label)
        }
        if tableView === customTable {
            // 文字随当前单元格高度居中，和预览的视觉中心对齐。
            label.frame.origin.y = max(floor((cell.bounds.height - label.frame.height) / 2), 0)
        }
        label.stringValue = text
        label.textColor = (tableView === customTable && identifier.rawValue == "enabled" && customGestures[row].enabled == false) ? .secondaryLabelColor : .labelColor
        return cell
    }
}

// MARK: - 动作编辑器

private final class ActionEditorWindowController: NSWindowController, NSWindowDelegate {
    private let nameField = NSTextField()
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcutCaptureControl = ShortcutCaptureControl()
    private let randomPathField = NSTextField()
    private var capturedShortcut: KeyboardShortcut?
    private let editableName: Bool

    private var result: (name: String?, action: GestureAction)?
    private weak var parentWindow: NSWindow?
    private var completion: (((name: String?, action: GestureAction)?) -> Void)?
    private var didFinish = false

    init(title: String, name: String?, action: GestureAction, previewPoints: [GesturePoint]? = nil, shapeKind: GestureShapeKind? = nil) {
        editableName = name != nil
        capturedShortcut = action.shortcut
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: name == nil ? 280 : 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        buildView(action: action, name: name, previewPoints: previewPoints, shapeKind: shapeKind)
    }

    required init?(coder: NSCoder) { nil }

    /// 非阻塞显示编辑器。设置窗口不会进入嵌套 runModal，因此不会再被隐藏编辑窗口锁死。
    func present(attachedTo parentWindow: NSWindow?, completion: @escaping (((name: String?, action: GestureAction)?) -> Void)) {
        guard let window else {
            completion(nil)
            return
        }
        self.parentWindow = parentWindow
        self.completion = completion
        didFinish = false
        GestureManager.shared.beginModalEditing()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        // orderFrontRegardless 保证设置类后台应用的编辑器也会到当前空间并可见。
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func showAgain() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// 设置窗口关闭或控制器释放时的兜底清理，避免残留全局输入隔离状态。
    func cancelFromParent() {
        result = nil
        finishEditing()
    }

    func windowWillClose(_ notification: Notification) {
        result = nil
        finishEditing()
    }

    private func buildView(action: GestureAction, name: String?, previewPoints: [GesturePoint]?, shapeKind: GestureShapeKind?) {
        guard let window else { return }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content
        let yOffset: CGFloat = editableName ? 0 : 40

        if editableName {
            let nameTitle = NSTextField(labelWithString: "图案名称")
            nameTitle.frame = NSRect(x: 20, y: 270, width: 90, height: 20)
            content.addSubview(nameTitle)
            nameField.frame = NSRect(x: 115, y: 266, width: 260, height: 24)
            nameField.stringValue = name ?? ""
            content.addSubview(nameField)
        }

        if let previewPoints {
            let previewTitle = NSTextField(labelWithString: shapeKind.map { "录制轨迹（\($0.title)）" } ?? "录制轨迹")
            previewTitle.font = .systemFont(ofSize: 10)
            previewTitle.textColor = .secondaryLabelColor
            previewTitle.frame = NSRect(x: 390, y: 245, width: 110, height: 16)
            content.addSubview(previewTitle)

            let preview = GesturePreviewView(frame: NSRect(x: 390, y: 198, width: 110, height: 43))
            preview.points = previewPoints
            preview.showsBadge = false
            content.addSubview(preview)
        }

        let actionTitle = NSTextField(labelWithString: "执行动作")
        actionTitle.frame = NSRect(x: 20, y: 220 - yOffset, width: 90, height: 20)
        content.addSubview(actionTitle)
        actionPopup.frame = NSRect(x: 115, y: 216 - yOffset, width: 260, height: 26)
        GestureActionKind.allCases.forEach { actionPopup.addItem(withTitle: $0.title) }
        actionPopup.selectItem(at: GestureActionKind.allCases.firstIndex(of: action.kind) ?? 0)
        actionPopup.target = self
        actionPopup.action = #selector(actionKindChanged)
        content.addSubview(actionPopup)

        let shortcutTitle = NSTextField(labelWithString: "组合键")
        shortcutTitle.frame = NSRect(x: 20, y: 172 - yOffset, width: 90, height: 20)
        content.addSubview(shortcutTitle)
        shortcutCaptureControl.frame = NSRect(x: 115, y: 166 - yOffset, width: 300, height: 30)
        shortcutCaptureControl.shortcut = capturedShortcut
        shortcutCaptureControl.onCapture = { [weak self] shortcut in
            self?.capturedShortcut = shortcut
            self?.updateEditorVisibility()
        }
        content.addSubview(shortcutCaptureControl)

        let pathTitle = NSTextField(labelWithString: "随机文本文件")
        pathTitle.frame = NSRect(x: 20, y: 122 - yOffset, width: 90, height: 20)
        content.addSubview(pathTitle)
        randomPathField.frame = NSRect(x: 115, y: 118 - yOffset, width: 300, height: 24)
        randomPathField.placeholderString = "留空则使用默认随机文本文件"
        randomPathField.stringValue = action.randomTextPath ?? ""
        content.addSubview(randomPathField)
        let choosePath = NSButton(title: "选择…", target: self, action: #selector(chooseRandomTextFile))
        choosePath.frame = NSRect(x: 423, y: 116 - yOffset, width: 72, height: 28)
        choosePath.tag = 102
        content.addSubview(choosePath)

        let help = NSTextField(wrappingLabelWithString: "选择“自定义键盘组合键”后请录制快捷键。选择“随机文本”时可留空以使用全局默认文件。")
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 20, y: 59 - yOffset, width: 475, height: 38)
        content.addSubview(help)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.frame = NSRect(x: 330, y: 18, width: 76, height: 28)
        content.addSubview(cancel)
        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.frame = NSRect(x: 416, y: 18, width: 76, height: 28)
        save.keyEquivalent = "\r"
        content.addSubview(save)
        updateEditorVisibility()
    }

    @objc private func actionKindChanged() {
        updateEditorVisibility()
    }

    private func updateEditorVisibility() {
        let kind = selectedKind
        shortcutCaptureControl.shortcut = capturedShortcut
        shortcutCaptureControl.isHidden = kind != .keyboardShortcut
        randomPathField.isHidden = kind != .randomText
        window?.contentView?.viewWithTag(102)?.isHidden = kind != .randomText
    }

    @objc private func chooseRandomTextFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            randomPathField.stringValue = url.path
        }
    }

    @objc private func save() {
        let kind = selectedKind
        if kind == .keyboardShortcut && capturedShortcut == nil {
            let alert = NSAlert()
            alert.messageText = "请先录制组合键"
            alert.informativeText = "自定义键盘组合键动作必须包含一个主按键。"
            alert.runModal()
            return
        }
        let action = GestureAction(
            kind: kind,
            shortcut: kind == .keyboardShortcut ? capturedShortcut : nil,
            randomTextPath: kind == .randomText ? randomPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
        result = (editableName ? nameField.stringValue : nil, action)
        finishModal()
    }

    @objc private func cancel() {
        result = nil
        finishModal()
    }

    private func finishModal() {
        finishEditing()
    }

    private func finishEditing() {
        guard !didFinish else { return }
        didFinish = true
        GestureManager.shared.endModalEditing()
        window?.orderOut(nil)
        parentWindow?.makeKeyAndOrderFront(nil)
        let completion = self.completion
        self.completion = nil
        // 异步回调避免在当前按钮事件栈内释放编辑控制器。
        DispatchQueue.main.async { completion?(self.result) }
    }

    private var selectedKind: GestureActionKind {
        GestureActionKind.allCases[actionPopup.indexOfSelectedItem]
    }
}

private final class ShortcutCaptureControl: NSControl {
    var shortcut: KeyboardShortcut? { didSet { needsDisplay = true } }
    var onCapture: ((KeyboardShortcut) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func keyDown(with event: NSEvent) {
        // Esc 仅移除焦点，不清空已有组合键，避免误操作。
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let value = KeyboardShortcut(keyCode: event.keyCode, flags: modifiers)
        shortcut = value
        onCapture?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let focused = window?.firstResponder === self
        let fillColor = NSColor.controlBackgroundColor
        let strokeColor = focused ? NSColor.controlAccentColor : NSColor.separatorColor
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        strokeColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = focused ? 2 : 1
        border.stroke()

        let text = shortcut?.displayString ?? "点击此框后直接按下组合键"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: shortcut == nil ? NSColor.placeholderTextColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: 9, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
