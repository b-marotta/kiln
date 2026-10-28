import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

/// Selection lens for the three sections. The drag is ours: macOS has no
/// iPhone-style floating tab bar, so the glass pill follows the pointer,
/// rubber-bands past the capsule, and springs back to the nearest section.
final class GlassSectionSelector: NSView {
    var onSelect: ((FanMode) -> Void)?
    private let modes: [(FanMode, String, String)] = [
        (.convert, "Conversioni", "arrow.triangle.2.circlepath"),
        (.fileActions, "Azioni", "bolt"),
        (.fileTools, "Tool", "wrench.and.screwdriver")
    ]
    private let enabledModes: Set<FanMode>
    private let pill: NSView
    private var buttons: [ShelfButton] = []
    private var selectedMode: FanMode
    private var pressedIndex: Int?
    private var trackingCenterX: CGFloat?
    private var trackingCenterY: CGFloat?
    private var pointerOffsetX: CGFloat = 0
    private var pointerOffsetY: CGFloat = 0
    private var laidOutWidth: CGFloat = -1
    private var catchDuration: CGFloat = 0.28
    private var catchUntil: TimeInterval = 0
    private var pillShapeGeneration = 0
    private var aimX: CGFloat?
    private var aimY: CGFloat?
    private var followTimer: Timer?
    private var followStamp: TimeInterval = 0
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    init(frame: NSRect, selectedMode: FanMode, enabledModes: Set<FanMode>) {
        self.selectedMode = selectedMode
        self.enabledModes = enabledModes
        let content = ShelfContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        pill = LiquidGlass.wrap(content: content, cornerRadius: 20, interactive: true)
        LiquidGlass.setTint(LiquidGlass.selectedTint, on: pill)
        pill.alphaValue = 1
        super.init(frame: frame)
        pill.autoresizingMask = []
        addSubview(pill)
        for entry in modes {
            let button = ShelfButton(title: entry.1, symbol: entry.2) { [weak self] in
                self?.commit(entry.0)
            }
            button.usesSectionSelectionBubble = true
            (button.cell as? NSButtonCell)?.highlightsBy = []
            // Keep the original mouse-down view as the event recipient while
            // forwarding its whole gesture to the shared selector.
            button.onPointerEvent = { [weak self] event in self?.trackPointer(event) }
            addSubview(button)
            buttons.append(button)
        }
        updateSelection(animated: false)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    deinit { followTimer?.invalidate() }

    override func layout() {
        super.layout()
        let widthChanged = abs(bounds.width - laidOutWidth) > 0.5
        guard widthChanged else { return }
        laidOutWidth = bounds.width
        updateSelection(animated: false)
    }

    /// The glass draws over the titles. Clicks on that glass, not only the glyphs,
    /// belong to the section row. Otherwise they land on an action and close the shelf.
    func claims(_ local: NSPoint) -> Bool {
        bounds.contains(local) || pill.frame.insetBy(dx: -4, dy: -4).contains(local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        claims(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { trackPointer(event) }
    override func mouseDragged(with event: NSEvent) { trackPointer(event) }
    override func mouseUp(with event: NSEvent) { trackPointer(event) }

    private func trackPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown: beginSelection(at: point)
        case .leftMouseDragged: continueSelection(at: point)
        case .leftMouseUp:
            if window?.isVisible == true { finishSelection(at: point) } else { cancelSelection() }
        default: break
        }
    }

    private func index(at point: NSPoint) -> Int {
        let width = max(1, (bounds.width - 12) / 3)
        return min(modes.count - 1, max(0, Int(floor((point.x - 6) / width))))
    }

    private func beginSelection(at point: NSPoint) {
        guard claims(point) else { return }
        let pillHit = pill.frame.insetBy(dx: -2, dy: -2)
        if pillHit.contains(point) {
            let centerX = pill.frame.midX
            let centerY = pill.frame.midY
            trackingCenterX = centerX
            trackingCenterY = centerY
            pointerOffsetX = point.x - centerX
            pointerOffsetY = point.y - centerY
            catchDuration = 0.16
            catchUntil = 0
        } else {
            guard bounds.contains(point), isEnabled(index(at: point)) else { return }
            pointerOffsetX = 0
            pointerOffsetY = 0
            let minX = restCenterX(for: 0)
            let maxX = restCenterX(for: modes.count - 1)
            trackingCenterX = rubberBand(point.x, min: minX, max: maxX, limit: 28)
            trackingCenterY = verticalCenter(for: point.y)
            let travel = abs((trackingCenterX ?? pill.frame.midX) - pill.frame.midX)
            catchDuration = min(0.16, max(0.24, travel / 1100))
            catchUntil = CACurrentMediaTime() + catchDuration
        }
        pressedIndex = index(at: point)
        updateSelection(animated: true)
    }

    private func continueSelection(at point: NSPoint) {
        guard pressedIndex != nil, CACurrentMediaTime() >= catchUntil else { return }
        pressedIndex = index(at: point)
        let minX = restCenterX(for: 0)
        let maxX = restCenterX(for: modes.count - 1)
        let x = rubberBand(point.x - pointerOffsetX, min: minX, max: maxX, limit: 28)
        let y = verticalCenter(for: point.y - pointerOffsetY)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            trackingCenterX = x
            trackingCenterY = y
            updateSelection(animated: false)
            return
        }
        followPointer(x: x, y: y)
    }

    /// The pill eases toward the pointer instead of sticking to it.
    private func followPointer(x: CGFloat, y: CGFloat) {
        aimX = x
        aimY = y
        guard followTimer == nil else { return }
        followStamp = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepFollow()
        }
        followTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepFollow() {
        guard pressedIndex != nil, let aimX, let aimY else {
            stopFollow()
            return
        }
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - followStamp)
        followStamp = now
        let currentX = trackingCenterX ?? aimX
        let currentY = trackingCenterY ?? aimY
        let blend = 1 - exp(-dt / 0.11)
        let nextX = currentX + (aimX - currentX) * blend
        let nextY = currentY + (aimY - currentY) * blend
        trackingCenterX = nextX
        trackingCenterY = nextY
        updateSelection(animated: false)
        if abs(nextX - aimX) < 0.4, abs(nextY - aimY) < 0.4 {
            trackingCenterX = aimX
            trackingCenterY = aimY
            updateSelection(animated: false)
            stopFollow()
        }
    }

    private func stopFollow() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func finishSelection(at point: NSPoint) {
        guard pressedIndex != nil else { return }
        commit(modes[enabledIndex(nearestTo: point)].0)
    }

    private func isEnabled(_ index: Int) -> Bool {
        enabledModes.contains(modes[index].0)
    }

    /// A section with no actions cannot be chosen. Release lands on the nearest one that can.
    private func enabledIndex(nearestTo point: NSPoint) -> Int {
        let raw = index(at: point)
        if isEnabled(raw) { return raw }
        let enabled = modes.indices.filter(isEnabled)
        return enabled.min { lhs, rhs in
            let ld = abs(lhs - raw)
            let rd = abs(rhs - raw)
            return ld == rd ? lhs < rhs : ld < rd
        } ?? raw
    }

    private func cancelSelection() {
        stopFollow()
        pressedIndex = nil
        trackingCenterX = nil
        trackingCenterY = nil
        updateSelection(animated: true)
    }

    private var restCenterY: CGFloat { 26 }

    private func restCenterX(for index: Int) -> CGFloat {
        6 + (CGFloat(index) + 0.5) * ((bounds.width - 12) / 3)
    }

    /// Vertical travel is almost locked. A long drag only shifts the pill a few points.
    private func verticalCenter(for proposed: CGFloat) -> CGFloat {
        rubberBand(proposed, min: restCenterY, max: restCenterY, limit: 3.5, coeff: 0.12)
    }

    /// Past the ends the pill keeps moving, but each extra point costs more.
    private func rubberBand(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat, limit: CGFloat, coeff: CGFloat = 0.55) -> CGFloat {
        if value < minValue { return minValue - damp(minValue - value, limit: limit, coeff: coeff) }
        if value > maxValue { return maxValue + damp(value - maxValue, limit: limit, coeff: coeff) }
        return value
    }

    private func damp(_ distance: CGFloat, limit: CGFloat, coeff: CGFloat) -> CGFloat {
        (1 - (1 / ((distance * coeff / limit) + 1))) * limit
    }

    private func commit(_ mode: FanMode) {
        guard enabledModes.contains(mode) else {
            cancelSelection()
            return
        }
        let changed = selectedMode != mode
        selectedMode = mode
        cancelSelection()
        if changed { onSelect?(mode) }
    }

    private func updateSelection(animated: Bool) {
        let segmentWidth = (bounds.width - 12) / 3
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 6 + CGFloat(index) * segmentWidth, y: 6, width: segmentWidth, height: 40)
            button.sectionEnabled = isEnabled(index)
            button.selected = pressedIndex.map { $0 == index && isEnabled(index) } ?? (modes[index].0 == selectedMode)
            button.setAccessibilityValue(modes[index].0 == selectedMode ? "Selected" : "")
        }
        let index = pressedIndex ?? modes.firstIndex(where: { $0.0 == selectedMode }) ?? 0
        var width = segmentWidth
        var height: CGFloat = 40
        var originX = 6 + CGFloat(index) * segmentWidth
        var originY: CGFloat = 6
        if let trackingCenterX { originX = trackingCenterX - segmentWidth / 2 }
        if let trackingCenterY { originY = trackingCenterY - 20 }
        if pressedIndex != nil {
            let minX = 6 + segmentWidth / 2
            let maxX = 6 + (CGFloat(modes.count) - 0.5) * segmentWidth
            let centerX = trackingCenterX ?? (originX + segmentWidth / 2)
            let past = max(0, minX - centerX) + max(0, centerX - maxX)
            let stretch = min(16, past * 0.45)
            let growX: CGFloat = 20 + stretch
            let growY: CGFloat = 20
            width += growX
            height += growY
            originX -= growX / 2
            originY -= growY / 2
        }
        let destination = NSRect(x: originX, y: originY, width: width, height: height)
        pillShapeGeneration += 1
        let shapeGeneration = pillShapeGeneration
        let destinationRadius = height / 2
        // The frame animates. The radius must stay half of the larger height, or the ends look square until the size catches up.
        let radiusDuringTravel = max(pill.frame.height, height) / 2
        let animate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setPillRadius(animate ? radiusDuringTravel : destinationRadius)
        if animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = pressedIndex == nil ? 0.46 : catchDuration
                context.timingFunction = pressedIndex == nil
                    ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.05)
                    : CAMediaTimingFunction(name: .easeInEaseOut)
                pill.animator().frame = destination
            }, completionHandler: { [weak self] in
                guard let self, shapeGeneration == self.pillShapeGeneration else { return }
                self.setPillRadius(destinationRadius)
            })
        } else {
            pill.frame = destination
        }
    }

    private func setPillRadius(_ radius: CGFloat) {
        guard pill.responds(to: NSSelectorFromString("setCornerRadius:")) else { return }
        pill.setValue(radius, forKey: "cornerRadius")
        LiquidGlass.setEdgeRadius(radius, on: pill)
    }
}
