import AppKit
import Combine
import UniformTypeIdentifiers

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let store: ConversionTaskStore
    private let overlay = DropOverlayController()
    private let dragMonitor = DragGestureMonitor()
    private var cancellables = Set<AnyCancellable>()

    init(store: ConversionTaskStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        configureStatusButton()
        statusItem.isVisible = true
        statusItem.autosaveName = "kiln.statusItem"

        store.onImageAction = { [weak self] urls, action in
            self?.overlay.presentImage(urls: urls, action: action)
        }
        store.onPDFAction = { [weak self] urls, action in
            self?.overlay.presentPDF(urls: urls, action: action)
        }
        overlay.onAction = { [weak self] action, urls in
            self?.store.enqueue(urls: urls, action: action)
        }
        overlay.onVisibilityChange = { [weak self] _ in
            self?.rebuildMenu()
        }
        dragMonitor.onShelfRequested = { [weak self] in
            self?.overlay.showForDrag()
        }
        dragMonitor.start()

        store.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        store.$isBusy
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        store.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        rebuildMenu()

        // Re-assert visibility after the run loop settles (helps crowded menu bars).
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.isVisible = true
            self?.configureStatusButton()
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeKilnIcon()
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = "Kiln — local file convert"
        button.appearsDisabled = false
    }

    /// Menu-bar kiln: filled arch + door cutout (SF-style template).
    private static func makeKilnIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            kilnGlyphPath(in: rect.insetBy(dx: 2.2, dy: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Shared kiln silhouette in `rect` (bottom-left origin, AppKit).
    static func kilnGlyphPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd

        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        // Outer body + chimney as one silhouette.
        path.move(to: NSPoint(x: x + w * 0.10, y: y))
        path.line(to: NSPoint(x: x + w * 0.90, y: y))
        path.line(to: NSPoint(x: x + w * 0.90, y: y + h * 0.40))
        path.curve(
            to: NSPoint(x: x + w * 0.68, y: y + h * 0.78),
            controlPoint1: NSPoint(x: x + w * 0.90, y: y + h * 0.62),
            controlPoint2: NSPoint(x: x + w * 0.82, y: y + h * 0.74)
        )
        path.line(to: NSPoint(x: x + w * 0.68, y: y + h * 0.96))
        path.line(to: NSPoint(x: x + w * 0.52, y: y + h * 0.96))
        path.line(to: NSPoint(x: x + w * 0.52, y: y + h * 0.80))
        path.curve(
            to: NSPoint(x: x + w * 0.10, y: y + h * 0.40),
            controlPoint1: NSPoint(x: x + w * 0.28, y: y + h * 0.80),
            controlPoint2: NSPoint(x: x + w * 0.10, y: y + h * 0.62)
        )
        path.close()

        // Door opening (cutout via even-odd).
        let door = NSBezierPath(
            roundedRect: NSRect(
                x: x + w * 0.34,
                y: y + h * 0.05,
                width: w * 0.32,
                height: h * 0.36
            ),
            xRadius: w * 0.09,
            yRadius: w * 0.09
        )
        path.append(door)
        return path
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let dropItem = NSMenuItem(
            title: overlay.isVisible ? "Hide Drop Overlay" : "Show Drop Overlay",
            action: #selector(toggleOverlay),
            keyEquivalent: "d"
        )
        dropItem.target = self
        menu.addItem(dropItem)

        let mods = NSMenuItem(
            title: "Drag + ⇧ to show file shelf",
            action: nil,
            keyEquivalent: ""
        )
        mods.isEnabled = false
        menu.addItem(mods)

        menu.addItem(.separator())

        if let err = store.lastError {
            let item = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if store.isBusy {
            menu.addItem(NSMenuItem(title: "Working…", action: nil, keyEquivalent: ""))
        }

        let recent = store.tasks.prefix(8)
        if !recent.isEmpty {
            menu.addItem(NSMenuItem(title: "Recent", action: nil, keyEquivalent: ""))
            for task in recent {
                let name = task.outputs.first?.lastPathComponent ?? task.source.lastPathComponent
                let label: String
                switch task.status {
                case .queued: label = "Queued · \(task.action.title) · \(name)"
                case .running: label = "Running · \(task.action.title)"
                case .succeeded: label = "✓ \(task.action.title) · \(name)"
                case .failed: label = "✗ \(task.action.title) · \(task.errorMessage ?? name)"
                }
                let item = NSMenuItem(title: label, action: #selector(revealTask(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = task.outputs.first ?? task.source
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Kiln", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleOverlay() {
        overlay.toggle()
        // Menu title refreshes via overlay.onVisibilityChange.
    }

    @objc private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            Task { @MainActor in
                self.overlay.present(urls: panel.urls)
            }
        }
    }

    @objc private func revealTask(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func openConvertPicker() {
        pickFiles()
    }

    func toggleOverlayPublic() {
        toggleOverlay()
    }
}
