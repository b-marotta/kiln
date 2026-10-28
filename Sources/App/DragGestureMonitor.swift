import AppKit

/// Reveals the shelf on Shift only during a fresh file drag.
final class DragGestureMonitor {
    var onShelfRequested: (() -> Void)?
    private var monitors: [Any] = []
    private var baselineChangeCount = NSPasteboard(name: .drag).changeCount
    private var armed = false
    private var shiftDown = false

    func start() {
        stop()
        baselineChangeCount = NSPasteboard(name: .drag).changeCount
        shiftDown = NSEvent.modifierFlags.contains(.shift)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .leftMouseDragged, .leftMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) { monitors.append(global) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        let down = event.modifierFlags.contains(.shift)
        let rose = down && !shiftDown
        shiftDown = down
        if event.type == .leftMouseUp {
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            armed = false
            return
        }
        // Releasing Shift allows reopening after Esc during the same drag.
        if !down { armed = false; return }
        guard !armed, event.type == .leftMouseDragged || rose,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount,
              PasteboardFileURLs.fileURLs(from: pasteboard).contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        armed = true
        onShelfRequested?()
    }
}
