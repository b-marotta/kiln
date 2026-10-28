import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

/// A compact, persistent file shelf anchored below the menu bar.
final class DropOverlayController: NSObject {
    private var panel: NSPanel?
    private var shelf: FileShelfView?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var dragEndTimer: Timer?
    private var awaitingDrop = false
    private var escapeHotKey: EventHotKeyRef?
    private var escapeHandler: EventHandlerRef?
    private var escapeHandled = false
    private var captureReturnDown = false
    var onAction: ((FanAction, [URL]) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isVisible = false

    func show() {
        if isVisible { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        let overflow = FileShelfView.overflow
        let contentWidth = min(640, screen.visibleFrame.width - 32)
        let width = contentWidth + overflow * 2
        let view = FileShelfView(frame: NSRect(x: 0, y: 0, width: width, height: 132))
        view.onClose = { [weak self] in self?.hide() }
        view.onFilesReceived = { [weak self] in self?.stopWaitingForDrop() }
        view.onHeightChange = { [weak self] height in self?.resize(height: height) }
        view.onAction = { [weak self] action, urls in
            self?.hide()
            self?.onAction?(action, urls)
        }
        let panel = FileShelfPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.onCancel = { [weak self] in self?.handleEscape(pressed: true) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = view
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - 12 - view.frame.height))
        self.panel = panel
        shelf = view
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        isVisible = true
        onVisibilityChange?(true)
    }

    func showForDrag() {
        show()
        guard shelf?.hasFiles == false, !awaitingDrop else { return }
        awaitingDrop = true
        // Finder's tracking loop can consume mouse-up before NSEvent monitors see it.
        // Poll only while awaiting a drop, in common modes so dragging cannot stall it.
        weak var waitingShelf = shelf
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.dragEndTimer?.invalidate()
            self.dragEndTimer = nil
            // Allow the destination's performDragOperation to commit the file first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, let waitingShelf, self.shelf === waitingShelf else { return }
                self.finishPendingDrag()
            }
        }
        dragEndTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishPendingDrag() {
        guard awaitingDrop else { return }
        if shelf?.hasFiles == true { stopWaitingForDrop() } else { hide() }
    }

    private func stopWaitingForDrop() {
        awaitingDrop = false
        dragEndTimer?.invalidate()
        dragEndTimer = nil
    }

    func present(urls: [URL]) {
        show()
        shelf?.receive(urls)
        panel?.makeKey()
    }

    func presentImage(urls: [URL], action: FanAction) {
        present(urls: urls)
        shelf?.selectImageAction(action)
    }

    func presentPDF(urls: [URL], action: FanAction) {
        present(urls: urls)
        shelf?.selectPDFAction(action)
    }

    private func resize(height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    func hide() {
        escapeHandled = false
        captureReturnDown = false
        stopWaitingForDrop()
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        if let escapeHandler { RemoveEventHandler(escapeHandler) }
        escapeHotKey = nil
        escapeHandler = nil
        for monitor in [localKeyMonitor, globalKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localKeyMonitor = nil
        globalKeyMonitor = nil
        shelf?.shutdownAudio()
        panel?.orderOut(nil)
        panel = nil
        shelf = nil
        guard isVisible else { return }
        isVisible = false
        onVisibilityChange?(false)
    }

    func toggle() { if isVisible { hide() } else { show() } }

    private func handleEscape(pressed: Bool) {
        guard pressed else { escapeHandled = false; return }
        guard !escapeHandled else { return }
        escapeHandled = true
        if shelf?.endSignatureAcquisition() == true { return }
        hide()
    }

    private func installMonitors() {
        // A temporary Carbon hotkey receives Esc across apps without relying on
        // accessibility permission for a global NSEvent keyboard monitor.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x4B4C4E45, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<DropOverlayController>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { [weak owner] in owner?.handleEscape(pressed: pressed) }
            return noErr
        }, 2, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &escapeHandler)
        if status == noErr {
            RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4B4C4E45, id: 1), GetApplicationEventTarget(), 0, &escapeHotKey)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.handleEscape(pressed: event.type == .keyDown)
                return nil
            }
            if [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(event.keyCode) {
                if event.type == .keyUp {
                    if self.captureReturnDown { self.captureReturnDown = false; return nil }
                } else {
                    if self.captureReturnDown { return nil }
                    if self.shelf?.endSignatureAcquisition() == true {
                        self.captureReturnDown = true
                        return nil
                    }
                }
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) { self?.handleEscape(pressed: event.type == .keyDown) }
        }
    }
}

