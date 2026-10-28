import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

final class ShelfButton: GlassCenteredIconButton {
    private var handler: () -> Void
    var selected = false { didSet { updateAppearance() } }
    var usesSectionSelectionBubble = false { didSet { updateAppearance() } }
    var sectionEnabled = true { didSet { updateAppearance() } }
    var onPointerEvent: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) {
        if let onPointerEvent { onPointerEvent(event) }
        else { GlassButtonPressFeedback.track(self) { super.mouseDown(with: event) } }
    }
    override func mouseDragged(with event: NSEvent) {
        if let onPointerEvent { onPointerEvent(event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if let onPointerEvent { onPointerEvent(event) } else { super.mouseUp(with: event) }
    }
    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        alignment = .center
        font = .systemFont(ofSize: 13, weight: .semibold)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        wantsLayer = true
        target = self
        action = #selector(invoke)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }
    override func refreshGlassAppearance() { updateAppearance() }

    private func updateAppearance() {
        layer?.cornerRadius = 20
        // Selection belongs to the glass tint (AudioActionButton / section pill), never a solid fill.
        layer?.backgroundColor = nil
        alphaValue = sectionEnabled ? 1 : 0.35
        let textColor = LiquidGlass.primaryText
        contentTintColor = textColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: textColor
        ])
    }
    @objc private func invoke() { handler() }
}

/// One glass surface; selection is a tint lift on that same glass, never a solid white plate.
final class AudioActionButton: NSView {
    private let button: ShelfButton
    private let glass: NSView

    init(frame: NSRect, title: String, handler: @escaping () -> Void) {
        let content = ShelfContentView(frame: NSRect(origin: .zero, size: frame.size))
        button = ShelfButton(title: title, handler: handler)
        button.frame = content.bounds
        content.addSubview(button)
        glass = LiquidGlass.wrap(content: content, cornerRadius: 22, interactive: true)
        super.init(frame: frame)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        (button.cell as? NSButtonCell)?.highlightsBy = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool, animated _: Bool) {
        button.selected = selected
        button.state = selected ? .on : .off
        button.setAccessibilityValue(selected ? "Selected" : "")
        LiquidGlass.setSelected(selected, on: glass)
    }
}


