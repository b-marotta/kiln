import AppKit
import CoreText
import AudioToolbox
import Carbon.HIToolbox
import QuartzCore

// MARK: - Radial view

final class RadialFanView: NSView {
    var actions: [FanAction] = [] {
        didSet { petals.actions = actions; petals.needsDisplay = true; syncHubChrome() }
    }
    var mode: FanMode = .convert {
        didSet { petals.mode = mode; petals.needsDisplay = true; syncHubChrome() }
    }
    var fileLabel: String = "" {
        didSet { petals.fileLabel = fileLabel; syncHubChrome() }
    }
    var onSelect: ((FanAction) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var highlightedIndex: Int? {
        didSet {
            petals.highlightedIndex = highlightedIndex
            petals.needsDisplay = true
            syncHubChrome()
            if let highlightedIndex, highlightedIndex != oldValue {
                Self.playPetalHoverSound()
            }
        }
    }

    /// Overlapping soft ticks — new instance each time so skim never waits on the previous note.
    private static var hoverSounds: [NSSound] = []
    private static let hoverPrototype: NSSound? = {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "mouseclick1", withExtension: "caf"),
            Bundle.main.resourceURL?.appendingPathComponent("mouseclick1.caf")
        ]
        for url in candidates.compactMap({ $0 }) {
            if let s = NSSound(contentsOf: url, byReference: true) { return s }
        }
        return NSSound(named: "Bottle")
    }()

    private static func playPetalHoverSound() {
        hoverSounds.removeAll { !$0.isPlaying }
        // Fresh copy: one shared NSSound refuses to re-trigger until finished.
        if let proto = hoverPrototype, let tick = proto.copy() as? NSSound {
            tick.volume = 0.22
            hoverSounds.append(tick)
            tick.play()
            return
        }
        AudioServicesPlaySystemSound(1104)
    }
    var highlightedAction: FanAction? {
        guard let highlightedIndex, actions.indices.contains(highlightedIndex) else { return nil }
        return actions[highlightedIndex]
    }

    /// Glass ring (underlay) extents as fraction of half-size.
    private let ringInnerRatio: CGFloat = 0.30
    private let ringOuterRatio: CGFloat = 0.88
    /// Shared spacing: between wedges and from wedges to glass rim.
    private let petalGap: CGFloat = 5
    private let ringGlass: NSView
    private let ringMask = CAShapeLayer()
    private let hubGlass: NSView
    private let hubChrome = FanHubChromeView()
    private let petals = FanPetalsView()

    override var isFlipped: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        // Liquid Glass when available (macOS 26+ runtime); else HUD visual effect.
        ringGlass = LiquidGlass.makeBackdrop(frame: frameRect, cornerRadius: 0)
        // Hub chrome embedded as contentView when Liquid Glass exists.
        hubGlass = LiquidGlass.wrap(content: hubChrome, cornerRadius: 40)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        ringGlass.frame = bounds
        ringGlass.autoresizingMask = [.width, .height]
        ringGlass.wantsLayer = true
        ringGlass.layer?.mask = ringMask
        addSubview(ringGlass)

        addSubview(hubGlass)

        petals.frame = bounds
        petals.autoresizingMask = [.width, .height]
        petals.ringInnerRatio = ringInnerRatio
        petals.ringOuterRatio = ringOuterRatio
        petals.gapPoints = petalGap
        addSubview(petals)
        syncHubChrome()
        updateGlassGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        ringGlass.frame = bounds
        petals.frame = bounds
        petals.ringInnerRatio = ringInnerRatio
        petals.ringOuterRatio = ringOuterRatio
        petals.gapPoints = petalGap
        updateGlassGeometry()
    }

    private func syncHubChrome() {
        hubChrome.mode = petals.mode
        hubChrome.fileLabel = petals.fileLabel
        if let idx = petals.highlightedIndex, petals.actions.indices.contains(idx) {
            hubChrome.highlightedAction = petals.actions[idx]
        } else {
            hubChrome.highlightedAction = nil
        }
        hubChrome.needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func petalRadii() -> (inner: CGFloat, outer: CGFloat) {
        let half = min(bounds.width, bounds.height) / 2
        let ringInner = half * ringInnerRatio
        let ringOuter = half * ringOuterRatio
        // Inset wedges from the blur rim by the same gap used between wedges.
        return (ringInner + petalGap, ringOuter - petalGap)
    }

    func containsScreenPoint(_ screen: NSPoint) -> Bool {
        guard let window else { return false }
        let win = window.convertPoint(fromScreen: screen)
        let local = convert(win, from: nil)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = hypot(local.x - c.x, local.y - c.y)
        let (_, outer) = petalRadii()
        return r <= outer
    }

    func updateHighlight(atScreen screen: NSPoint) {
        guard let window else { return }
        let win = window.convertPoint(fromScreen: screen)
        let local = convert(win, from: nil)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = hypot(local.x - c.x, local.y - c.y)
        let (inner, outer) = petalRadii()

        guard r >= inner * 0.5, r <= outer, !actions.isEmpty else {
            if highlightedIndex != nil { highlightedIndex = nil }
            return
        }

        // Angle: 0 = east, CCW; convert so 0 = north (top), clockwise for reading order.
        var angle = atan2(local.y - c.y, local.x - c.x)
        angle = (.pi / 2) - angle
        if angle < 0 { angle += 2 * .pi }

        let n = CGFloat(actions.count)
        let slice = (2 * .pi) / n
        var index = Int(angle / slice) % actions.count
        if index < 0 { index += actions.count }

        if highlightedIndex != index {
            highlightedIndex = index
        }
    }

    private func updateGlassGeometry() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let half = min(bounds.width, bounds.height) / 2
        let outer = half * ringOuterRatio
        let inner = half * ringInnerRatio

        // Donut mask for the ring overlay.
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        ringMask.frame = bounds
        ringMask.path = path
        ringMask.fillRule = .evenOdd

        // Circular hub glass in the hole.
        let hubSide = inner * 2
        hubGlass.frame = CGRect(x: c.x - inner, y: c.y - inner, width: hubSide, height: hubSide)
        if hubGlass.responds(to: NSSelectorFromString("setCornerRadius:")) {
            hubGlass.setValue(inner, forKey: "cornerRadius")
        } else {
            hubGlass.layer?.cornerRadius = inner
            hubGlass.layer?.masksToBounds = true
        }
        hubChrome.frame = CGRect(origin: .zero, size: CGSize(width: hubSide, height: hubSide))
        hubChrome.autoresizingMask = [.width, .height]
        // Keep contentView in sync if Liquid Glass owns the chrome.
        if hubGlass.responds(to: NSSelectorFromString("setContentView:")) {
            hubGlass.setValue(hubChrome, forKey: "contentView")
        }
    }
}

