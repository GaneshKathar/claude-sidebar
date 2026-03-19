import AppKit
import Foundation

// MARK: - Docking Delegate

protocol DockingDelegate: AnyObject {
    func layoutSubviews()
    func collapsedContentHeight() -> CGFloat
    var isSidebarExpanded: Bool { get }
    var collapsedWidth: CGFloat { get }
    var expandedWidth: CGFloat { get }
}

// MARK: - Docking Manager (extracted from SidebarController — SRP)

class DockingManager {
    enum DockSide { case left, right }

    let window: NSPanel
    weak var delegate: DockingDelegate?

    var dockSide: DockSide = .right
    var userY: CGFloat?          // set whenever the user drags; nil = use default (center)
    var isDragging = false
    var isAnimating = false

    private var snapWorkItem: DispatchWorkItem?
    private var screenChangeObserver: NSObjectProtocol?
    private var windowMoveObserver: NSObjectProtocol?

    init(window: NSPanel) {
        self.window = window
    }

    deinit {
        snapWorkItem?.cancel()
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = windowMoveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Position

    func screenForWindow() -> NSScreen? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main
    }

    func clampY(_ y: CGFloat, height: CGFloat, in sf: NSRect) -> CGFloat {
        min(max(y, sf.minY), sf.maxY - height)
    }

    func resizeCollapsedToFitContent() {
        guard let delegate = delegate else { return }
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let targetH = delegate.collapsedContentHeight()
        let frame = window.frame
        guard abs(frame.height - targetH) > 2 else { return }
        let baseY = userY ?? (sf.midY - targetH / 2)
        let newY = clampY(baseY, height: targetH, in: sf)
        let newFrame = NSRect(x: frame.origin.x, y: newY, width: frame.width, height: targetH)
        window.setFrame(newFrame, display: true)
        delegate.layoutSubviews()
    }

    func positionWindow() {
        guard let delegate = delegate else { return }
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let currentWidth = delegate.isSidebarExpanded ? delegate.expandedWidth : delegate.collapsedWidth
        let h = delegate.isSidebarExpanded ? sf.height * 0.7 : delegate.collapsedContentHeight()
        let x: CGFloat
        switch dockSide {
        case .right: x = sf.maxX - currentWidth
        case .left:  x = sf.minX
        }
        let baseY = userY ?? (sf.midY - h / 2)
        let y = clampY(baseY, height: h, in: sf)
        window.setFrame(NSRect(x: x, y: y, width: currentWidth, height: h), display: true)
    }

    // MARK: - Screen Change Handling

    func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        guard let screen = screenForWindow() else {
            positionWindow()
            return
        }
        let sf = screen.visibleFrame
        var frame = window.frame

        if !sf.intersects(frame) {
            positionWindow()
            return
        }

        switch dockSide {
        case .right: frame.origin.x = sf.maxX - frame.width
        case .left:  frame.origin.x = sf.minX
        }
        frame.origin.y = clampY(frame.origin.y, height: frame.height, in: sf)
        window.setFrame(frame, display: true)
    }

    // MARK: - Drag-to-Snap

    func setupWindowMoveObserver() {
        windowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.handleWindowMoved()
        }
    }

    private func handleWindowMoved() {
        guard !isAnimating else { return }
        isDragging = true
        userY = window.frame.origin.y
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.snapAfterDrag()
        }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func snapAfterDrag() {
        guard !isAnimating else { return }
        guard let screen = screenForWindow() else { return }
        let sf = screen.visibleFrame
        let frame = window.frame

        let distToLeft = frame.minX - sf.minX
        let distToRight = sf.maxX - frame.maxX

        dockSide = distToLeft <= distToRight ? .left : .right

        let targetX: CGFloat
        switch dockSide {
        case .right: targetX = sf.maxX - frame.width
        case .left:  targetX = sf.minX
        }

        let clampedY = clampY(frame.origin.y, height: frame.height, in: sf)
        let snappedFrame = NSRect(x: targetX, y: clampedY,
                                  width: frame.width, height: frame.height)

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Layout.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(snappedFrame, display: true)
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
            self?.isDragging = false
        })
    }
}
