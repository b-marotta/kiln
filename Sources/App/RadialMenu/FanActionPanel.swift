import AppKit
import CoreText
import AudioToolbox
import Carbon.HIToolbox
import QuartzCore

/// Radial glass-style fan centered on the cursor (Tangerine-like).
final class FanActionPanel: NSObject {
    private var panel: NSPanel?
    private var fanView: RadialFanView?
    private var urls: [URL] = []
    private var mode: FanMode = .convert
    private var centerScreen: NSPoint = .zero
    private var showingUnsupported = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    /// Bumps on every hide so a late dismiss animation cannot tear down a newer panel.
    private var hideGeneration = 0

    var onAction: ((FanAction, [URL]) -> Void)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    private let diameter: CGFloat = 280
    private let appearDuration: CFTimeInterval = 0.16
    private let dismissDuration: CFTimeInterval = 0.12
    private let appearScale: CGFloat = 0.94
    private let dismissScale: CGFloat = 0.96

    func present(urls: [URL], mode: FanMode, near screenPoint: NSPoint? = nil) {
        self.urls = urls
        self.mode = mode
        centerScreen = screenPoint ?? NSEvent.mouseLocation
        rebuild()
    }

    func updateMode(_ mode: FanMode) {
        guard !urls.isEmpty else { return }
        self.mode = mode
        rebuild(keepCenter: true)
    }

    func hide(animated: Bool = true) {
        removeMonitors()
        hideGeneration += 1
        let generation = hideGeneration

        guard animated,
              let panel,
              let content = panel.contentView,
              panel.isVisible
        else {
            tearDownPanel()
            return
        }

        panel.ignoresMouseEvents = true
        playMotion(
            on: content,
            fromOpacity: content.layer?.presentation()?.opacity ?? content.layer?.opacity ?? 1,
            toOpacity: 0,
            fromScale: 1,
            toScale: dismissScale,
            duration: dismissDuration,
            timing: .easeIn
        ) { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.tearDownPanel()
        }
    }

    private func tearDownPanel() {
        panel?.contentView?.layer?.removeAllAnimations()
        panel?.orderOut(nil)
        panel = nil
        fanView = nil
        showingUnsupported = false
    }

    private func rebuild(keepCenter: Bool = false) {
        let actions = ActionAvailability.actions(for: urls, mode: mode)
        let center = keepCenter ? centerScreen : (NSEvent.mouseLocation)
        if !keepCenter { centerScreen = center }
        hide(animated: false)

        if actions.isEmpty {
            presentUnsupportedBanner(at: center)
            return
        }

        let size = NSSize(width: diameter, height: diameter)
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = false

        let view = RadialFanView(frame: NSRect(origin: .zero, size: size))
        view.actions = actions
        view.mode = mode
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        view.fileLabel = urls.count == 1 ? names : "\(urls.count) file · \(names)"
        view.onSelect = { [weak self] action in
            guard let self else { return }
            let urls = self.urls
            self.hide(animated: true)
            self.onDismiss?()
            self.onAction?(action, urls)
        }
        view.onCancel = { [weak self] in
            self?.hide(animated: true)
            self?.onDismiss?()
        }
        panel.contentView = view

        self.panel = panel
        self.fanView = view
        showingUnsupported = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        installMonitors()
        view.updateHighlight(atScreen: NSEvent.mouseLocation)
        playAppear(on: view)
    }

    private func presentUnsupportedBanner(at center: NSPoint) {
        let size = NSSize(width: 260, height: 56)
        let origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let view = UnsupportedBannerView(frame: NSRect(origin: .zero, size: size))
        view.mode = mode
        view.onCancel = { [weak self] in
            self?.hide(animated: true)
            self?.onDismiss?()
        }
        panel.contentView = view

        self.panel = panel
        self.fanView = nil
        showingUnsupported = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        installMonitors()
        playAppear(on: view)
    }

    private func playAppear(on view: NSView) {
        playMotion(
            on: view,
            fromOpacity: 0,
            toOpacity: 1,
            fromScale: appearScale,
            toScale: 1,
            duration: appearDuration,
            timing: .easeOut,
            completion: nil
        )
    }

    private func playMotion(
        on view: NSView,
        fromOpacity: Float,
        toOpacity: Float,
        fromScale: CGFloat,
        toScale: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: (() -> Void)?
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else {
            completion?()
            return
        }

        // NSView-backed layers keep AppKit's anchor at (0,0). Changing anchorPoint
        // gets overwritten on layout and scales from bottom-left. Bake center into
        // the transform instead: translate → scale → translate back.
        let bounds = layer.bounds
        let fromTransform = Self.centeredScale(fromScale, in: bounds)
        let toTransform = Self.centeredScale(toScale, in: bounds)
        layer.removeAnimation(forKey: "fanMotion")

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = toOpacity

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: fromTransform)
        scale.toValue = NSValue(caTransform3D: toTransform)

        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: timing)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.opacity = toOpacity
        layer.transform = toTransform
        layer.add(group, forKey: "fanMotion")
        CATransaction.commit()
    }

    /// Scale around bounds center without touching `anchorPoint` (AppKit-owned).
    private static func centeredScale(_ scale: CGFloat, in bounds: CGRect) -> CATransform3D {
        let cx = bounds.midX
        let cy = bounds.midY
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, cx, cy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    private func installMonitors() {
        removeMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async { self?.handleMouse(event) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        ) { [weak self] event in
            self?.handleMouse(event)
            return event
        }

        // Panel is nonactivating → local Esc often never arrives; need global too.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.dismissFromEsc()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { self?.dismissFromEsc() }
            }
        }
    }

    private func dismissFromEsc() {
        guard isVisible else { return }
        hide()
        onDismiss?()
    }

    private func removeMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }

    private func handleMouse(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }
        let screen = NSEvent.mouseLocation

        if showingUnsupported {
            if event.type == .leftMouseDown || event.type == .leftMouseUp {
                let win = panel.convertPoint(fromScreen: screen)
                if !panel.contentView!.bounds.contains(win) {
                    hide()
                    onDismiss?()
                }
            }
            return
        }

        guard let fanView else { return }
        fanView.updateHighlight(atScreen: screen)

        switch event.type {
        case .leftMouseUp:
            // Release over a petal → run it; otherwise drag/cancel ends the tool.
            if let action = fanView.highlightedAction {
                fanView.onSelect?(action)
            } else {
                hide()
                onDismiss?()
            }
        case .leftMouseDown:
            if fanView.containsScreenPoint(screen), let action = fanView.highlightedAction {
                fanView.onSelect?(action)
            } else if !fanView.containsScreenPoint(screen) {
                hide()
                onDismiss?()
            }
        default:
            break
        }
    }
}

