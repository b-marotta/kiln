import AppKit
import AVFoundation
import Carbon.HIToolbox

final class AudioEditorContentView: NSView {
    override var isFlipped: Bool { true }
}

/// Borderless fields draw text high in a tall frame; recenter for display and edit.
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    private func centeredRect(for rect: NSRect) -> NSRect {
        var title = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        let delta = title.height - height
        if delta > 0 {
            title.origin.y += floor(delta / 2)
            title.size.height = height
        }
        return title
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredRect(for: rect) }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, start selStart: Int, length selLength: Int
    ) {
        super.select(
            withFrame: centeredRect(for: rect), in: controlView, editor: textObj,
            delegate: delegate, start: selStart, length: selLength
        )
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
        delegate: Any?, event: NSEvent?
    ) {
        super.edit(
            withFrame: centeredRect(for: rect), in: controlView, editor: textObj,
            delegate: delegate, event: event
        )
    }
}

