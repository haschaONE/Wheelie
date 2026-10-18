import CoreGraphics
import Foundation

/// Screen edge a Float can attach to as a slim tab.
public enum FloatEdge: String, Codable, Sendable {
    case left, right
}

/// Edge-docking geometry. All rects are in AppKit screen coordinates (y up);
/// `visibleFrame` is the screen's visible frame (menu bar and Dock excluded).
public enum FloatDocking {
    /// Collapsed tab size (the edge side is flush with the screen).
    public static let tabSize = CGSize(width: 62, height: 104)
    /// The pointer within this distance of an edge attaches a moving Float.
    public static let attachZone: CGFloat = 24
    /// A floating Float pushed this fraction of its width past an edge attaches too,
    /// as long as the pointer is within `detachDistance` of that edge.
    public static let overshootFraction: CGFloat = 0.4
    /// A docked tab detaches once the pointer is this far from its edge.
    /// Larger than the tab plus the attach zone, so attach/detach has hysteresis.
    /// An expanded docked panel reaches further in; see `detachThreshold`.
    public static let detachDistance: CGFloat = 110
    /// Keeps tabs and docked panels off the very top/bottom of the screen.
    public static let verticalInset: CGFloat = 8

    /// Where a Float being moved should be: attached to `edge`, or floating (nil).
    /// - Parameters:
    ///   - cursor: pointer location.
    ///   - frame: the Float's frame if it followed the pointer freely.
    ///   - current: the edge it is attached to right now (nil while floating).
    ///   - allowed: edges that may take a tab (see `outerEdges`).
    public static func decision(cursor: CGPoint, frame: CGRect, visibleFrame: CGRect, current: FloatEdge?,
                                allowed: Set<FloatEdge> = [.left, .right]) -> FloatEdge? {
        let fromLeft = cursor.x - visibleFrame.minX
        let fromRight = visibleFrame.maxX - cursor.x
        if let current {
            let distance = current == .left ? fromLeft : fromRight
            return distance > detachThreshold(frame: frame, edge: current, visibleFrame: visibleFrame) ? nil : current
        }
        // Overshoot only counts while the pointer is close enough to stay attached
        // afterwards; otherwise the Float would dock and immediately detach again.
        let overshoot = frame.width * overshootFraction
        if allowed.contains(.left),
           fromLeft <= attachZone || (frame.minX <= visibleFrame.minX - overshoot && fromLeft <= detachDistance) {
            return .left
        }
        if allowed.contains(.right),
           fromRight <= attachZone || (frame.maxX >= visibleFrame.maxX + overshoot && fromRight <= detachDistance) {
            return .right
        }
        return nil
    }

    /// How far from `edge` the pointer may go before a Float docked there with `frame`
    /// detaches. A collapsed tab uses `detachDistance`; a wider expanded panel adds the
    /// same margin beyond its inner side, so it can be held anywhere and slid along the edge.
    public static func detachThreshold(frame: CGRect, edge: FloatEdge, visibleFrame: CGRect) -> CGFloat {
        // How far the docked frame reaches in from the edge (it is flush with it; never more than its width).
        let fromEdge = edge == .left ? frame.maxX - visibleFrame.minX : visibleFrame.maxX - frame.minX
        let reach = max(0, min(frame.width, fromEdge))
        return max(detachDistance, reach + (detachDistance - tabSize.width))
    }

    /// Edges of a display that don't border another display at height `y`, so moving
    /// a Float across to the neighbouring display doesn't dock it on the way.
    public static func outerEdges(of screenFrame: CGRect, others: [CGRect], at y: CGFloat) -> Set<FloatEdge> {
        var edges: Set<FloatEdge> = [.left, .right]
        for other in others where other != screenFrame && other.minY <= y && y <= other.maxY {
            if abs(other.minX - screenFrame.maxX) < 1 { edges.remove(.right) }
            if abs(other.maxX - screenFrame.minX) < 1 { edges.remove(.left) }
        }
        return edges
    }

    /// Edge a Float collapses to when asked: the nearer one, unless only the other is free.
    public static func collapseEdge(for frame: CGRect, visibleFrame: CGRect, allowed: Set<FloatEdge>) -> FloatEdge {
        let nearest = nearestEdge(of: frame, in: visibleFrame)
        if allowed.contains(nearest) || allowed.isEmpty { return nearest }
        return nearest == .left ? .right : .left
    }

    /// Edge a floating Float collapses to when asked (closest side of its screen).
    public static func nearestEdge(of frame: CGRect, in visibleFrame: CGRect) -> FloatEdge {
        frame.midX < visibleFrame.midX ? .left : .right
    }

    /// Clamps a vertical centre so a panel of `height` fits on screen.
    public static func clampedCenterY(_ y: CGFloat, height: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let low = visibleFrame.minY + verticalInset + height / 2
        let high = visibleFrame.maxY - verticalInset - height / 2
        guard low <= high else { return visibleFrame.midY }
        return min(max(y, low), high)
    }

    /// Collapsed tab, flush with `edge`, centred on `centerY` (clamped on screen).
    public static func tabFrame(edge: FloatEdge, centerY: CGFloat, visibleFrame: CGRect) -> CGRect {
        attachedFrame(edge: edge, centerY: centerY, size: tabSize, visibleFrame: visibleFrame)
    }

    /// A docked Float expanded out of its tab: same edge and centre, full panel size.
    public static func attachedFrame(edge: FloatEdge, centerY: CGFloat, size: CGSize,
                                     visibleFrame: CGRect) -> CGRect {
        let y = clampedCenterY(centerY, height: size.height, visibleFrame: visibleFrame) - size.height / 2
        let x = edge == .left ? visibleFrame.minX : visibleFrame.maxX - size.width
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Keeps a floating Float fully inside the visible frame.
    public static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - f.width))
        f.origin.y = min(max(f.minY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - f.height))
        return f
    }

    /// A Float of `size` centred on `point`, kept on screen.
    public static func frame(centeredOn point: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGRect {
        clamp(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                     width: size.width, height: size.height), to: visibleFrame)
    }

    /// When a Float detaches from its edge: the panel is placed so the pointer
    /// holds it by the middle of its header (`headerHeight` tall).
    public static func detachedFrame(cursor: CGPoint, size: CGSize, headerHeight: CGFloat) -> CGRect {
        CGRect(x: cursor.x - size.width / 2, y: cursor.y - size.height + headerHeight / 2,
               width: size.width, height: size.height)
    }

    /// Offsets `frame` until no frame in `occupied` shares its origin (cascade new Floats).
    public static func cascade(_ frame: CGRect, avoiding occupied: [CGRect], visibleFrame: CGRect,
                               step: CGFloat = 22) -> CGRect {
        var f = frame
        for _ in 0..<12 {
            let clash = occupied.contains { abs($0.minX - f.minX) < 8 && abs($0.maxY - f.maxY) < 8 }
            guard clash else { break }
            f.origin.x += step
            f.origin.y -= step
            f = clamp(f, to: visibleFrame)
        }
        return f
    }
}
