import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

final class FileShelfView: NSView {
    var onClose: (() -> Void)?
    var onFilesReceived: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onAction: ((FanAction, [URL]) -> Void)?
    private var urls: [URL] = []
    var hasFiles: Bool { !urls.isEmpty }
    private var mode: FanMode = .convert
    private var previewImages: [NSImage] = []
    private var previewSlots: [RoundedPreview] = []
    private var previewRequests: [QLThumbnailGenerator.Request] = []
    private var dragHighlighted = false
    private weak var fileCard: NSView?
    private var optionViews: [NSView] = []
    private var sectionSelector: GlassSectionSelector?
    private var sharingPicker: NSSharingServicePicker?
    private weak var sharingButton: NSButton?
    private var audioEditor: AudioEditorWindowController?
    private var selectedAudioAction: FanAction?
    private var audioActionButtons: [FanAction: AudioActionButton] = [:]
    private weak var audioEditorContent: NSView?
    private var imageEditor: ImageEditorWindowController?
    private var selectedImageAction: FanAction?
    private var imageActionButtons: [FanAction: AudioActionButton] = [:]
    private weak var imageEditorContent: NSView?
    private var pdfEditor: PDFEditorWindowController?
    private var selectedPDFAction: FanAction?
    private var pdfActionButtons: [FanAction: AudioActionButton] = [:]
    private weak var pdfEditorContent: NSView?
    private var optionsBottom: CGFloat = 248
    private static let sectionOrder: [FanMode] = [.convert, .fileActions, .fileTools]
    static let overflow: CGFloat = 48
    override var isFlipped: Bool { true }
    private var contentWidth: CGFloat { bounds.width - Self.overflow * 2 }

    private func placed(_ rect: NSRect) -> NSRect {
        rect.offsetBy(dx: Self.overflow, dy: 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = LiquidGlass.controlAppearance
        registerForDraggedTypes([.fileURL])
        rebuild()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func endSignatureAcquisition() -> Bool {
        pdfEditor?.endSignatureAcquisition() ?? false
    }

    func shutdownAudio() {
        audioEditor?.shutdown()
        audioEditor = nil
        selectedAudioAction = nil
        pdfEditor = nil
        selectedPDFAction = nil
        imageEditor = nil
        selectedImageAction = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sectionSelector else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let inSelector = sectionSelector.convert(local, from: self)
        if sectionSelector.claims(inSelector) { return sectionSelector }
        return super.hitTest(point)
    }

    func receive(_ candidates: [URL]) {
        let files = candidates.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        shutdownAudio()
        previewRequests.forEach { QLThumbnailGenerator.shared.cancel($0) }
        previewRequests = []
        urls = files
        if files.count == 1, FileKind.classify(url: files[0]).isAudio {
            audioEditor = AudioEditorWindowController(source: files[0], action: .trimAudio, embeddedWidth: contentWidth - 16)
        }
        onFilesReceived?()
        mode = Self.sectionOrder.first { !ActionAvailability.actions(for: files, mode: $0).isEmpty } ?? .fileActions
        previewImages = files.prefix(3).map { NSWorkspace.shared.icon(forFile: $0.path) }
        rebuild()
        let scale = window?.backingScaleFactor ?? 2
        for file in files.prefix(3) {
            let request = QLThumbnailGenerator.Request(fileAt: file, size: NSSize(width: 144, height: 144), scale: scale, representationTypes: .all)
            previewRequests.append(request)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                DispatchQueue.main.async {
                    guard let self, let thumbnail, let index = self.previewRequests.firstIndex(where: { $0 === request }) else { return }
                    guard index < self.previewImages.count, index < self.previewSlots.count else { return }
                    self.previewImages[index] = thumbnail.nsImage
                    self.previewSlots[index].image = thumbnail.nsImage
                }
            }
        }
    }

    private func label(_ title: String, frame: NSRect, size: CGFloat, color: NSColor = LiquidGlass.primaryText, weight: NSFont.Weight = .regular, truncatesTail: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame = frame
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = truncatesTail ? .byTruncatingTail : .byTruncatingMiddle
        return label
    }

    private func glass(_ frame: NSRect, radius: CGFloat = 24, isOption: Bool = false, interactive: Bool = false) -> NSView {
        let content = ShelfContentView(frame: NSRect(origin: .zero, size: frame.size))
        let glass = LiquidGlass.place(content, in: self, frame: frame, cornerRadius: radius, interactive: interactive)
        if isOption { optionViews.append(glass) }
        return content
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        optionViews.removeAll()
        sectionSelector = nil
        let width = contentWidth
        let radius: CGFloat = 24
        let card = glass(placed(NSRect(x: 8, y: 8, width: width - 16, height: 112)), radius: radius, interactive: true)
        fileCard = card
        card.wantsLayer = true
        // A layer border with no radius is a square, so it sticks out past the glass curve.
        card.layer?.cornerRadius = radius
        card.layer?.cornerCurve = LiquidGlass.isLiquidGlassAvailable ? .continuous : .circular
        card.layer?.borderColor = NSColor.controlAccentColor.cgColor
        card.layer?.borderWidth = dragHighlighted ? 2 : 0
        let close = ShelfButton(title: "", symbol: "xmark") { [weak self] in self?.onClose?() }
        close.frame = NSRect(x: card.bounds.width - 38, y: 10, width: 28, height: 28)
        close.imagePosition = .imageOnly
        close.setAccessibilityLabel("Close shelf")
        card.addSubview(close)

        if urls.isEmpty {
            let cardHeight: CGFloat = 112
            let midY = cardHeight / 2
            let iconSize: CGFloat = 32
            let iconX: CGFloat = 26
            // SF Symbol "tray…" sits optically low in its bounds; nudge up a hair.
            let iconY = midY - iconSize / 2
            let icon = NSImageView(frame: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
            let symbol = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            icon.image = symbol?.withSymbolConfiguration(.init(pointSize: iconSize * 0.85, weight: .semibold))
            icon.imageScaling = .scaleProportionallyDown
            icon.imageAlignment = .alignCenter
            icon.contentTintColor = .controlAccentColor
            card.addSubview(icon)
            // NSTextField draws near the top of a tall frame — keep height ≈ font so midY matches.
            let fontSize: CGFloat = 19
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let labelHeight = ceil(font.ascender - font.descender)
            let labelX = iconX + iconSize + 16
            let labelY = midY - labelHeight / 2
            card.addSubview(label("Trascina qui un file", frame: NSRect(x: labelX, y: labelY, width: width - labelX - 54, height: labelHeight), size: fontSize, weight: .semibold))
            onHeightChange?(132)
            return
        }

        installPreviews(in: card)
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        let title = urls.count == 1 ? names : "\(urls.count) file · \(names)"
        card.addSubview(label(title, frame: NSRect(x: 118, y: 23, width: width - 190, height: 25), size: 17, weight: .semibold, truncatesTail: true))
        card.addSubview(label(fileDetails, frame: NSRect(x: 118, y: 55, width: width - 190, height: 20), size: 12, color: LiquidGlass.secondaryText))

        let share = ShelfButton(title: "", symbol: "square.and.arrow.up") { [weak self] in
            self?.shareFiles()
        }
        share.frame = NSRect(x: close.frame.minX, y: card.bounds.height - close.frame.maxY, width: close.frame.width, height: close.frame.height)
        share.imagePosition = .imageOnly
        share.toolTip = "Condividi"
        share.setAccessibilityLabel("Condividi")
        card.addSubview(share)
        sharingButton = share

        let bar = SectionBarView(frame: placed(NSRect(x: 8, y: 132, width: width - 16, height: 52)))
        addSubview(bar)
        let backdrop = LiquidGlass.makeBackdrop(frame: bar.bounds, cornerRadius: bar.bounds.height / 2, interactive: true)
        backdrop.autoresizingMask = [.width, .height]
        bar.addSubview(backdrop)
        let enabled = Set(Self.sectionOrder.filter { $0 == .fileActions || !ActionAvailability.actions(for: urls, mode: $0).isEmpty })
        let selector = GlassSectionSelector(frame: bar.bounds, selectedMode: mode, enabledModes: enabled)
        selector.onSelect = { [weak self] in self?.select($0) }
        bar.addSubview(selector)
        sectionSelector = selector
        rebuildOptions()
    }

    /// First file stays in front. The stack is centered on the same spot as the single preview, so the titles do not move.
    private func installPreviews(in card: NSView) {
        previewSlots = []
        let count = min(urls.count, previewImages.count, 3)
        guard count > 0 else { return }
        if count == 1 {
            let image = RoundedPreview(frame: NSRect(x: 20, y: 16, width: 80, height: 80), radius: 16)
            image.image = previewImages[0]
            card.addSubview(image)
            previewSlots = [image]
            return
        }
        let host = PreviewStackView(frame: NSRect(x: 4, y: 4, width: 108, height: 104))
        card.addSubview(host)
        let side: CGFloat = 68
        let anchor = NSPoint(x: 56, y: 52)
        let fans = previewFans(count: count)
        var slots = [RoundedPreview?](repeating: nil, count: count)
        for index in (0..<count).reversed() {
            let fan = fans[index]
            let rotating = RotatingPreview(
                center: NSPoint(x: anchor.x + fan.dx, y: anchor.y + fan.dy),
                side: side,
                angle: fan.angle,
                radius: 14
            )
            rotating.preview.image = previewImages[index]
            host.addSubview(rotating)
            slots[index] = rotating.preview
        }
        previewSlots = slots.compactMap { $0 }
    }

    private func previewFans(count: Int) -> [(angle: CGFloat, dx: CGFloat, dy: CGFloat)] {
        if count == 2 {
            return [(-6, -5, 2), (7, 7, -1)]
        }
        return [(-3, 0, 3), (8, 9, -2), (-11, -8, 1)]
    }

    private func rebuildOptions() {
        optionViews.forEach { $0.removeFromSuperview() }
        optionViews.removeAll()
        audioActionButtons.removeAll()
        pdfActionButtons.removeAll()
        imageActionButtons.removeAll()
        imageEditorContent = nil
        audioEditorContent = nil
        pdfEditorContent = nil
        let width = contentWidth
        let actions = ActionAvailability.actions(for: urls, mode: mode)
        audioEditor?.suspendPlayback()
        let gap: CGFloat = 8
        let available = width - 16
        let minimumWidth: CGFloat = actions.allSatisfy { AudioEditOperation(action: $0) != nil || $0.isPDFAction || $0.isImageAction } ? 112 : 142
        let fitted = max(1, Int((available + gap) / (minimumWidth + gap)))
        let columns = max(1, min(max(actions.count, 1), fitted))
        let cellWidth = (available - CGFloat(columns - 1) * gap) / CGFloat(columns)
        for (index, action) in actions.enumerated() {
            let row = index / columns
            let column = index % columns
            let itemsInRow = min(columns, actions.count - row * columns)
            let rowWidth = CGFloat(itemsInRow) * cellWidth + CGFloat(itemsInRow - 1) * gap
            let x = Self.overflow + (width - rowWidth) / 2 + CGFloat(column) * (cellWidth + gap)
            let y = 196 + CGFloat(row) * 52
            if AudioEditOperation(action: action) != nil {
                let button = AudioActionButton(frame: NSRect(x: x, y: y, width: cellWidth, height: 44), title: action.title) { [weak self] in
                    guard let self else { return }
                    if let editor = self.audioEditor {
                        guard editor.selectAction(action) else { return }
                    } else {
                        self.audioEditor = AudioEditorWindowController(source: self.urls[0], action: action, embeddedWidth: self.contentWidth - 16)
                    }
                    self.selectedAudioAction = action
                    for (candidate, button) in self.audioActionButtons {
                        button.setSelected(candidate == action, animated: true)
                    }
                    self.showAudioEditor()
                }
                button.setSelected(action == selectedAudioAction, animated: false)
                addSubview(button)
                optionViews.append(button)
                audioActionButtons[action] = button
                continue
            }
            if action.isImageAction {
                let button = AudioActionButton(frame: NSRect(x: x, y: y, width: cellWidth, height: 44), title: action.title) { [weak self] in
                    self?.selectImageAction(action)
                }
                button.setSelected(action == selectedImageAction, animated: false)
                addSubview(button)
                optionViews.append(button)
                imageActionButtons[action] = button
                continue
            }
            if action.isPDFAction {
                let button = AudioActionButton(frame: NSRect(x: x, y: y, width: cellWidth, height: 44), title: action.title) { [weak self] in
                    self?.selectPDFAction(action)
                }
                button.setSelected(action == selectedPDFAction, animated: false)
                addSubview(button)
                optionViews.append(button)
                pdfActionButtons[action] = button
                continue
            }
            let bubble = glass(NSRect(x: x, y: y, width: cellWidth, height: 44), radius: 22, isOption: true, interactive: true)
            let button = ShelfButton(title: action.title) { [weak self] in
                guard let self else { return }
                self.onAction?(action, self.urls)
            }
            button.frame = bubble.bounds
            bubble.addSubview(button)
        }
        let rows = max(1, (actions.count + columns - 1) / columns)
        optionsBottom = 196 + CGFloat(rows) * 52
        if mode == .fileActions, let selectedImageAction, actions.contains(selectedImageAction), imageEditor != nil {
            showImageEditor()
        } else if mode == .fileActions, let selectedAudioAction, actions.contains(selectedAudioAction), audioEditor != nil {
            showAudioEditor()
        } else if mode == .fileActions, let selectedPDFAction, actions.contains(selectedPDFAction), pdfEditor != nil {
            showPDFEditor()
        } else {
            onHeightChange?(optionsBottom + 8)
        }
    }

    func selectImageAction(_ action: FanAction) {
        guard ActionAvailability.actions(for: urls, mode: .fileActions).contains(action), action.isImageAction else { return }
        if let imageEditor {
            guard imageEditor.selectAction(action) else { return }
        } else {
            imageEditor = ImageEditorWindowController(source: urls[0], action: action, embeddedWidth: contentWidth - 16)
        }
        selectedImageAction = action
        if mode != .fileActions { mode = .fileActions; rebuild() }
        for (candidate, button) in imageActionButtons { button.setSelected(candidate == action, animated: true) }
        showImageEditor()
    }

    private func showImageEditor() {
        guard let imageEditor else { return }
        imageEditor.onExportCompleted = { [weak self, weak imageEditor] in
            guard let self, let imageEditor, self.imageEditor === imageEditor else { return }
            self.onClose?()
        }
        if imageEditorContent == nil {
            imageEditor.editorView.removeFromSuperview()
            imageEditor.editorView.frame = placed(NSRect(x: 8, y: optionsBottom, width: contentWidth - 16, height: imageEditor.contentHeight))
            addSubview(imageEditor.editorView)
            optionViews.append(imageEditor.editorView)
            imageEditorContent = imageEditor.editorView
        }
        imageEditor.editorView.frame = placed(NSRect(x: 8, y: optionsBottom, width: contentWidth - 16, height: imageEditor.contentHeight))
        onHeightChange?(optionsBottom + imageEditor.contentHeight + 8)
    }

    func selectPDFAction(_ action: FanAction) {
        guard ActionAvailability.actions(for: urls, mode: .fileActions).contains(action), action.isPDFAction else { return }
        do {
            if let pdfEditor {
                guard pdfEditor.selectAction(action) else { return }
            } else {
                pdfEditor = try PDFEditorWindowController(sources: urls, action: action, embeddedWidth: contentWidth - 16)
            }
            selectedPDFAction = action
            if mode != .fileActions {
                mode = .fileActions
                rebuild()
            }
            for (candidate, button) in pdfActionButtons {
                button.setSelected(candidate == action, animated: true)
            }
            showPDFEditor()
        } catch {
            let errorView = glass(placed(NSRect(x: 8, y: optionsBottom, width: contentWidth - 16, height: 76)), isOption: true)
            let message = NSTextField(wrappingLabelWithString: error.localizedDescription)
            message.font = .systemFont(ofSize: 12)
            message.frame = errorView.bounds.insetBy(dx: 16, dy: 16)
            errorView.addSubview(message)
            onHeightChange?(optionsBottom + 84)
        }
    }

    private func showPDFEditor() {
        guard let pdfEditor else { return }
        let height = pdfEditor.contentHeight
        pdfEditor.onExportCompleted = { [weak self, weak pdfEditor] in
            guard let self, let pdfEditor, self.pdfEditor === pdfEditor else { return }
            self.onClose?()
        }
        pdfEditor.onContentHeightChange = { [weak self] _ in
            guard let self, self.mode == .fileActions, self.pdfEditorContent != nil else { return }
            self.showPDFEditor()
        }
        if pdfEditorContent == nil {
            pdfEditor.editorView.removeFromSuperview()
            pdfEditor.editorView.frame = placed(NSRect(x: 8, y: optionsBottom, width: contentWidth - 16, height: height))
            addSubview(pdfEditor.editorView)
            optionViews.append(pdfEditor.editorView)
            pdfEditorContent = pdfEditor.editorView
        }
        pdfEditorContent?.setFrameSize(NSSize(width: contentWidth - 16, height: height))
        onHeightChange?(optionsBottom + height + 8)
    }

    private func showAudioEditor() {
        guard let audioEditor else { return }
        let height = audioEditor.contentHeight
        audioEditor.onExportCompleted = { [weak self, weak audioEditor] in
            guard let self, let audioEditor, self.audioEditor === audioEditor else { return }
            self.onClose?()
        }
        audioEditor.onContentHeightChange = { [weak self] _ in
            guard let self, self.mode == .fileActions, self.audioEditorContent != nil else { return }
            self.showAudioEditor()
        }
        if audioEditorContent == nil {
            audioEditor.editorView.removeFromSuperview()
            audioEditor.editorView.frame = placed(NSRect(x: 8, y: optionsBottom, width: contentWidth - 16, height: height))
            addSubview(audioEditor.editorView)
            optionViews.append(audioEditor.editorView)
            audioEditorContent = audioEditor.editorView
        }
        audioEditorContent?.setFrameSize(NSSize(width: contentWidth - 16, height: height))
        onHeightChange?(optionsBottom + height + 8)
    }

    private func select(_ newMode: FanMode) {
        guard mode != newMode else { return }
        guard newMode == .fileActions || !ActionAvailability.actions(for: urls, mode: newMode).isEmpty else { return }
        mode = newMode
        rebuildOptions()
    }

    private func shareFiles() {
        guard !urls.isEmpty, let share = sharingButton else { return }
        let picker = NSSharingServicePicker(items: urls)
        sharingPicker = picker
        picker.show(relativeTo: share.bounds, of: share, preferredEdge: .minY)
    }

    private var fileDetails: String {
        var total: Int64 = 0
        var extensions = Set<String>()
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            total += Int64(values?.fileSize ?? 0)
            extensions.insert(values?.isDirectory == true ? "Cartella" : (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()))
        }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(extensions.sorted().joined(separator: ", ")) · \(size)"
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = !PasteboardFileURLs.fileURLs(from: sender.draggingPasteboard).isEmpty
        setDragHighlighted(valid)
        return valid ? .copy : []
    }
    private func setDragHighlighted(_ highlighted: Bool) {
        guard dragHighlighted != highlighted else { return }
        dragHighlighted = highlighted
        if urls.isEmpty { rebuild() }
        else { fileCard?.layer?.borderWidth = highlighted ? 2 : 0 }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDragHighlighted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDragHighlighted(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = PasteboardFileURLs.fileURLs(from: sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        dragHighlighted = false
        receive(files)
        window?.makeKey()
        return !urls.isEmpty
    }
}

