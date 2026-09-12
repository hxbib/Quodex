import AppKit
import SwiftUI

struct AccountDragSession: Equatable {
    let accountID: String
    let originalOrder: [String]
    let size: CGSize
    let grabOffset: CGPoint
    var previewOrder: [String]
    var pointer: CGPoint

    var origin: CGPoint {
        CGPoint(x: pointer.x - grabOffset.x, y: pointer.y - grabOffset.y)
    }

    mutating func update(pointer: CGPoint, frames: [String: CGRect]) -> Bool {
        self.pointer = pointer
        let centerY = origin.y + size.height / 2
        if let placeholder = frames[accountID],
           centerY >= placeholder.minY - 3,
           centerY <= placeholder.maxY + 3 {
            return false
        }
        let base = previewOrder.filter { $0 != accountID }
        let visible = base.compactMap { id -> (String, CGRect)? in
            guard let rect = frames[id] else { return nil }
            return (id, rect)
        }.sorted { $0.1.minY < $1.1.minY }
        guard !visible.isEmpty else { return false }
        let insertion: Int
        if let next = visible.first(where: { centerY < $0.1.midY }),
           let index = base.firstIndex(of: next.0) {
            insertion = index
        } else if let last = visible.last, let index = base.firstIndex(of: last.0) {
            insertion = index + 1
        } else {
            return false
        }
        var order = base
        order.insert(accountID, at: insertion)
        guard order != previewOrder else { return false }
        previewOrder = order
        return true
    }
}

enum DragScrollVelocity {
    static func pointsPerSecond(pointerY: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        let edge = min(82, height / 3)
        if pointerY < edge {
            let proximity = min(1, max(0, (edge - pointerY) / edge))
            return -(70 + 1500 * proximity * proximity)
        }
        if pointerY > height - edge {
            let proximity = min(1, max(0, (pointerY - height + edge) / edge))
            return 70 + 1500 * proximity * proximity
        }
        return 0
    }
}

@MainActor
final class AccountDragController: ObservableObject {
    weak var scrollView: NSScrollView?
    weak var viewport: NSView?
    var enabled = true
    var begin: (CGPoint) -> Bool = { _ in false }
    var canBegin: (CGPoint) -> Bool = { _ in false }
    var moved: (CGPoint) -> Void = { _ in }
    var ended: (Bool) -> Void = { _ in }
    private(set) var isDragging = false
    private var mouseDownPoint: CGPoint?
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var globalMonitor: Any?
    private var timer: Timer?
    private var lastTick: TimeInterval = 0

    func attach(_ view: NSView) {
        viewport = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == nil }
            return handled ? nil : event
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: view.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDragging else { return }
                self.cancel()
            }
        }
    }

    func detach() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        monitor = nil
        observer = nil
        globalMonitor = nil
        viewport = nil
    }

    func cancel() {
        mouseDownPoint = nil
        timer?.invalidate()
        timer = nil
        if isDragging {
            isDragging = false
            ended(false)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let viewport, let window = viewport.window, window.isVisible else { return event }
        if event.type == .keyDown, event.keyCode == 53, isDragging {
            cancel()
            return nil
        }
        guard event.window === window else {
            if event.type == .leftMouseDown { cancel() }
            return event
        }
        let point = viewport.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = enabled && viewport.bounds.contains(point) && canBegin(point)
                ? point : nil
            return event
        case .leftMouseDragged:
            if !isDragging, let start = mouseDownPoint,
               hypot(point.x - start.x, point.y - start.y) >= 5 {
                guard enabled, begin(start) else {
                    mouseDownPoint = nil
                    return event
                }
                isDragging = true
                lastTick = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrollTick() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            guard isDragging else { return event }
            moved(point)
            return nil
        case .leftMouseUp:
            mouseDownPoint = nil
            guard isDragging else { return event }
            timer?.invalidate()
            timer = nil
            moved(point)
            isDragging = false
            ended(viewport.bounds.contains(point))
            return nil
        default:
            return event
        }
    }

    private func scrollTick() {
        guard isDragging, let viewport, let window = viewport.window else { return }
        let point = viewport.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(1.0 / 30, max(0, now - lastTick))
        lastTick = now
        guard point.x >= 0, point.x <= viewport.bounds.width,
              let scrollView, let document = scrollView.documentView else {
            moved(point)
            return
        }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let velocity = DragScrollVelocity.pointsPerSecond(pointerY: point.y, height: viewport.bounds.height)
        let direction: CGFloat = document.isFlipped ? 1 : -1
        var origin = clip.bounds.origin
        origin.y = min(maximum, max(0, origin.y + direction * velocity * elapsed))
        if origin != clip.bounds.origin {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
        moved(point)
    }
}

struct AccountDragInput: NSViewRepresentable {
    let controller: AccountDragController
    let enabled: Bool
    let canBegin: (CGPoint) -> Bool
    let begin: (CGPoint) -> Bool
    let moved: (CGPoint) -> Void
    let ended: (Bool) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        controller.enabled = enabled
        controller.canBegin = canBegin
        controller.begin = begin
        controller.moved = moved
        controller.ended = ended
        if view.window != nil { controller.attach(view) }
    }

    static func dismantleNSView(_ nsView: InputView, coordinator: ()) {
        nsView.controller?.detach()
    }

    final class InputView: NSView {
        weak var controller: AccountDragController?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { controller?.attach(self) } else { controller?.detach() }
        }
    }
}

struct AccountScrollProbe: NSViewRepresentable {
    let controller: AccountDragController
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.controller = controller
        return view
    }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.resolve() }
    final class ProbeView: NSView {
        weak var controller: AccountDragController?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolve() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); resolve() }
        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let scroll = self.enclosingScrollView { self.controller?.scrollView = scroll }
            }
        }
    }
}
