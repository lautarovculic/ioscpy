import AppKit
import SwiftUI

private struct MirrorResizeEdges: OptionSet {
    let rawValue: Int
    static let left = MirrorResizeEdges(rawValue: 1 << 0)
    static let right = MirrorResizeEdges(rawValue: 1 << 1)
    static let bottom = MirrorResizeEdges(rawValue: 1 << 2)
    static let top = MirrorResizeEdges(rawValue: 1 << 3)
}

/// Borderless NSWindow does not provide a useful visible resize affordance.
/// This overlay only captures the thin device-frame perimeter; the entire
/// interior returns nil from hitTest so iPhone touch input continues to reach
/// MirrorMetalView without any SwiftUI gesture competition.
@MainActor
final class MirrorEdgeResizeNSView: NSView {
    private let hitWidth: CGFloat = 11
    private var activeEdges: MirrorResizeEdges = []
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var startAspect: CGFloat = 1

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return edges(at: local).isEmpty ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width
        let h = bounds.height
        addCursorRect(NSRect(x: 0, y: hitWidth, width: hitWidth, height: max(0, h - hitWidth * 2)),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: max(0, w - hitWidth), y: hitWidth, width: hitWidth,
                             height: max(0, h - hitWidth * 2)),
                      cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: hitWidth, y: 0, width: max(0, w - hitWidth * 2), height: hitWidth),
                      cursor: .resizeUpDown)
        addCursorRect(NSRect(x: hitWidth, y: max(0, h - hitWidth),
                             width: max(0, w - hitWidth * 2), height: hitWidth),
                      cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        activeEdges = edges(at: convert(event.locationInWindow, from: nil))
        guard !activeEdges.isEmpty else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        let ratio = window.contentAspectRatio
        startAspect = ratio.width > 0 && ratio.height > 0
            ? ratio.width / ratio.height
            : startFrame.width / max(startFrame.height, 1)
        AppWindowManager.shared.beginMirrorWindowResize()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !activeEdges.isEmpty, startAspect > 0 else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y

        let horizontal = activeEdges.contains(.left) || activeEdges.contains(.right)
        let vertical = activeEdges.contains(.top) || activeEdges.contains(.bottom)
        let desiredWidthDelta = activeEdges.contains(.right) ? dx
            : (activeEdges.contains(.left) ? -dx : 0)
        let desiredHeightDelta = activeEdges.contains(.top) ? dy
            : (activeEdges.contains(.bottom) ? -dy : 0)

        var proposedHeight: CGFloat
        if horizontal && vertical {
            // Project the pointer movement onto the fixed-aspect resize vector
            // (aspect, 1). Corners therefore follow the mouse naturally instead
            // of reacting to only one axis.
            proposedHeight = startFrame.height +
                (desiredWidthDelta * startAspect + desiredHeightDelta) /
                (startAspect * startAspect + 1)
        } else if horizontal {
            proposedHeight = (startFrame.width + desiredWidthDelta) / startAspect
        } else {
            proposedHeight = startFrame.height + desiredHeightDelta
        }

        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let minHeight = max(window.minSize.height, 320 / startAspect)
        let maxHeight = max(minHeight, min(screen.height * 0.96, screen.width * 0.96 / startAspect))
        proposedHeight = min(max(proposedHeight, minHeight), maxHeight)
        let proposedWidth = proposedHeight * startAspect

        let x: CGFloat
        if activeEdges.contains(.left) {
            x = startFrame.maxX - proposedWidth
        } else if activeEdges.contains(.right) {
            x = startFrame.minX
        } else {
            x = startFrame.midX - proposedWidth / 2
        }

        let y: CGFloat
        if activeEdges.contains(.bottom) {
            y = startFrame.maxY - proposedHeight
        } else if activeEdges.contains(.top) {
            y = startFrame.minY
        } else {
            y = startFrame.midY - proposedHeight / 2
        }

        window.setFrame(
            NSRect(x: x, y: y, width: proposedWidth, height: proposedHeight),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
        AppWindowManager.shared.endMirrorWindowResize()
    }

    private func edges(at point: NSPoint) -> MirrorResizeEdges {
        guard bounds.contains(point) else { return [] }
        var result: MirrorResizeEdges = []
        if point.x <= hitWidth { result.insert(.left) }
        if point.x >= bounds.width - hitWidth { result.insert(.right) }
        if point.y <= hitWidth { result.insert(.bottom) }
        if point.y >= bounds.height - hitWidth { result.insert(.top) }
        return result
    }
}

struct MirrorEdgeResizeRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MirrorEdgeResizeNSView {
        MirrorEdgeResizeNSView(frame: .zero)
    }

    func updateNSView(_ nsView: MirrorEdgeResizeNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// Dedicated AppKit drag surface for the floating toolbar. A native NSView is
/// used instead of SwiftUI DragGesture so AppKit never starts a competing
/// NSPanel move session while we move the parent mirror window ourselves.
@MainActor
final class MirrorWindowDragHandleNSView: NSView {
    private var startMouse = NSPoint.zero
    private var dragging = false

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        dragging = true
        NSCursor.closedHand.push()
        AppWindowManager.shared.beginMirrorWindowDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let mouse = NSEvent.mouseLocation
        AppWindowManager.shared.updateMirrorWindowDrag(
            translation: CGSize(
                width: mouse.x - startMouse.x,
                height: startMouse.y - mouse.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        NSCursor.pop()
        AppWindowManager.shared.endMirrorWindowDrag()
    }
}

struct MirrorWindowDragHandleRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MirrorWindowDragHandleNSView {
        MirrorWindowDragHandleNSView(frame: .zero)
    }

    func updateNSView(_ nsView: MirrorWindowDragHandleNSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
