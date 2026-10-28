import AppKit
import PDFKit
import UniformTypeIdentifiers

final class SignaturePad: NSView, NSServicesMenuRequestor {
    var onCaptureModeChange: ((Bool) -> Void)?
    var onImportedImage: ((NSImage) -> Bool)?
    private var trackpadMode = false
    var isAcquiring: Bool { trackpadMode }
    private var startsNewCapture = false
    private var activeTouch: NSTouch?
    private var cursorDetached = false
    private var deactivateObserver: NSObjectProtocol?
    private let captureStatus = SignatureCaptureStatusView(frame: NSRect(x: 0, y: 0, width: 290, height: 40))
    private let captureSpinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.indirect]
        captureStatus.appearance = NSAppearance(named: .aqua)
        captureStatus.frame.origin = NSPoint(x: (bounds.width - 290) / 2, y: (bounds.height - 40) / 2)
        captureStatus.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        captureStatus.wantsLayer = true
        captureStatus.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        captureStatus.layer?.cornerRadius = 12
        captureSpinner.style = .spinning
        captureSpinner.controlSize = .small
        captureSpinner.isIndeterminate = true
        captureSpinner.isDisplayedWhenStopped = false
        captureSpinner.frame = NSRect(x: 12, y: 12, width: 16, height: 16)
        captureSpinner.setAccessibilityLabel("In attesa del primo tocco sul trackpad")
        captureStatus.addSubview(captureSpinner)
        let message = NSTextField(labelWithString: "In attesa del tocco sul trackpad…")
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = LiquidGlass.secondaryText
        message.frame = NSRect(x: 38, y: 12, width: 244, height: 17)
        captureStatus.addSubview(message)
        captureStatus.isHidden = true
        addSubview(captureStatus)
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endTrackpadCapture()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        if cursorDetached { CGAssociateMouseAndMouseCursorPosition(1) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endTrackpadCapture() }
    }
    func showAcquisitionMenu() {
        if trackpadMode { endTrackpadCapture(); return }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(self)
        let menu = NSMenu(title: "Acquisisci firma")
        let trackpad = NSMenuItem(title: "Trackpad", action: #selector(beginTrackpadCapture), keyEquivalent: "")
        trackpad.target = self
        trackpad.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)
        menu.addItem(trackpad)
        // AppKit injects its available iPhone/iPad Continuity actions into this contextual menu.
        // Use the public responder/pasteboard integration, rather than private signature-panel APIs.
        let location = convert(NSPoint(x: bounds.midX, y: 10), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: NSApp.currentEvent?.timestamp ?? 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Acquisisci firma")
        let item = NSMenuItem(title: "Trackpad", action: #selector(beginTrackpadCapture), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if window != nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard window != nil, let image = NSImage(pasteboard: pasteboard) else { return false }
        return onImportedImage?(image) ?? false
    }
    @objc private func beginTrackpadCapture() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(self)
        trackpadMode = true
        startsNewCapture = true
        captureStatus.isHidden = false
        captureSpinner.startAnimation(nil)
        onCaptureModeChange?(true)
        needsDisplay = true
    }
    func endTrackpadCapture() {
        captureSpinner.stopAnimation(nil)
        captureStatus.isHidden = true
        activeTouch = nil
        if cursorDetached { CGAssociateMouseAndMouseCursorPosition(1); cursorDetached = false }
        guard trackpadMode else { return }
        trackpadMode = false
        onCaptureModeChange?(false)
        needsDisplay = true
    }
    private func touchPoint(_ touch: NSTouch) -> NSPoint {
        // Preserve the trackpad's physical proportions inside the signature canvas.
        let device = touch.deviceSize
        let scale = min(bounds.width / max(1, device.width), bounds.height / max(1, device.height))
        let size = NSSize(width: device.width * scale, height: device.height * scale)
        let p = touch.normalizedPosition
        return NSPoint(x: ((bounds.width - size.width) / 2 + p.x * size.width) / max(1, bounds.width), y: ((bounds.height - size.height) / 2 + p.y * size.height) / max(1, bounds.height))
    }
    override func touchesBegan(with event: NSEvent) {
        guard trackpadMode, activeTouch == nil,
              let touch = event.touches(matching: .began, in: self).first(where: { $0.type == .indirect && !$0.isResting }) else { return }
        captureSpinner.stopAnimation(nil)
        captureStatus.isHidden = true
        if startsNewCapture { strokes = []; importedImage = nil; startsNewCapture = false }
        activeTouch = touch
        strokes.append([touchPoint(touch)])
        // Keep the pointer over the canvas while drawing; reconnect on every finger lift/cancel.
        cursorDetached = CGAssociateMouseAndMouseCursorPosition(0) == .success
        needsDisplay = true
    }
    override func touchesMoved(with event: NSEvent) {
        guard trackpadMode, let activeTouch,
              let touch = event.touches(matching: .moved, in: self).first(where: { $0.identity.isEqual(activeTouch.identity) }), !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(touchPoint(touch))
        needsDisplay = true
    }
    override func touchesEnded(with event: NSEvent) { finishTouch(event, phase: .ended) }
    override func touchesCancelled(with event: NSEvent) { finishTouch(event, phase: .cancelled) }
    private func finishTouch(_ event: NSEvent, phase: NSTouch.Phase) {
        guard let activeTouch, event.touches(matching: phase, in: self).contains(where: { $0.identity.isEqual(activeTouch.identity) }) else { return }
        self.activeTouch = nil
        if cursorDetached { CGAssociateMouseAndMouseCursorPosition(1); cursorDetached = false }
    }
    override func keyDown(with event: NSEvent) {
        if trackpadMode, [36, 76, 53].contains(event.keyCode) { endTrackpadCapture() }
        else { super.keyDown(with: event) }
    }

    var strokes: [[NSPoint]] = []
    var importedImage: NSImage?
    var contentAspect: CGFloat { bounds.height / max(1, bounds.width) }
    private func imageRect(for image: NSImage) -> NSRect {
        let available = bounds.insetBy(dx: 8, dy: 6)
        let scale = min(available.width / max(1, image.size.width), available.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    func renderedImage() -> CGImage? {
        guard importedImage != nil || strokes.contains(where: { $0.count > 1 }) else { return nil }
        let width = max(1, Int(bounds.width * 3)), height = max(1, Int(bounds.height * 3))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let image = importedImage {
            var proposed = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
            let scale = CGAffineTransform(scaleX: CGFloat(width) / max(1, bounds.width), y: CGFloat(height) / max(1, bounds.height))
            ctx.draw(cg, in: imageRect(for: image).applying(scale))
        }
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            ctx.beginPath()
            for (i, point) in stroke.enumerated() {
                let p = CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        if let image = importedImage {
            image.draw(in: imageRect(for: image))
        }
        if trackpadMode {
            let hint = "Puntatore nel riquadro · Firma sul trackpad senza premere · Invio o Esc per terminare"
            hint.draw(in: NSRect(x: 12, y: 6, width: bounds.width - 24, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: LiquidGlass.secondaryText])
        }
        NSColor.black.setStroke()
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            for (i, p) in stroke.enumerated() {
                let point = NSPoint(x: p.x * bounds.width, y: p.y * bounds.height)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.stroke()
        }
    }
    private func point(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(1, max(0, p.x / bounds.width)), y: min(1, max(0, p.y / bounds.height)))
    }
    override func mouseDown(with event: NSEvent) {
        if trackpadMode { window?.makeFirstResponder(self); return }
        importedImage = nil; strokes.append([point(event)]); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { guard !trackpadMode, !strokes.isEmpty else { return }; strokes[strokes.count - 1].append(point(event)); needsDisplay = true }
}

