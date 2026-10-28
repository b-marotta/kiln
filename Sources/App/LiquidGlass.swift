import AppKit
import CoreText

/// Liquid Glass (`NSGlassEffectView`, style regular) when the runtime has it (macOS 26+),
/// otherwise `NSVisualEffectView` HUD blur. Compiled against older SDKs via runtime class lookup.
/// Style clear is the milky one: in Dark Mode it blurs harder and lays a white face behind the lens.
enum LiquidGlass {
    // One appearance and one glass face for every surface (panel, button, chip, bar).
    // Selection is a small lift of the same material — never a second color family.
    static let controlAppearance = NSAppearance(named: .darkAqua)
    /// Shared face for boxes, buttons, chips, and the section bar.
    /// Mid density: readable on white wallpaper without going charcoal.
    static let surfaceTint = NSColor(calibratedWhite: 0.12, alpha: 0.58)
    /// Selected chip and section switch bubble. Same family as surfaceTint, slightly lifted.
    static let selectedTint = NSColor(calibratedWhite: 0.40, alpha: 0.42)
    /// Text on glass. Explicit whites — semantic label colors wash out on light refraction.
    static let primaryText = NSColor.white.withAlphaComponent(0.96)
    static let secondaryText = NSColor.white.withAlphaComponent(0.80)
    static let rimStroke = NSColor.white.withAlphaComponent(0.28)
    /// Momentary press flash. Translucent so light wallpapers do not go blank.
    static let pressFill = NSColor.white.withAlphaComponent(0.45)

    /// Kept as aliases so older call sites stay readable.
    static var selectionTint: NSColor { selectedTint }
    static var emphasisTint: NSColor { selectedTint }

    static var isLiquidGlassAvailable: Bool {
        NSClassFromString("NSGlassEffectView") != nil
    }

    /// Backdrop suitable for masking (ring) or circular hub.
    static func makeBackdrop(frame: NSRect, cornerRadius: CGFloat, interactive: Bool = false, refractive: Bool = true) -> NSView {
        let glass: NSView
        if refractive, let liquid = makeLiquidGlassView(frame: frame, cornerRadius: cornerRadius) {
            if liquid.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
                liquid.setValue(interactive, forKey: "effectIsInteractive")
            }
            glass = liquid
        } else {
            glass = fallback(frame: frame, cornerRadius: cornerRadius)
        }
        guard cornerRadius > 0 else { return glass }
        let host = NSView(frame: frame)
        glass.frame = host.bounds
        glass.autoresizingMask = [.width, .height]
        host.addSubview(glass)
        addRim(to: host, radius: cornerRadius)
        return host
    }

    /// Place wrapped glass in `parent` at an explicit frame. Shared by shelf and editors.
    @discardableResult
    static func place(
        _ content: NSView,
        in parent: NSView,
        frame: NSRect,
        cornerRadius: CGFloat,
        interactive: Bool = false
    ) -> NSView {
        let glass = wrap(content: content, cornerRadius: cornerRadius, interactive: interactive)
        glass.frame = frame
        glass.autoresizingMask = []
        parent.addSubview(glass)
        return glass
    }

    /// Borderless control inside a glass capsule (buttons, popups, fields).
    @discardableResult
    static func placeControl(
        _ control: NSView,
        in parent: NSView,
        frame: NSRect,
        horizontalPadding: CGFloat = 0,
        verticalPadding: CGFloat = 0,
        interactive: Bool = true
    ) -> NSView {
        let host = GlassContentView(frame: NSRect(origin: .zero, size: frame.size))
        control.frame = host.bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        if let button = control as? NSButton { button.isBordered = false }
        host.addSubview(control)
        return place(host, in: parent, frame: frame, cornerRadius: min(24, frame.height / 2), interactive: interactive)
    }

    /// Update glass tint. Falls back to a light veil on HUD blur when tintColor is unavailable.
    static func setTint(_ tint: NSColor, on glass: NSView) {
        let surface = glassSurface(of: glass)
        if surface.responds(to: NSSelectorFromString("setTintColor:")) {
            surface.setValue(tint, forKey: "tintColor")
            setFallbackVeil(nil, on: surface)
            return
        }
        setFallbackVeil(tint, on: surface)
    }

    static func setSelected(_ selected: Bool, on glass: NSView) {
        setTint(selected ? selectedTint : surfaceTint, on: glass)
    }

    /// Embed `content` in glass (Apple’s recommended pattern).
    static func wrap(content: NSView, cornerRadius: CGFloat, interactive: Bool = false) -> NSView {
        // A borderless NSButton can hit-test only its title/image. Route the entire
        // visible glass surface to the same button, keeping native tracking and disabled behavior.
        content.appearance = controlAppearance
        prepareTree(content)
        // Popups inherit NSButton, but must retain the padding supplied by placeControl.
        let containsSingleButton = content.subviews.count == 1
            && content.subviews.first is NSButton
            && !(content.subviews.first is NSPopUpButton)
        if containsSingleButton, let button = content.subviews.first as? NSButton {
            button.frame = content.bounds
            button.autoresizingMask = [.width, .height]
            let hitArea = GlassButtonHitArea(button: button, cornerRadius: cornerRadius)
            hitArea.frame = content.bounds
            hitArea.autoresizingMask = [.width, .height]
            content.addSubview(hitArea)
        }
        if let glass = makeLiquidGlassView(frame: content.bounds, cornerRadius: cornerRadius) {
            if glass.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
                glass.setValue(interactive, forKey: "effectIsInteractive")
            }
            content.translatesAutoresizingMaskIntoConstraints = true
            content.autoresizingMask = [.width, .height]
            content.frame = glass.bounds
            glass.setValue(content, forKey: "contentView")
            addRim(to: content, radius: cornerRadius)
            return containsSingleButton ? GlassButtonSurface(glass: glass, cornerRadius: cornerRadius) : glass
        }
        let ve = fallback(frame: content.frame, cornerRadius: cornerRadius)
        content.frame = ve.bounds
        content.autoresizingMask = [.width, .height]
        ve.addSubview(content)
        // Pin a dark veil under HUD blur so white desktops do not bleach the face.
        setFallbackVeil(surfaceTint, on: ve)
        addRim(to: content, radius: cornerRadius)
        return containsSingleButton ? GlassButtonSurface(glass: ve, cornerRadius: cornerRadius) : ve
    }

    /// Keep text and controls readable on the shared dark glass face.
    /// Call again after adding labels into an already-wrapped surface.
    static func prepareTree(_ root: NSView) {
        root.appearance = controlAppearance
        if let field = root as? NSTextField {
            if field.textColor == nil || field.textColor == .labelColor {
                field.textColor = primaryText
            } else if field.textColor == .secondaryLabelColor {
                field.textColor = secondaryText
            }
        } else if let popup = root as? NSPopUpButton {
            popup.appearance = controlAppearance
            popup.isBordered = false
        } else if let button = root as? NSButton {
            button.appearance = controlAppearance
            if button.contentTintColor == nil || button.contentTintColor == .labelColor {
                button.contentTintColor = primaryText
            }
        }
        for child in root.subviews { prepareTree(child) }
    }

    /// Keeps the light edge in step with the glass corner while the pill grows and shrinks.
    static func setEdgeRadius(_ radius: CGFloat, on glass: NSView) {
        let surface = glassSurface(of: glass)
        let host = (surface.value(forKey: "contentView") as? NSView) ?? surface
        for case let rim as GlassRim in host.subviews {
            rim.radius = radius
        }
    }

    static func glassSurface(of view: NSView) -> NSView {
        (view as? GlassButtonSurface)?.glass ?? view
    }

    private static func addRim(to host: NSView, radius: CGFloat) {
        let rim = GlassRim(radius: radius)
        rim.frame = host.bounds
        rim.autoresizingMask = [.width, .height]
        host.addSubview(rim)
    }

    private static func setFallbackVeil(_ tint: NSColor?, on surface: NSView) {
        let host = (surface.value(forKey: "contentView") as? NSView)
            ?? surface.subviews.first
            ?? surface
        for case let veil as GlassFallbackVeil in host.subviews {
            veil.removeFromSuperview()
        }
        guard let tint else { return }
        let veil = GlassFallbackVeil(frame: host.bounds)
        veil.autoresizingMask = [.width, .height]
        veil.wantsLayer = true
        veil.layer?.backgroundColor = tint.cgColor
        host.addSubview(veil, positioned: .below, relativeTo: host.subviews.first)
    }

    private static func makeLiquidGlassView(frame: NSRect, cornerRadius: CGFloat) -> NSView? {
        guard let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type else { return nil }
        let view = cls.init(frame: frame)
        view.appearance = controlAppearance
        if view.responds(to: NSSelectorFromString("setTintColor:")) {
            view.setValue(surfaceTint, forKey: "tintColor")
        }
        view.autoresizingMask = [.width, .height]
        if view.responds(to: NSSelectorFromString("setCornerRadius:")) {
            view.setValue(cornerRadius, forKey: "cornerRadius")
        }
        if view.responds(to: NSSelectorFromString("setStyle:")) {
            // NSGlassEffectView.Style.regular. Clear (1) adds the white blur plate.
            // Do not set wantsLayer: the view draws its own refraction.
            view.setValue(0, forKey: "style")
        }
        if view.responds(to: NSSelectorFromString("setClipsToBounds:")) {
            // The regular material also casts a soft black shadow outside the shape.
            // Left unclipped, those shadows stack into one dark halo behind the UI.
            view.setValue(true, forKey: "clipsToBounds")
        }
        return view
    }

    private static func fallback(frame: NSRect, cornerRadius: CGFloat) -> NSVisualEffectView {
        let ve = NSVisualEffectView(frame: frame)
        ve.appearance = controlAppearance
        ve.material = .hudWindow
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = cornerRadius
        ve.layer?.masksToBounds = true
        return ve
    }
}

/// Flipped host shared by shelf chips and editor controls.
final class GlassContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class GlassFallbackVeil: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Light hairline inside the glass shape. It does not take clicks, and it is not the glass view's own layer.
final class GlassRim: NSView {
    var radius: CGFloat {
        didSet { needsDisplay = true }
    }

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard inset.width > 1, inset.height > 1 else { return }
        let curve = min(radius, min(inset.width, inset.height) / 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: curve, yRadius: curve)
        LiquidGlass.rimStroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Reject corners before AppKit can fall through to the rectangular native button.
private final class GlassButtonSurface: NSView {
    let glass: NSView
    private let cornerRadius: CGFloat

    init(glass: NSView, cornerRadius: CGFloat) {
        self.glass = glass
        self.cornerRadius = cornerRadius
        super.init(frame: glass.frame)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        guard NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Hit-testing proxy for a glass surface that contains exactly one button.
private final class GlassButtonHitArea: NSView {
    private weak var button: NSButton?
    private let cornerRadius: CGFloat

    init(button: NSButton, cornerRadius: CGFloat) {
        self.button = button
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let button, !button.isHidden else { return nil }
        let local = convert(point, from: superview)
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        guard NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).contains(local) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard let button else { return }
        GlassButtonPressFeedback.track(button) { button.mouseDown(with: event) }
    }
}

/// Momentary feedback shared by native buttons and shelf buttons; native tracking still owns activation.
enum GlassButtonPressFeedback {
    private static var tracking: Set<ObjectIdentifier> = []

    static func track(_ button: NSButton, perform: () -> Void) {
        guard button.isEnabled else { return }
        if let glassButton = button as? GlassCenteredIconButton, !glassButton.usesGlassPressFeedback {
            perform()
            return
        }
        let identifier = ObjectIdentifier(button)
        guard !tracking.contains(identifier) else { perform(); return }
        tracking.insert(identifier)
        // Icon chips: same press fill as text buttons, but never flip the glyph to black
        // (black-on-dark glass reads as a broken control). Skip button.layer — that resizes tiny pills.
        if let glassButton = button as? GlassCenteredIconButton, glassButton.fixedIconSize != nil {
            let background = GlassPressedBackground(frame: button.frame)
            background.wantsLayer = true
            background.layer?.backgroundColor = LiquidGlass.pressFill.cgColor
            background.layer?.cornerRadius = min(22, min(button.bounds.width, button.bounds.height) / 2)
            button.superview?.addSubview(background, positioned: .below, relativeTo: button)
            button.window?.displayIfNeeded()
            defer {
                background.removeFromSuperview()
                tracking.remove(identifier)
                button.needsDisplay = true
            }
            perform()
            return
        }
        let originalAppearance = button.appearance
        let originalBackground = button.layer?.backgroundColor
        let originalTint = button.contentTintColor
        let originalTitle = button.attributedTitle
        let originalString = button.title
        let originalHighlights = (button.cell as? NSButtonCell)?.highlightsBy
        let background = GlassPressedBackground(frame: button.frame)
        background.wantsLayer = true
        background.layer?.backgroundColor = LiquidGlass.pressFill.cgColor
        background.layer?.cornerRadius = min(22, min(button.bounds.width, button.bounds.height) / 2)
        button.superview?.addSubview(background, positioned: .below, relativeTo: button)
        button.layer?.backgroundColor = LiquidGlass.pressFill.cgColor
        button.appearance = NSAppearance(named: .aqua)
        button.contentTintColor = .black
        let title = NSMutableAttributedString(attributedString: button.attributedTitle)
        title.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
        (button.cell as? NSButtonCell)?.highlightsBy = []
        button.window?.displayIfNeeded()
        defer {
            background.removeFromSuperview()
            button.layer?.backgroundColor = originalBackground
            button.appearance = originalAppearance
            button.contentTintColor = originalTint
            if let originalHighlights { (button.cell as? NSButtonCell)?.highlightsBy = originalHighlights }
            // Actions may change the label (for example Play -> Pause) during mouse-up.
            if button.title == originalString { button.attributedTitle = originalTitle }
            else {
                let title = NSMutableAttributedString(attributedString: button.attributedTitle)
                let color = originalTitle.length > 0 ? (originalTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .labelColor) : .labelColor
                title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
                button.attributedTitle = title
            }
            (button as? GlassCenteredIconButton)?.refreshGlassAppearance()
            tracking.remove(identifier)
            button.needsDisplay = true
        }
        perform()
    }
}

private final class GlassPressedBackground: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Center visible glyphs and symbols, and center icon/title groups as a single unit.
class GlassCenteredIconButton: NSButton {
    var usesGlassPressFeedback = true
    var fixedIconSize: NSSize?
    func refreshGlassAppearance() {}
    private static let visibleBoundsCache = NSCache<NSImage, NSValue>()

    private static func visibleBounds(of image: NSImage) -> NSRect {
        if let cached = visibleBoundsCache.object(forKey: image) { return cached.rectValue }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return proposed }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return proposed }
        let sx = image.size.width / CGFloat(bitmap.pixelsWide)
        let sy = image.size.height / CGFloat(bitmap.pixelsHigh)
        let rect = NSRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                          width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
        visibleBoundsCache.setObject(NSValue(rect: rect), forKey: image)
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        let supported: [NSControl.ImagePosition] = [.noImage, .imageOnly, .imageLeading, .imageTrailing, .imageLeft, .imageRight]
        guard !isBordered, supported.contains(imagePosition), let ctx = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }
        let color = contentTintColor ?? .labelColor
        let icon = imagePosition == .noImage ? nil : image
        let visible = icon.map { Self.visibleBounds(of: $0) } ?? .zero
        let availableIconSize = fixedIconSize ?? NSSize(width: max(1, bounds.width - 12), height: max(1, bounds.height - 12))
        let iconScale = min(fixedIconSize == nil ? 1 : CGFloat.greatestFiniteMagnitude, min(availableIconSize.width / max(1, visible.width), availableIconSize.height / max(1, visible.height)))
        let iconWidth = icon == nil ? 0 : visible.width * iconScale
        let hasText = imagePosition != .imageOnly && !title.isEmpty
        let gap: CGFloat = icon != nil && hasText ? 6 : 0
        var textLine: CTLine?
        var textBounds = NSRect.zero
        if hasText {
            let font = self.font ?? NSFont.systemFont(ofSize: 13)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attrs))
            let available = max(1, bounds.width - 24 - iconWidth - gap)
            if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(available) {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                line = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) ?? ellipsis
            }
            textBounds = CTLineGetImageBounds(line, nil)
            if textBounds.isNull || textBounds.isEmpty { textBounds = .zero }
            textLine = line
        }
        let groupWidth = iconWidth + gap + textBounds.width
        let left = bounds.midX - groupWidth / 2
        let trailing = [.imageTrailing, .imageRight].contains(imagePosition)
        let iconOnRight = (imagePosition == .imageLeading || imagePosition == .imageTrailing)
            && userInterfaceLayoutDirection == .rightToLeft ? !trailing : trailing
        let iconX = iconOnRight ? left + textBounds.width + gap : left
        let textX = icon != nil && !iconOnRight ? left + iconWidth + gap : left
        ctx.saveGState()
        ctx.setAlpha(isEnabled ? 1 : 0.35)
        if let icon, icon.size.width > 0, icon.size.height > 0 {
            let centerY = isFlipped ? visible.midY : icon.size.height - visible.midY
            let rect = NSRect(x: iconX - visible.minX * iconScale,
                              y: bounds.midY - centerY * iconScale,
                              width: icon.size.width * iconScale, height: icon.size.height * iconScale)
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let textLine {
            ctx.textMatrix = .identity
            ctx.translateBy(x: textX - textBounds.minX, y: bounds.midY)
            if isFlipped { ctx.scaleBy(x: 1, y: -1) }
            ctx.textPosition = NSPoint(x: 0, y: -textBounds.midY)
            CTLineDraw(textLine, ctx)
        }
        ctx.restoreGState()
    }
}

/// Keep the text cursor explicit inside glass containers, including selectable OCR output.
final class GlassTextView: NSTextView {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEditable || isSelectable { addCursorRect(visibleRect, cursor: .iBeam) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEditable || isSelectable { NSCursor.iBeam.set() }
        else { super.cursorUpdate(with: event) }
    }
}
