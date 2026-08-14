import Cocoa
import Carbon

// MARK: - 核心手势管理器

/// 标准动作使用观察式全局事件流；“手势优先”模式仅额外拦截右键会话，
/// 在确认是普通点击后再补发原始右键事件，以避免按下时立即弹出菜单。
final class GestureManager {
    static let shared = GestureManager()
    private static let syntheticEventMarker: Int64 = 0x4D4D_4753 // "MMGS"

    private var mouseMonitor: Any?
    private var localRecordingMonitor: Any?

    private var menuEventTap: CFMachPort?
    private var menuEventTapSource: CFRunLoopSource?
    /// 扩展按键仅在用户明确启用某个 2–5 号按钮动作时建立独立拦截器。
    private var auxiliaryEventTap: CFMachPort?
    private var auxiliaryEventTapSource: CFRunLoopSource?
    /// 只有低层拦截器实际加入 RunLoop 后才让全局监听让出右键事件。
    private var isMenuDelayTapReady = false
    private var delayedMouseDown: CGEvent?
    private var delayedMouseDownTime: Date?
    private var delayedStartPoint: CGPoint?
    private var delayedPoints = [CGPoint]()
    private var delayedGestureDetected = false
    private var pendingReplay: PendingReplay?
    private var ignoreObservedEventsUntil = Date.distantPast

    private var isTracking = false
    private var startPoint: CGPoint?
    private var rawPoints = [CGPoint]()
    /// 当前右键会话的目标应用。聚焦查询在后台执行，不阻塞鼠标事件回调。
    private var focusedTargetPID: pid_t?
    private var focusRequestGeneration = 0
    private var recordingCompletion: (([CGPoint]) -> Void)?
    private var lastRightClick: (point: CGPoint, upTime: Date)?
    /// 编辑器显示期间禁止全局手势、扩展按键和延迟动作进入其他应用。
    private var modalEditingDepth = 0

    private let clickMoveTolerance: CGFloat = 8
    /// 右键按住超过此阈值、未移动且松开时执行“右键短按住后松开”动作。
    private let shortHoldMinimumDuration: TimeInterval = 0.28
    private let maximumRecordedPoints = 2_048
    private let actionDelay: TimeInterval = 0.08

    private struct PendingReplay {
        let id: UUID
        let point: CGPoint
        let date: Date
        let downEvent: CGEvent
        let upEvent: CGEvent
        let workItem: DispatchWorkItem
    }

    private init() {}

    var isMonitoring: Bool { mouseMonitor != nil }
    var isCustomGestureRecording: Bool { recordingCompletion != nil }
    private var isModalEditing: Bool { modalEditingDepth > 0 }

    /// 在模态动作编辑器显示期间隔离全局输入。该方法只清理临时状态，
    /// 不关闭监听器，也不改变任何已保存动作配置。
    func beginModalEditing() {
        modalEditingDepth += 1
        guard modalEditingDepth == 1 else { return }
        focusRequestGeneration &+= 1 // 使尚未完成的 AX 聚焦回调失效。
        focusedTargetPID = nil
        resetTracking()
        lastRightClick = nil
        delayedMouseDown = nil
        delayedMouseDownTime = nil
        delayedStartPoint = nil
        delayedPoints.removeAll(keepingCapacity: true)
        delayedGestureDetected = false
        pendingReplay?.workItem.cancel()
        pendingReplay = nil
    }

    func endModalEditing() {
        modalEditingDepth = max(0, modalEditingDepth - 1)
    }

    func startMonitoring() {
        guard mouseMonitor == nil else { return }
        // 右键拖动已覆盖按住绘制轨迹；不监听全局 mouseMoved，避免高刷新鼠标
        // 在未进行手势时向主线程持续投递事件。
        let mask: NSEvent.EventTypeMask = [
            .rightMouseDown, .rightMouseDragged, .rightMouseUp
        ]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // 全局事件没有可靠的所属窗口坐标；在回调瞬间保存统一的全局屏幕坐标。
            let type = event.type
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self, !self.isModalEditing, Date() >= self.ignoreObservedEventsUntil else { return }
                // 手势优先模式的原始右键只在低层拦截器已实际就绪时交给它处理。
                // 启动、权限恢复或创建失败的空窗期继续由稳定的观察式路径处理，
                // 避免“配置是手势优先但没有任何监听器接管事件”。
                let shouldUseObserver = self.recordingCompletion != nil
                    || Config.shared.contextMenuBehavior == .native
                    || !self.isMenuDelayTapReady
                guard shouldUseObserver else { return }
                self.handleMouseEvent(type: type, at: point)
            }
        }
        if mouseMonitor == nil {
            print("⚠️ 无法创建全局鼠标监听；请在系统设置中授予设备控制权限")
        }
        // 应用刚启动时先保留观察式路径，待主 RunLoop 稳定后再按已保存策略建立拦截器。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.refreshContextMenuMode()
            self?.refreshAuxiliaryButtonBindings()
        }
    }

    func stopMonitoring() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        stopMenuDelayTap()
        stopAuxiliaryButtonTap()
        cancelCustomGestureRecording()
    }

    /// 由设置切换调用；原生菜单模式不创建事件 tap，手势优先模式创建一个专用 tap。
    func refreshContextMenuMode() {
        lastRightClick = nil
        guard mouseMonitor != nil, Config.shared.contextMenuBehavior == .smartDelay else {
            stopMenuDelayTap()
            return
        }
        guard menuEventTap == nil else {
            isMenuDelayTapReady = true
            return
        }
        // 创建期间让全局观察器继续兜底，直到 RunLoop 来源已真正安装。
        isMenuDelayTapReady = false
        let events: CGEventMask = (CGEventMask(1) << CGEventMask(CGEventType.rightMouseDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.rightMouseDragged.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.rightMouseUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: GestureManager.menuEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ 无法启用手势优先菜单；已保留菜单优先行为")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        menuEventTap = tap
        menuEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMenuDelayTapReady = true
    }

    /// 根据用户当前绑定启用或释放扩展按键拦截。未绑定时绝不创建 tap，
    /// 因而中键、前进、后退、拇指键均维持 Logitech/系统原始行为。
    func refreshAuxiliaryButtonBindings() {
        guard mouseMonitor != nil, Config.shared.hasEnabledAuxiliaryButtonBinding else {
            stopAuxiliaryButtonTap()
            return
        }
        guard auxiliaryEventTap == nil else { return }

        let events: CGEventMask = (CGEventMask(1) << CGEventMask(CGEventType.otherMouseDown.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.otherMouseUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: GestureManager.auxiliaryEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ 无法启用扩展鼠标按键绑定；所有扩展按键已保持原生透传")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        auxiliaryEventTap = tap
        auxiliaryEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopAuxiliaryButtonTap() {
        if let source = auxiliaryEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = auxiliaryEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        auxiliaryEventTapSource = nil
        auxiliaryEventTap = nil
    }

    private func stopMenuDelayTap() {
        // 先恢复观察式路径，再撤销低层拦截，确保切换模式时没有事件无人处理。
        isMenuDelayTapReady = false
        flushPendingReplay()
        if let source = menuEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = menuEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        menuEventTapSource = nil
        menuEventTap = nil
        delayedMouseDown = nil
        delayedMouseDownTime = nil
        delayedStartPoint = nil
        delayedPoints.removeAll(keepingCapacity: true)
        delayedGestureDetected = false
    }

    /// 下一次右键按住轨迹将被保存为自定义图案。录制期间不抑制系统右键。
    @discardableResult
    func beginCustomGestureRecording(completion: @escaping ([CGPoint]) -> Void) -> Bool {
        guard isMonitoring else { return false }
        cancelCustomGestureRecording()
        recordingCompletion = completion
        let mask: NSEvent.EventTypeMask = [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .mouseMoved]
        localRecordingMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleMouseEvent(type: event.type, at: NSEvent.mouseLocation)
            return event
        }
        return true
    }

    @discardableResult
    func finishCustomGestureRecording() -> Bool {
        guard let completion = recordingCompletion, rawPoints.count >= 2 else { return false }
        finishRecording(with: completion)
        return true
    }

    func cancelCustomGestureRecording() {
        recordingCompletion = nil
        removeLocalRecordingMonitor()
        resetTracking()
    }

    private static let menuEventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<GestureManager>.fromOpaque(userInfo).takeUnretainedValue()
        return manager.handleMenuTap(proxy: proxy, type: type, event: event)
    }

    private static let auxiliaryEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<GestureManager>.fromOpaque(userInfo).takeUnretainedValue()
        return manager.handleAuxiliaryButtonTap(type: type, event: event)
    }

    private func handleAuxiliaryButtonTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.stopAuxiliaryButtonTap()
                self?.refreshAuxiliaryButtonBindings()
            }
            return Unmanaged.passUnretained(event)
        }
        guard !isModalEditing, Config.shared.gestureEnabled else { return Unmanaged.passUnretained(event) }
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let action = Config.shared.action(forAuxiliaryButtonNumber: buttonNumber)
        guard action.kind != .none else { return Unmanaged.passUnretained(event) }

        switch type {
        case .otherMouseDown:
            // 聚焦在后台执行，动作延迟投递；回调本身不做 AX 调用。
            requestWindowFocus(atQuartzPoint: event.location)
            dispatch(action)
            return nil
        case .otherMouseUp:
            // 已消费的按下必须连同抬起一起消费，避免目标应用收到不配对事件。
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMenuTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 先立即回退到观察式路径；稍后在主 RunLoop 上重建拦截器，避免短暂失效导致全部手势被跳过。
            isMenuDelayTapReady = false
            delayedMouseDown = nil
            delayedMouseDownTime = nil
            delayedStartPoint = nil
            delayedGestureDetected = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, Config.shared.contextMenuBehavior == .smartDelay else { return }
                self.stopMenuDelayTap()
                self.refreshContextMenuMode()
            }
            return Unmanaged.passUnretained(event)
        }
        guard !isModalEditing,
              Config.shared.gestureEnabled,
              Config.shared.contextMenuBehavior == .smartDelay,
              recordingCompletion == nil,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker
        else { return Unmanaged.passUnretained(event) }

        switch type {
        case .rightMouseDown:
            requestWindowFocus(atQuartzPoint: event.location)
            delayedMouseDown = event.copy()
            delayedMouseDownTime = Date()
            delayedStartPoint = event.location
            delayedPoints = [appKitScreenPoint(from: event.location)]
            delayedGestureDetected = false
            return nil

        case .rightMouseDragged:
            guard let start = delayedStartPoint else { return Unmanaged.passUnretained(event) }
            let point = event.location
            appendDelayedPoint(appKitScreenPoint(from: point))
            if max(abs(point.x - start.x), abs(point.y - start.y)) >= clickMoveTolerance {
                delayedGestureDetected = true
                // 先前等待双击判定的普通点击应立即恢复，其后的拖动手势继续消费。
                flushPendingReplay()
            }
            return nil

        case .rightMouseUp:
            guard let down = delayedMouseDown?.copy(), delayedStartPoint != nil,
                  let downTime = delayedMouseDownTime, let up = event.copy()
            else {
                return Unmanaged.passUnretained(event)
            }
            appendDelayedPoint(appKitScreenPoint(from: event.location), force: true)
            let points = delayedPoints
            let wasGesture = delayedGestureDetected
            let heldDuration = Date().timeIntervalSince(downTime)
            delayedMouseDown = nil
            delayedMouseDownTime = nil
            delayedStartPoint = nil
            delayedPoints.removeAll(keepingCapacity: true)
            delayedGestureDetected = false

            if wasGesture {
                executeGesture(points)
                return nil
            }
            // 速度优先：普通右键松开即补发菜单，绝不等待系统双击判定窗口。
            // 仅无移动、按住达到阈值时触发用户可配置的短按住动作。
            let shortHoldAction = Config.shared.action(for: .rightShortHold)
            if heldDuration >= shortHoldMinimumDuration, shortHoldAction.kind != .none {
                dispatch(shortHoldAction)
                return nil
            }
            replay(downEvent: down, upEvent: up, proxy: proxy)
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func queueReplayForPossibleDoubleClick(point: CGPoint, downEvent: CGEvent, upEvent: CGEvent, proxy: CGEventTapProxy) {
        let now = Date()
        if let pendingReplay {
            let withinTime = now.timeIntervalSince(pendingReplay.date) <= NSEvent.doubleClickInterval
            let nearby = max(abs(point.x - pendingReplay.point.x), abs(point.y - pendingReplay.point.y)) < clickMoveTolerance
            if withinTime && nearby {
                pendingReplay.workItem.cancel()
                self.pendingReplay = nil
                // 两次物理点击已由观察式监听识别并派发用户定义的双击动作；两次菜单均不显示。
                return
            }
            flushPendingReplay()
        }

        let id = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingReplay, pending.id == id else { return }
            self.pendingReplay = nil
            self.replay(downEvent: pending.downEvent, upEvent: pending.upEvent, proxy: nil)
        }
        pendingReplay = PendingReplay(id: id, point: point, date: now, downEvent: downEvent, upEvent: upEvent, workItem: workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    private func consumeMatchingPendingReplay(at point: CGPoint) -> Bool {
        guard let pendingReplay else { return false }
        let withinTime = Date().timeIntervalSince(pendingReplay.date) <= NSEvent.doubleClickInterval
        let nearby = max(abs(point.x - pendingReplay.point.x), abs(point.y - pendingReplay.point.y)) < clickMoveTolerance
        guard withinTime && nearby else { return false }
        pendingReplay.workItem.cancel()
        self.pendingReplay = nil
        return true
    }

    private func flushPendingReplay() {
        guard let pendingReplay else { return }
        pendingReplay.workItem.cancel()
        self.pendingReplay = nil
        replay(downEvent: pendingReplay.downEvent, upEvent: pendingReplay.upEvent, proxy: nil)
    }

    private func replay(downEvent: CGEvent, upEvent: CGEvent, proxy: CGEventTapProxy?) {
        downEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        upEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        // 生成事件也可能送达全局观察器；在极短窗口内忽略它们，避免被当作新的物理点击。
        ignoreObservedEventsUntil = Date().addingTimeInterval(0.06)
        if let proxy {
            downEvent.tapPostEvent(proxy)
            upEvent.tapPostEvent(proxy)
        } else {
            downEvent.post(tap: .cgSessionEventTap)
            upEvent.post(tap: .cgSessionEventTap)
        }
    }

    private func appKitScreenPoint(from quartzPoint: CGPoint) -> CGPoint {
        // Quartz 事件坐标以屏幕左上为原点；手势识别统一使用 AppKit 左下原点。
        let combinedFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        guard !combinedFrame.isNull else { return quartzPoint }
        return CGPoint(x: quartzPoint.x, y: combinedFrame.maxY - quartzPoint.y)
    }

    private func quartzScreenPoint(from appKitPoint: CGPoint) -> CGPoint {
        let combinedFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }
        guard !combinedFrame.isNull else { return appKitPoint }
        return CGPoint(x: appKitPoint.x, y: combinedFrame.maxY - appKitPoint.y)
    }

    /// 在右键按下时启动有限时的 AX 命中测试。后续动作投递前会重新激活该应用，
    /// 从而避免手势落在新窗口时仍对旧窗口执行复制、粘贴或确认。
    private func requestWindowFocus(atQuartzPoint point: CGPoint) {
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        focusedTargetPID = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pid = WindowFocusController.shared.focusWindow(at: point)
            DispatchQueue.main.async {
                guard let self, self.focusRequestGeneration == generation else { return }
                self.focusedTargetPID = pid
            }
        }
    }

    private func appendDelayedPoint(_ point: CGPoint, force: Bool = false) {
        if !force, let previous = delayedPoints.last, hypot(point.x - previous.x, point.y - previous.y) < 2 { return }
        if delayedPoints.count < maximumRecordedPoints {
            delayedPoints.append(point)
        } else if force, !delayedPoints.isEmpty {
            delayedPoints[delayedPoints.count - 1] = point
        }
    }

    /// 手势优先模式的轨迹不会进入全局观察器，因此在低层 tap 内独立复用相同识别规则。
    private func executeGesture(_ points: [CGPoint]) {
        guard let start = points.first, let end = points.last else { return }
        let terminalDistance = max(abs(end.x - start.x), abs(end.y - start.y))
        guard terminalDistance >= Config.shared.minimumDistance else { return }

        let pathLength = polylineLength(points)
        let endDistance = hypot(end.x - start.x, end.y - start.y)
        if pathLength > max(endDistance * 1.12, Config.shared.minimumDistance),
           let match = GestureTemplateRecognizer.bestMatch(
                for: points,
                in: Config.shared.customGestures,
                threshold: Config.shared.templateThreshold
           ), match.gesture.action.kind != .none {
            dispatch(match.gesture.action)
            return
        }

        let action = Config.shared.action(for: direction(from: start, to: end))
        guard action.kind != .none else { return }
        dispatch(action)
    }

    private func handleMouseEvent(type: NSEvent.EventType, at point: CGPoint) {
        guard !isModalEditing, Config.shared.gestureEnabled else { return }
        switch type {
        case .rightMouseDown:
            requestWindowFocus(atQuartzPoint: quartzScreenPoint(from: point))
            beginTracking(at: point)
        case .rightMouseDragged:
            guard isTracking else { return }
            appendPoint(point)
        case .rightMouseUp:
            guard isTracking else { return }
            appendPoint(point, force: true)
            finishTracking()
        default:
            return
        }
    }

    private func beginTracking(at point: CGPoint) {
        resetTracking()
        isTracking = true
        startPoint = point
        rawPoints = [point]
    }

    private func finishTracking() {
        if let completion = recordingCompletion {
            finishRecording(with: completion)
            return
        }
        let points = rawPoints
        defer { resetTracking() }
        guard let start = points.first, let end = points.last else { return }
        let terminalDistance = max(abs(end.x - start.x), abs(end.y - start.y))
        if terminalDistance < clickMoveTolerance {
            if let action = actionForDoubleClick(at: end) { dispatch(action) }
            return
        }

        lastRightClick = nil
        let pathLength = polylineLength(points)
        let endDistance = hypot(end.x - start.x, end.y - start.y)
        if pathLength > max(endDistance * 1.12, Config.shared.minimumDistance),
           let match = GestureTemplateRecognizer.bestMatch(for: points, in: Config.shared.customGestures, threshold: Config.shared.templateThreshold),
           match.gesture.action.kind != .none {
            dispatch(match.gesture.action)
            return
        }
        guard terminalDistance >= Config.shared.minimumDistance else { return }
        let action = Config.shared.action(for: direction(from: start, to: end))
        guard action.kind != .none else { return }
        dispatch(action)
    }

    private func finishRecording(with completion: @escaping ([CGPoint]) -> Void) {
        let points = rawPoints
        recordingCompletion = nil
        removeLocalRecordingMonitor()
        resetTracking()
        DispatchQueue.main.async { completion(points) }
    }

    private func removeLocalRecordingMonitor() {
        if let localRecordingMonitor {
            NSEvent.removeMonitor(localRecordingMonitor)
            self.localRecordingMonitor = nil
        }
    }

    private func appendPoint(_ point: CGPoint, force: Bool = false) {
        guard isTracking else { return }
        if !force, let previous = rawPoints.last, hypot(point.x - previous.x, point.y - previous.y) < 2 { return }
        if rawPoints.count < maximumRecordedPoints {
            rawPoints.append(point)
        } else if force, !rawPoints.isEmpty {
            rawPoints[rawPoints.count - 1] = point
        }
    }

    private func actionForDoubleClick(at point: CGPoint) -> GestureAction? {
        let now = Date()
        let action = Config.shared.action(for: .rightDoubleClick)
        guard action.kind != .none else { return nil }
        guard let lastRightClick else {
            self.lastRightClick = (point, now)
            return nil
        }
        let withinTime = now.timeIntervalSince(lastRightClick.upTime) <= NSEvent.doubleClickInterval
        let nearby = max(abs(point.x - lastRightClick.point.x), abs(point.y - lastRightClick.point.y)) < clickMoveTolerance
        self.lastRightClick = nil
        return withinTime && nearby ? action : nil
    }

    private func direction(from start: CGPoint, to end: CGPoint) -> StandardGesture {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let ratio = abs(dx) / max(abs(dy), 1)
        if ratio >= 0.4 && ratio <= 2.5 {
            switch (dx > 0, dy > 0) {
            case (true, true): return .upRight
            case (false, true): return .upLeft
            case (true, false): return .downRight
            case (false, false): return .downLeft
            }
        }
        return abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
    }

    private func dispatch(_ action: GestureAction) {
        let focusGeneration = focusRequestGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + actionDelay) { [weak self] in
            guard let self, !self.isModalEditing else { return }
            // 仅使用同一右键会话获得的焦点快照；新会话不会污染旧动作的目标。
            if self.focusRequestGeneration == focusGeneration, let pid = self.focusedTargetPID {
                _ = WindowFocusController.shared.reactivateApplication(pid: pid)
            }
            ActionExecutor.execute(action)
        }
    }

    private func resetTracking() {
        isTracking = false
        startPoint = nil
        rawPoints.removeAll(keepingCapacity: true)
    }

    private func polylineLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }
}
