import SwiftUI

enum SharedChartGeometry {
    static func xPosition(index: Int, count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return width / 2 }
        return CGFloat(index) / CGFloat(count - 1) * width
    }

    static func yPosition(value: Double, bounds: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
        return height - CGFloat((value - bounds.lowerBound) / span) * height
    }

    static func evenlySpacedIndexes(count: Int, maxCount: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxCount else { return Array(0..<count) }
        let step = Double(count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { Int((Double($0) * step).rounded()) }
    }

    static func nearestIndex(to x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        guard width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let index = Int((x / step).rounded())
        return min(max(index, 0), count - 1)
    }

    static func nearestBucketIndex(to x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard width > 0 else { return 0 }
        let step = width / CGFloat(count)
        let index = Int((x / step).rounded(.down))
        return min(max(index, 0), count - 1)
    }
}
