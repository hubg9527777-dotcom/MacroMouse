import Cocoa

/// 以统一坐标系绘制已保存的归一化手势轨迹。
final class GesturePreviewView: NSView {
    var points: [GesturePoint] = [] {
        didSet { needsDisplay = true }
    }

    var showsBadge = true {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()

        guard points.count >= 2 else { return }
        let raw = points.map(\.cgPoint)
        guard let minX = raw.map(\.x).min(), let maxX = raw.map(\.x).max(),
              let minY = raw.map(\.y).min(), let maxY = raw.map(\.y).max()
        else { return }

        let sourceWidth = max(maxX - minX, 0.001)
        let sourceHeight = max(maxY - minY, 0.001)
        // 轨迹保留适度留白；较小的外层列表缩略图使用更紧凑的最小边距，
        // 同时始终容纳起点和终点标记，避免压缩后裁切。
        let horizontalInset = max(7, bounds.width * 0.13)
        let verticalInset = max(4, bounds.height * 0.16)
        let drawableWidth = max(bounds.width - horizontalInset * 2, 1)
        let drawableHeight = max(bounds.height - verticalInset * 2, 1)
        let scale = min(drawableWidth / sourceWidth, drawableHeight / sourceHeight)

        // 先归一化到原点，再按最终尺寸居中；不可直接对原始坐标偏移，否则会贴边。
        let renderedWidth = sourceWidth * scale
        let renderedHeight = sourceHeight * scale
        let originX = (bounds.width - renderedWidth) / 2
        let originY = (bounds.height - renderedHeight) / 2
        func transform(_ point: CGPoint) -> NSPoint {
            // View 为翻转坐标系，Y 轴转换后保持与用户屏幕绘制方向一致。
            NSPoint(
                x: originX + (point.x - minX) * scale,
                y: originY + (maxY - point.y) * scale
            )
        }

        let path = NSBezierPath()
        for (index, point) in raw.enumerated() {
            if index == 0 { path.move(to: transform(point)) }
            else { path.line(to: transform(point)) }
        }
        NSColor.systemBlue.setStroke()
        path.lineWidth = max(1.4, min(bounds.width, bounds.height) / 36)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

        if let start = raw.first {
            let point = transform(start)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.8, y: point.y - 2.8, width: 5.6, height: 5.6)).fill()
        }
        if let end = raw.last {
            let point = transform(end)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 2.8, y: point.y - 2.8, width: 5.6, height: 5.6)).fill()
        }
    }
}
