import AppKit
import CoreText
import AudioToolbox
import Carbon.HIToolbox
import QuartzCore

// MARK: - Unsupported banner

final class UnsupportedBannerView: NSView {
    var mode: FanMode = .convert {
        didSet { chrome.mode = mode; chrome.needsDisplay = true }
    }
    var onCancel: (() -> Void)?
    private let chrome = UnsupportedBannerChrome()
    private let glass: NSView

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        chrome.frame = NSRect(origin: .zero, size: frameRect.size)
        chrome.mode = .convert
        glass = LiquidGlass.wrap(content: chrome, cornerRadius: 14)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class UnsupportedBannerChrome: NSView {
    var mode: FanMode = .convert

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let title = "Unsupported file type"
        let subtitle = "\(mode.shortcutHint) \(mode.title)"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65)
        ]
        let ts = title.size(withAttributes: titleAttrs)
        let ss = subtitle.size(withAttributes: subAttrs)
        title.draw(
            at: NSPoint(x: (bounds.width - ts.width) / 2, y: bounds.midY + 2),
            withAttributes: titleAttrs
        )
        subtitle.draw(
            at: NSPoint(x: (bounds.width - ss.width) / 2, y: bounds.midY - ss.height - 2),
            withAttributes: subAttrs
        )
    }
}

