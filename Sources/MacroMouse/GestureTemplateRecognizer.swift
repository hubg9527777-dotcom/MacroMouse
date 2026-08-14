import Foundation
import CoreGraphics

/// 将鼠标轨迹标准化、提取形状特征并进行模板比对。
/// 圆形等闭合图案使用形状特征匹配，忽略起点、大小、方向与自然手绘偏差；其他图案使用模板匹配。
enum GestureTemplateRecognizer {
    static let sampleCount = 32

    private struct CircleMetrics {
        let closureRatio: CGFloat
        let radialVariation: CGFloat
        let turnAmount: CGFloat
        let turnVariation: CGFloat
        let aspectRatio: CGFloat

        var isCircle: Bool {
            // 完整闭环是最强证据；手绘圆常有少量缺口，因此允许至少约 260° 的平滑圆弧。
            let sufficientClosure = closureRatio <= 0.75 || (closureRatio <= 2.05 && turnAmount >= 4.5)
            return sufficientClosure &&
                radialVariation <= 0.45 &&
                // 圆形的曲率应沿轨迹较均匀；方形等折线的转折会集中在少数角点。
                turnVariation <= 1.1 &&
                turnAmount >= 4.3 && turnAmount <= 8.3 &&
                aspectRatio >= 0.40 && aspectRatio <= 2.5
        }
    }

    static func normalizedPoints(from rawPoints: [CGPoint]) -> [GesturePoint] {
        guard rawPoints.count >= 2 else { return [] }
        let simplified = simplify(rawPoints, minimumSpacing: 3)
        let sampled = resample(simplified, count: sampleCount)
        guard sampled.count == sampleCount else { return [] }

        let centroid = CGPoint(
            x: sampled.map(\.x).reduce(0, +) / CGFloat(sampled.count),
            y: sampled.map(\.y).reduce(0, +) / CGFloat(sampled.count)
        )
        let translated = sampled.map { CGPoint(x: $0.x - centroid.x, y: $0.y - centroid.y) }
        let maxCoordinate = translated.reduce(CGFloat.zero) { partial, point in
            max(partial, abs(point.x), abs(point.y))
        }
        guard maxCoordinate > 0.001 else { return [] }
        return translated.map { GesturePoint(CGPoint(x: $0.x / maxCoordinate, y: $0.y / maxCoordinate)) }
    }

    /// 保存图案时的语义形状判定。当前优先支持“圆形”，可在此扩展三角形、方形等类型。
    static func detectedShape(for normalizedPoints: [GesturePoint]) -> GestureShapeKind? {
        guard let metrics = circleMetrics(for: normalizedPoints), metrics.isCircle else { return nil }
        return .circle
    }

    static func isCircle(rawPoints: [CGPoint]) -> Bool {
        let normalized = normalizedPoints(from: rawPoints)
        return detectedShape(for: normalized) == .circle
    }

    /// 数值越小越相似；对两个已归一化且等长的模板计算平均点距离。
    static func distance(_ first: [GesturePoint], _ second: [GesturePoint]) -> CGFloat? {
        guard first.count == sampleCount, second.count == sampleCount else { return nil }
        let total = zip(first, second).reduce(CGFloat.zero) { partial, pair in
            let dx = pair.0.x - pair.1.x
            let dy = pair.0.y - pair.1.y
            return partial + sqrt(dx * dx + dy * dy)
        }
        return total / CGFloat(sampleCount)
    }

    /// 闭合图案允许任意起笔位置和绘制方向；开放图案仍按原始起笔方向匹配。
    static func invariantDistance(_ first: [GesturePoint], _ second: [GesturePoint]) -> CGFloat? {
        guard first.count == sampleCount, second.count == sampleCount else { return nil }
        guard isClosed(first), isClosed(second) else { return distance(first, second) }

        var best = CGFloat.greatestFiniteMagnitude
        for offset in 0..<sampleCount {
            best = min(best, shiftedDistance(first, second, offset: offset, reversed: false))
            best = min(best, shiftedDistance(first, second, offset: offset, reversed: true))
        }
        return best
    }

    static func bestMatch(for rawPoints: [CGPoint], in templates: [CustomGesture], threshold: CGFloat) -> (gesture: CustomGesture, distance: CGFloat)? {
        let normalized = normalizedPoints(from: rawPoints)
        guard normalized.count == sampleCount else { return nil }

        // 圆形按形状语义匹配，而不是逐点模板距离。这样不同起点、顺逆时针与手绘轻微偏差都能命中。
        if detectedShape(for: normalized) == .circle,
           let circle = templates
            .filter({ $0.enabled && ($0.shapeKind ?? detectedShape(for: $0.points)) == .circle })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first {
            return (circle, 0)
        }

        var match: (gesture: CustomGesture, distance: CGFloat)?
        for template in templates where template.enabled {
            // 已标记为圆形的绑定只接受圆形输入，避免自由图案误触发圆形动作。
            let shape = template.shapeKind ?? detectedShape(for: template.points)
            if shape == .circle { continue }

            guard let currentDistance = invariantDistance(normalized, template.points) else { continue }
            if currentDistance <= threshold, currentDistance < (match?.distance ?? .greatestFiniteMagnitude) {
                match = (template, currentDistance)
            }
        }
        return match
    }

    private static func circleMetrics(for points: [GesturePoint]) -> CircleMetrics? {
        guard points.count == sampleCount else { return nil }
        let cgPoints = points.map(\.cgPoint)
        let center = CGPoint(
            x: cgPoints.map(\.x).reduce(0, +) / CGFloat(cgPoints.count),
            y: cgPoints.map(\.y).reduce(0, +) / CGFloat(cgPoints.count)
        )
        let radii = cgPoints.map { hypot($0.x - center.x, $0.y - center.y) }
        let meanRadius = radii.reduce(0, +) / CGFloat(radii.count)
        guard meanRadius > 0.001 else { return nil }
        let variance = radii.reduce(CGFloat.zero) { partial, radius in
            partial + pow(radius - meanRadius, 2)
        } / CGFloat(radii.count)
        let radialVariation = sqrt(variance) / meanRadius

        let start = cgPoints[0]
        let end = cgPoints[cgPoints.count - 1]
        let closureRatio = hypot(end.x - start.x, end.y - start.y) / meanRadius

        let xs = cgPoints.map(\.x)
        let ys = cgPoints.map(\.y)
        let width = max((xs.max() ?? 0) - (xs.min() ?? 0), 0.001)
        let height = max((ys.max() ?? 0) - (ys.min() ?? 0), 0.001)
        let aspectRatio = width / height

        var totalTurn: CGFloat = 0
        var localTurnMagnitudes = [CGFloat]()
        for index in 1..<(cgPoints.count - 1) {
            let previous = cgPoints[index - 1]
            let current = cgPoints[index]
            let next = cgPoints[index + 1]
            let first = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            let second = CGPoint(x: next.x - current.x, y: next.y - current.y)
            let firstLength = hypot(first.x, first.y)
            let secondLength = hypot(second.x, second.y)
            guard firstLength > 0.0001, secondLength > 0.0001 else { continue }
            let cross = first.x * second.y - first.y * second.x
            let dot = first.x * second.x + first.y * second.y
            let localTurn = atan2(cross, dot)
            totalTurn += localTurn
            localTurnMagnitudes.append(abs(localTurn))
        }
        let meanTurn = localTurnMagnitudes.reduce(0, +) / CGFloat(max(localTurnMagnitudes.count, 1))
        let turnVariance = localTurnMagnitudes.reduce(CGFloat.zero) { partial, turn in
            partial + pow(turn - meanTurn, 2)
        } / CGFloat(max(localTurnMagnitudes.count, 1))
        let turnVariation = sqrt(turnVariance) / max(meanTurn, 0.0001)

        return CircleMetrics(
            closureRatio: closureRatio,
            radialVariation: radialVariation,
            turnAmount: abs(totalTurn),
            turnVariation: turnVariation,
            aspectRatio: aspectRatio
        )
    }

    private static func isClosed(_ points: [GesturePoint]) -> Bool {
        guard let metrics = circleMetrics(for: points) else { return false }
        return metrics.closureRatio <= 0.7
    }

    private static func shiftedDistance(_ first: [GesturePoint], _ second: [GesturePoint], offset: Int, reversed: Bool) -> CGFloat {
        let total = (0..<sampleCount).reduce(CGFloat.zero) { partial, index in
            let pairedIndex: Int
            if reversed {
                pairedIndex = (offset - index + sampleCount * 2) % sampleCount
            } else {
                pairedIndex = (index + offset) % sampleCount
            }
            let dx = first[index].x - second[pairedIndex].x
            let dy = first[index].y - second[pairedIndex].y
            return partial + sqrt(dx * dx + dy * dy)
        }
        return total / CGFloat(sampleCount)
    }

    private static func simplify(_ points: [CGPoint], minimumSpacing: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var output = [first]
        for point in points.dropFirst() {
            guard let previous = output.last else { continue }
            if hypot(point.x - previous.x, point.y - previous.y) >= minimumSpacing {
                output.append(point)
            }
        }
        if let last = points.last, output.last != last {
            output.append(last)
        }
        return output
    }

    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count > 1 else { return points }
        let totalLength = pathLength(points)
        guard totalLength > 0.001 else { return [] }

        let step = totalLength / CGFloat(count - 1)
        var output = [points[0]]
        var previous = points[0]
        var distanceSinceLastSample: CGFloat = 0

        for target in points.dropFirst() {
            var segmentStart = previous
            let segmentEnd = target
            var segmentLength = hypot(segmentEnd.x - segmentStart.x, segmentEnd.y - segmentStart.y)

            while distanceSinceLastSample + segmentLength >= step, output.count < count - 1 {
                let remaining = step - distanceSinceLastSample
                let ratio = remaining / segmentLength
                let sample = CGPoint(
                    x: segmentStart.x + (segmentEnd.x - segmentStart.x) * ratio,
                    y: segmentStart.y + (segmentEnd.y - segmentStart.y) * ratio
                )
                output.append(sample)
                segmentStart = sample
                segmentLength = hypot(segmentEnd.x - segmentStart.x, segmentEnd.y - segmentStart.y)
                distanceSinceLastSample = 0
            }
            distanceSinceLastSample += segmentLength
            previous = target
        }

        if let last = points.last {
            while output.count < count {
                output.append(last)
            }
        }
        return output
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
    }
}
