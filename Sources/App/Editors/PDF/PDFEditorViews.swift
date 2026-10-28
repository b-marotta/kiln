import AppKit
import PDFKit
import UniformTypeIdentifiers

final class PDFEditorContentView: NSView {
    override var isFlipped: Bool { true }
}

final class PDFCenteredTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = PDFCenteredTextFieldCell(textCell: "")
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PDFCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        result.origin.y += max(0, (result.height - height) / 2)
        result.size.height = min(result.height, height)
        return result
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

/// The selected page stays visibly marked even when another editor control has keyboard focus.
final class PDFThumbnailRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

/// Capture feedback is decorative, so it never steals the touch target from the signature canvas.
final class SignatureCaptureStatusView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Viewport overlay stays anchored while the document scrolls underneath it.
final class PDFPreviewSurface: NSView {
    private let page: NSView
    private let floatingControls: NSView
    override var isFlipped: Bool { true }

    init(page: NSView, floatingControls: NSView) {
        self.page = page
        self.floatingControls = floatingControls
        super.init(frame: .zero)
        addSubview(page)
        addSubview(floatingControls)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); positionContents() }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        positionContents()
    }
    private func positionContents() {
        page.frame = bounds
        floatingControls.setFrameOrigin(NSPoint(x: max(12, bounds.width - floatingControls.frame.width - 12), y: max(12, bounds.height - floatingControls.frame.height - 12)))
    }
}

/// Gaps between floating buttons remain available for placing a signature on the page.
final class PDFPreviewControlsView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
