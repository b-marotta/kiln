import AppKit
import PDFKit
import UniformTypeIdentifiers

final class PDFEditorWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private var sourceDocuments: [URL: PDFDocument] = [:]
    private var sources: [URL]
    private let source: URL
    private var pdfDocument: PDFDocument
    private var action: FanAction
    private var busy = false
    private var output: [URL] = []
    private var insertedSignatures = 0
    private struct SignatureEdit {
        let index: Int
        let before: Data
        let after: Data
    }
    private var signatureUndo: [SignatureEdit] = []
    private var signatureRedo: [SignatureEdit] = []
    private weak var undoSignatureButton: NSButton?
    private weak var redoSignatureButton: NSButton?
    private var restoringSignatureViewport = false
    private var signatureTarget: (page: PDFPage, annotation: PDFAnnotation)?
    private var exportContainer: NSView?
    private var previewContainer: NSView?
    private let sideControls = PDFPreviewControlsView()
    private var previewSurface: PDFPreviewSurface?
    private var ocrScroll: NSScrollView?
    private var signatureScale: CGFloat = 1
    private let recognizedText = GlassTextView()
    private var ocrPage: Int?
    private var ocrCache: [Int: String] = [:]
    private var ocrWork: DispatchWorkItem?
    private let ocrQueue = DispatchQueue(label: "io.leapstudio.kiln.page-ocr", qos: .userInitiated)
    private var ocrGeneration = 0
    private let compressionPercent = NSTextField(labelWithString: "")
    private let compressionSize = NSTextField(labelWithString: "")
    private var estimateGeneration = 0
    private var estimateWork: DispatchWorkItem?
    private let estimateQueue = DispatchQueue(label: "io.leapstudio.kiln.pdf-estimate", qos: .userInitiated)
    private var rangeHelp: NSPopover?
    let editorView: NSView
    var onContentHeightChange: ((CGFloat) -> Void)?
    var onExportCompleted: (() -> Void)?
    private var accessoryHeight: CGFloat {
        switch action {
        case .compressPDF: return 48
        case .reorderPDF, .signPDF: return 44
        default: return 0
        }
    }
    private var controlsTop: CGFloat { 312 }
    var contentHeight: CGFloat { controlsTop + controlsHeight + (controlsHeight > 0 ? 12 : 0) + 44 }
    private var controlsHeight: CGFloat {
        switch action {
        case .signPDF: return 214
        case .ocrPDF: return 180
        case .splitPDF: return 44
        case .compressPDF: return 76
        case .mergePDF: return 44
        default: return 0
        }
    }
    private let table = NSTableView()
    private let preview = SignaturePDFView()
    private let controls = PDFEditorContentView()
    private var exportTitle: String { action == .ocrPDF ? "Esporta TXT" : "Esporta PDF" }
    private let exportButton = GlassCenteredIconButton(title: "Esporta PDF", target: nil, action: nil)
    private let range = PDFCenteredTextField(string: "")
    private let splitMode = NSPopUpButton()
    private let quality = NSSlider(value: 0.85, minValue: 0.5, maxValue: 0.95, target: nil, action: nil)
    private weak var acquisitionButton: NSButton?
    private let signature = SignaturePad(frame: NSRect(x: 0, y: 0, width: 400, height: 72))
    private let dragType = NSPasteboard.PasteboardType("io.leapstudio.kiln.pdf-row")
    private let dragToken = UUID().uuidString
    private var available: [FanAction] { ActionAvailability.actions(for: sources, mode: .fileActions) }

    init(sources: [URL], action: FanAction, embeddedWidth: CGFloat) throws {
        guard let first = sources.first, ActionAvailability.actions(for: sources, mode: .fileActions).contains(action),
              (sources.count > 1 ? action == .mergePDF : action != .mergePDF) else { throw ConversionError.unsupported }
        self.sources = sources
        self.source = first
        self.action = action
        var documents: [URL: PDFDocument] = [:]
        for url in sources { documents[url] = try DocumentConverter.pdfDocument(source: url) }
        self.sourceDocuments = documents
        pdfDocument = try Self.combine(sources, documents: documents)
        editorView = PDFEditorContentView(frame: NSRect(x: 0, y: 0, width: embeddedWidth, height: 416))
        super.init()
        build()
    }

    private static func combine(_ sources: [URL], documents: [URL: PDFDocument]) throws -> PDFDocument {
        let result = PDFDocument()
        for url in sources {
            guard let document = documents[url] else { throw ConversionError.readFailed }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw ConversionError.readFailed }
                result.insert(page, at: result.pageCount)
            }
        }
        return result
    }

    @discardableResult
    func selectAction(_ selected: FanAction) -> Bool {
        guard !busy, available.contains(selected) else { return false }
        guard action != selected else { return true }
        signature.endTrackpadCapture()
        clearTarget()
        if action == .ocrPDF {
            ocrGeneration += 1
            ocrWork?.cancel()
            exportButton.isEnabled = true
        }
        action = selected
        rebuildControls()
        return true
    }

    @discardableResult
    private func box(_ content: NSView, frame: NSRect, radius: CGFloat = 24, parent: NSView? = nil, interactive: Bool = false) -> NSView {
        content.frame = NSRect(origin: .zero, size: frame.size)
        return LiquidGlass.place(content, in: parent ?? editorView, frame: frame, cornerRadius: radius, interactive: interactive)
    }
    @discardableResult
    private func controlBox(_ control: NSView, frame: NSRect, parent: NSView? = nil, interactive: Bool = true) -> NSView {
        LiquidGlass.placeControl(
            control,
            in: parent ?? editorView,
            frame: frame,
            horizontalPadding: 12,
            verticalPadding: 4,
            interactive: interactive
        )
    }
    private func build() {
        let width = editorView.bounds.width
        let thumbWidth: CGFloat = 136
        let previewWidth = width - thumbWidth - 12
        let start: CGFloat = 0
        signature.onCaptureModeChange = { [weak self] active in
            self?.acquisitionButton?.title = active ? "Fine trackpad" : "Acquisisci..."
        }
        signature.onImportedImage = { [weak self] image in
            guard let self, !self.busy, self.action == .signPDF else { return false }
            do {
                self.signature.endTrackpadCapture()
                self.signature.importedImage = try Self.transparentSignature(image)
                self.signature.strokes = []
                self.signature.needsDisplay = true
                return true
            } catch { self.showError(error); return false }
        }
        splitMode.addItems(withTitles: ["Tutte le pagine in un PDF", "Un PDF per intervallo", "Un PDF per pagina"])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.width = 96
        column.minWidth = 60
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = .zero
        table.headerView = nil
        table.rowHeight = 90
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Miniature PDF trascinabili per cambiare ordine")
        scroll.documentView = table
        controlBox(scroll, frame: NSRect(x: start, y: 0, width: thumbWidth, height: 300))
        table.frame.size.width = scroll.contentSize.width
        table.sizeLastColumnToFit()
        preview.autoresizingMask = [.width, .height]
        preview.autoScales = false
        preview.displaysPageBreaks = true
        preview.pageBreakMargins = NSEdgeInsets(top: 40, left: 0, bottom: 40, right: 0)
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 24
        preview.layer?.masksToBounds = true
        preview.displayMode = .singlePage
        preview.backgroundColor = .clear
        preview.document = pdfDocument
        preview.onPlace = { [weak self] page, point in self?.placeSignature(page: page, point: point) }
        preview.signatureTarget = { [weak self] in
            guard let self, !self.busy else { return nil }
            return self.signatureTarget
        }
        let surface = PDFPreviewSurface(page: preview, floatingControls: sideControls)
        previewSurface = surface
        previewContainer = box(surface, frame: NSRect(x: start + thumbWidth + 12, y: 0, width: previewWidth, height: 300), radius: 24)
        exportButton.target = self
        exportButton.action = #selector(exportPDF)
        exportContainer = controlBox(exportButton, frame: NSRect(x: 0, y: contentHeight - 44, width: width, height: 44))
        quality.target = self
        quality.action = #selector(qualityChanged)
        quality.isContinuous = true
        recognizedText.delegate = self
        recognizedText.textContainerInset = NSSize(width: 4, height: 8)
        recognizedText.font = .systemFont(ofSize: 12)
        recognizedText.isRichText = false
        recognizedText.isAutomaticQuoteSubstitutionEnabled = false
        recognizedText.isVerticallyResizable = true
        recognizedText.isHorizontallyResizable = false
        recognizedText.autoresizingMask = [.width]
        recognizedText.textContainer?.widthTracksTextView = true
        recognizedText.drawsBackground = false
        recognizedText.textColor = LiquidGlass.primaryText
        controls.frame = NSRect(x: 0, y: controlsTop, width: width, height: controlsHeight)
        editorView.addSubview(controls)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        rebuildControls()
    }

    private func button(_ title: String, column: Int, row: Int = 0, columns: Int = 3, selector: Selector) {
        let width = (editorView.bounds.width - CGFloat(columns - 1) * 12) / CGFloat(columns)
        let button = GlassCenteredIconButton(title: title, target: self, action: selector)
        button.font = .systemFont(ofSize: 12)
        controlBox(button, frame: NSRect(x: CGFloat(column) * (width + 12), y: CGFloat(row) * 52, width: width, height: 44), parent: controls)
    }
    @discardableResult
    private func sideIcon(_ symbol: String, title: String, selector: Selector, column: Int, row: Int) -> NSButton {
        let button = GlassCenteredIconButton(title: "", target: self, action: selector)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.imagePosition = .imageOnly
        button.alignment = .center
        button.toolTip = title
        button.setAccessibilityLabel(title)
        controlBox(button, frame: NSRect(x: CGFloat(column) * 52, y: CGFloat(row) * 52, width: 44, height: 44), parent: sideControls)
        return button
    }
    private func sideInfo(_ field: NSTextField, x: CGFloat, y: CGFloat) {
        let width: CGFloat = 120
        let host = PDFEditorContentView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        field.frame = NSRect(x: 8, y: 15, width: width - 16, height: 18)
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .center
        host.addSubview(field)
        box(host, frame: NSRect(x: x, y: y, width: width, height: 44), parent: sideControls, interactive: false)
    }
    private func layoutOCRText() {
        guard let scroll = ocrScroll, let container = recognizedText.textContainer,
              let manager = recognizedText.layoutManager else { return }
        let width = max(1, scroll.contentSize.width)
        recognizedText.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        recognizedText.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        recognizedText.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, recognizedText.frame.height)))
        container.containerSize = NSSize(width: max(1, width - 2 * recognizedText.textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = ceil(manager.usedRect(for: container).maxY + 2 * recognizedText.textContainerInset.height + 16)
        recognizedText.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === recognizedText else { return }
        if let page = ocrPage, ocrCache[page] != nil { ocrCache[page] = recognizedText.string }
        layoutOCRText()
    }
    @objc private func shrinkSignature() { resizeSignature(by: 1 / 1.15) }
    @objc private func enlargeSignature() { resizeSignature(by: 1.15) }
    private func resizeSignature(by factor: CGFloat) {
        guard !busy else { return }
        if signatureScale * factor > 6 || signatureScale * factor < 0.2 { return }
        signatureScale = signatureScale * factor
        guard let target = signatureTarget else { return }
        let bounds = target.annotation.bounds
        placeSignature(page: target.page, point: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    private func rebuildControls() {
        controls.subviews.forEach { $0.removeFromSuperview() }
        sideControls.subviews.forEach { $0.removeFromSuperview() }
        ocrScroll = nil
        let width = editorView.bounds.width
        controls.frame = NSRect(x: 0, y: controlsTop, width: width, height: controlsHeight)
        preview.placingSignature = action == .signPDF
        let accessoryWidth: CGFloat
        switch action {
        case .compressPDF: accessoryWidth = 252
        case .reorderPDF: accessoryWidth = 304
        case .signPDF: accessoryWidth = 200
        default: accessoryWidth = 0
        }
        sideControls.setFrameSize(NSSize(width: accessoryWidth, height: accessoryHeight))
        sideControls.isHidden = accessoryWidth == 0
        previewContainer?.frame = NSRect(x: 148, y: 0, width: width - 148, height: 300)
        previewSurface?.needsLayout = true
        previewSurface?.layoutSubtreeIfNeeded()
        exportContainer?.frame = NSRect(x: 0, y: contentHeight - 44, width: width, height: 44)
        exportContainer?.isHidden = false
        exportButton.title = exportTitle
        switch action {
        case .mergePDF:
            button("Sposta su", column: 0, columns: 2, selector: #selector(moveRowUp))
            button("Sposta giù", column: 1, columns: 2, selector: #selector(moveRowDown))
        case .splitPDF:
            range.placeholderString = "1-2, 5-7"
            range.setAccessibilityLabel("Pagine da estrarre")
            range.isBordered = false
            range.drawsBackground = false
            range.usesSingleLineMode = true
            range.cell?.isScrollable = true
            let rangeWidth = width - 240 - 12
            let host = PDFEditorContentView(frame: NSRect(x: 0, y: 0, width: rangeWidth, height: 44))
            range.frame = NSRect(x: 14, y: 0, width: rangeWidth - 64, height: 44)
            host.addSubview(range)
            let info = GlassCenteredIconButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Sintassi pagine")!, target: self, action: #selector(showRangeHelp(_:)))
            info.frame = NSRect(x: rangeWidth - 42, y: 6, width: 30, height: 32)
            info.isBordered = false
            info.imagePosition = .imageOnly
            info.alignment = .center
            info.toolTip = "Pagine singole: 3. Intervalli: 1-2. Più intervalli: 1-2, 5-7. Gli spazi sono facoltativi."
            host.addSubview(info)
            box(host, frame: host.bounds, radius: 22, parent: controls, interactive: true)
            splitMode.isBordered = false
            splitMode.alignment = .center
            splitMode.font = .systemFont(ofSize: 11)
            controlBox(splitMode, frame: NSRect(x: rangeWidth + 12, y: 0, width: 240, height: 44), parent: controls)
        case .reorderPDF:
            let items: [(String, String, Selector)] = [
                ("arrow.up", "Sposta su", #selector(moveRowUp)),
                ("arrow.down", "Sposta giù", #selector(moveRowDown)),
                ("rotate.right", "Ruota 90°", #selector(rotatePage)),
                ("rotate.left", "Ruota -90°", #selector(rotatePageBack)),
                ("plus.square.on.square", "Duplica", #selector(duplicatePage)),
                ("trash", "Elimina", #selector(deletePage))
            ]
            for (i, item) in items.enumerated() {
                sideIcon(item.0, title: item.1, selector: item.2, column: i, row: 0)
            }
        case .compressPDF:
            quality.setAccessibilityLabel("Qualità di compressione PDF")
            let host = PDFEditorContentView(frame: NSRect(x: 0, y: 0, width: width, height: 76))
            quality.frame = NSRect(x: 12, y: 4, width: width - 24, height: 40)
            host.addSubview(quality)
            let low = NSTextField(labelWithString: "Più compatto")
            low.frame = NSRect(x: 14, y: 48, width: 110, height: 18)
            low.font = .systemFont(ofSize: 11)
            low.textColor = LiquidGlass.secondaryText
            let high = NSTextField(labelWithString: "Più qualità")
            high.frame = NSRect(x: width - 124, y: 48, width: 110, height: 18)
            high.font = .systemFont(ofSize: 11)
            high.textColor = LiquidGlass.secondaryText
            high.alignment = .right
            sideInfo(compressionPercent, x: 0, y: 0)
            sideInfo(compressionSize, x: 132, y: 0)
            host.addSubview(low)
            host.addSubview(high)
            box(host, frame: NSRect(x: 0, y: 0, width: width, height: 76), parent: controls, interactive: true)
            updateEstimate()
        case .ocrPDF:
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
            scroll.documentView = recognizedText
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            controlBox(scroll, frame: NSRect(x: 0, y: 0, width: width, height: 180), parent: controls, interactive: false)
            ocrScroll = scroll
            layoutOCRText()
            detectText()
        case .signPDF:
            signature.wantsLayer = true
            signature.layer?.cornerRadius = 24
            signature.layer?.masksToBounds = true
            box(signature, frame: NSRect(x: 0, y: 0, width: width, height: 158), radius: 24, parent: controls)
            sideIcon("minus", title: "Riduci riquadro firma", selector: #selector(shrinkSignature), column: 0, row: 0)
            sideIcon("plus", title: "Ingrandisci riquadro firma", selector: #selector(enlargeSignature), column: 1, row: 0)
            undoSignatureButton = sideIcon("arrow.uturn.backward", title: "Annulla firma", selector: #selector(undoSignature), column: 2, row: 0)
            redoSignatureButton = sideIcon("arrow.uturn.forward", title: "Ripristina firma", selector: #selector(redoSignature), column: 3, row: 0)
            updateSignatureHistoryButtons()
            let titles = ["Pulisci", "Carica...", "Acquisisci...", "Inserisci"]
            let selectors = [#selector(clearSignature), #selector(loadSignature), #selector(acquireSignature), #selector(insertSignature)]
            let cellWidth = (width - 36) / 4
            for i in 0..<4 {
                let button = GlassCenteredIconButton(title: titles[i], target: self, action: selectors[i])
                button.font = .systemFont(ofSize: 12)
                if i == 2 { acquisitionButton = button }
                controlBox(button, frame: NSRect(x: CGFloat(i) * (cellWidth + 12), y: 170, width: cellWidth, height: 44), parent: controls)
            }
        default: break
        }
        table.reloadData()
        editorView.setFrameSize(NSSize(width: width, height: contentHeight))
        onContentHeightChange?(contentHeight)
    }

    @objc private func showRangeHelp(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        let help = NSTextField(wrappingLabelWithString: "Pagina singola: 3\nIntervallo: 1-2\nPiù pagine o intervalli: 1-2, 5-7\nGli spazi dopo la virgola sono facoltativi.")
        help.frame = NSRect(x: 16, y: 14, width: 290, height: 78)
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 322, height: 106))
        controller.view.addSubview(help)
        rangeHelp = popover
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PDFThumbnailRowView()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sources.count > 1 ? sources.count : pdfDocument.pageCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 96, height: 90))
        let page: PDFPage?
        let title: String
        if sources.count > 1 {
            page = sourceDocuments[sources[row]]?.page(at: 0)
            title = "\(row + 1). \(sources[row].lastPathComponent)"
        } else {
            page = pdfDocument.page(at: row)
            title = "Pagina \(row + 1)"
        }
        let image = NSImageView(frame: NSRect(x: (cell.bounds.width - 48) / 2, y: 20, width: 48, height: 66))
        image.image = page?.thumbnail(of: NSSize(width: 132, height: 180), for: .cropBox)
        image.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(image)
        let text = NSTextField(wrappingLabelWithString: title)
        text.frame = NSRect(x: 3, y: 0, width: cell.bounds.width - 6, height: 18)
        text.font = .systemFont(ofSize: 10)
        text.maximumNumberOfLines = 1
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = .center
        cell.addSubview(text)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSignatureViewport else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        let index = sources.count > 1 ? sources.prefix(row).reduce(0) { $0 + (sourceDocuments[$1]?.pageCount ?? 0) } : row
        if let page = pdfDocument.page(at: index) { preview.go(to: page) }
        if action == .ocrPDF { detectText() }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !busy, action == .mergePDF || action == .reorderPDF else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(dragToken):\(row)", forType: dragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !busy, action == .mergePDF || action == .reorderPDF,
              info.draggingPasteboard.string(forType: dragType)?.hasPrefix(dragToken + ":") == true else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard !busy, let text = info.draggingPasteboard.string(forType: dragType), text.hasPrefix(dragToken + ":"),
              let from = Int(text.split(separator: ":").last ?? "") else { return false }
        move(from: from, to: row > from ? row - 1 : row)
        return true
    }
    private func refresh(selected: Int, signatureEdit: Bool = false) {
        if !signatureEdit {
            signatureUndo.removeAll()
            signatureRedo.removeAll()
            updateSignatureHistoryButtons()
        }
        preview.document = pdfDocument
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: max(0, min(selected, numberOfRows(in: table) - 1))), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        invalidateDerived()
    }
    private func move(from: Int, to: Int) {
        guard !busy, from != to, from >= 0, to >= 0, to < numberOfRows(in: table), from < numberOfRows(in: table) else { return }
        if sources.count > 1 {
            let old = sources
            sources.insert(sources.remove(at: from), at: to)
            do { pdfDocument = try Self.combine(sources, documents: sourceDocuments) }
            catch { sources = old; showError(error); return }
        } else {
            guard let page = pdfDocument.page(at: from) else { return }
            pdfDocument.removePage(at: from)
            pdfDocument.insert(page, at: to)
        }
        refresh(selected: to)
    }
    @objc private func moveRowUp() { move(from: table.selectedRow, to: table.selectedRow - 1) }
    @objc private func moveRowDown() { move(from: table.selectedRow, to: table.selectedRow + 1) }
    @objc private func rotatePage() { rotate(by: 90) }
    @objc private func rotatePageBack() { rotate(by: -90) }
    private func rotate(by angle: Int) {
        guard !busy, let page = pdfDocument.page(at: table.selectedRow) else { return }
        clearTarget()
        page.rotation = (page.rotation + angle + 360) % 360
        refresh(selected: table.selectedRow)
    }
    @objc private func duplicatePage() {
        guard !busy, let page = pdfDocument.page(at: table.selectedRow)?.copy() as? PDFPage else { return }
        let row = table.selectedRow + 1
        pdfDocument.insert(page, at: row)
        refresh(selected: row)
    }
    @objc private func deletePage() {
        guard !busy, pdfDocument.pageCount > 1, table.selectedRow >= 0 else { NSSound.beep(); return }
        let row = table.selectedRow
        pdfDocument.removePage(at: row)
        refresh(selected: row)
    }
    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        if let window = editorView.window { alert.beginSheetModal(for: window) }
    }
    private func clearTarget() {
        if let target = signatureTarget { target.page.removeAnnotation(target.annotation) }
        signatureTarget = nil
        preview.needsDisplay = true
    }
    private func snapshot() throws -> Data {
        let target = signatureTarget
        if let target { target.page.removeAnnotation(target.annotation) }
        defer { if let target { target.page.addAnnotation(target.annotation) } }
        guard let data = pdfDocument.dataRepresentation() else { throw ConversionError.readFailed }
        return data
    }
    private func invalidateDerived() {
        ocrCache.removeAll()
        ocrPage = nil
        ocrWork?.cancel()
        ocrGeneration += 1
        estimateGeneration += 1
        estimateWork?.cancel()
    }
    @discardableResult
    func endSignatureAcquisition() -> Bool {
        guard signature.isAcquiring else { return false }
        signature.endTrackpadCapture()
        return true
    }
    @objc private func acquireSignature() {
        guard !busy else { return }
        signature.showAcquisitionMenu()
    }
    @objc private func clearSignature() {
        guard !busy else { return }
        signature.endTrackpadCapture()
        signature.strokes = []
        signature.importedImage = nil
        signature.needsDisplay = true
    }
    @objc private func loadSignature() {
        guard !busy, let window = editorView.window else { return }
        signature.endTrackpadCapture()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let image = try Self.transparentSignature(url)
                self.signature.strokes = []
                self.signature.importedImage = image
                self.signature.needsDisplay = true
            } catch { self.showError(error) }
        }
    }
    private static func transparentSignature(_ url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else { throw ConversionError.readFailed }
        return try transparentSignature(image)
    }
    private static func transparentSignature(_ image: NSImage) throws -> NSImage {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ConversionError.readFailed }
        let scale = min(1, 2400 / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let result: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let p = bytes.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) {
                let alpha = Double(p[i + 3]) / 255
                guard alpha > 0 else { continue }
                let r = Double(p[i]) / alpha, g = Double(p[i + 1]) / alpha, b = Double(p[i + 2]) / alpha
                // Unmatte neutral white, retaining antialiased edges and existing transparency.
                let neutral = max(r, max(g, b)) - min(r, min(g, b)) < 35
                let white = min(r, min(g, b))
                let remaining = neutral ? min(1, max(0, (255 - white) / 100)) : 1
                let newAlpha = alpha * remaining
                p[i + 3] = UInt8(min(255, newAlpha * 255))
                for c in 0..<3 { p[i + c] = UInt8(min(255, max(0, (Double(p[i + c]) / alpha - 255 * (1 - remaining)) * alpha))) }
            }
            return ctx.makeImage()
        }
        guard let result else { throw ConversionError.readFailed }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }
    private func placeSignature(page: PDFPage, point: NSPoint) {
        guard !busy else { return }
        clearTarget()
        let displayBounds = preview.convert(page.bounds(for: .cropBox), from: page)
        let center = preview.convert(point, from: page)
        let aspect = signature.contentAspect
        let width = min(min(180 * signatureScale * preview.scaleFactor, displayBounds.width * 0.9), displayBounds.height / max(0.001, aspect))
        let height = width * aspect
        let displayRect = NSRect(x: min(max(center.x - width / 2, displayBounds.minX), displayBounds.maxX - width), y: min(max(center.y - height / 2, displayBounds.minY), displayBounds.maxY - height), width: width, height: height)
        let annotation = PDFAnnotation(bounds: preview.convert(displayRect, to: page), forType: .square, withProperties: nil)
        annotation.color = .systemBlue
        annotation.interiorColor = .clear
        let border = PDFBorder()
        border.lineWidth = 1.5 / max(0.1, preview.scaleFactor)
        annotation.border = border
        annotation.shouldPrint = false
        page.addAnnotation(annotation)
        signatureTarget = (page, annotation)
        preview.needsDisplay = true
    }
    @objc private func insertSignature() {
        guard !busy else { return }
        signature.endTrackpadCapture()
        do {
            guard let target = signatureTarget else { throw ConversionError.processFailed("Clicca sulla pagina per scegliere dove inserire la firma.") }
            guard let image = signature.renderedImage() else { throw ConversionError.processFailed("Disegna o carica una firma.") }
            let index = pdfDocument.index(for: target.page)
            guard index != NSNotFound, index >= 0, index < pdfDocument.pageCount else { throw ConversionError.readFailed }
            let rect = target.annotation.bounds
            // Work on an independent document: PDFView may still have accessibility nodes for the displayed pages.
            let data = try snapshot()
            guard let edited = PDFDocument(data: data), let page = edited.page(at: index) else { throw ConversionError.readFailed }
            guard let before = page.dataRepresentation else { throw ConversionError.readFailed }
            let signed = try PDFActions.signedPageDocument(page, image: image, rect: rect)
            guard let replacement = signed.page(at: 0)?.copy() as? PDFPage else { throw ConversionError.readFailed }
            edited.removePage(at: index)
            edited.insert(replacement, at: index)
            let finalized: PDFDocument = try withExtendedLifetime(signed) {
                guard let bytes = edited.dataRepresentation(), let result = PDFDocument(data: bytes) else { throw ConversionError.writeFailed("Firma") }
                return result
            }
            guard let after = finalized.page(at: index)?.dataRepresentation else { throw ConversionError.readFailed }
            installSignatureDocument(finalized, selected: index)
            signatureUndo.append(SignatureEdit(index: index, before: before, after: after))
            if signatureUndo.count > 20 { signatureUndo.removeFirst() }
            signatureRedo.removeAll()
            insertedSignatures += 1
            updateSignatureHistoryButtons()
        } catch { showError(error) }
    }

    private func installSignatureDocument(_ document: PDFDocument, selected: Int) {
        let origin = preview.documentView?.enclosingScrollView?.contentView.bounds.origin
        let scale = preview.scaleFactor
        let autoScales = preview.autoScales
        clearTarget()
        restoringSignatureViewport = true
        preview.document = nil
        pdfDocument = document
        refresh(selected: selected, signatureEdit: true)
        if let page = document.page(at: selected) { preview.go(to: page) }
        restoringSignatureViewport = false
        func restoreViewport() {
            guard self.pdfDocument === document else { return }
            self.preview.autoScales = autoScales
            self.preview.scaleFactor = scale
            self.preview.layoutSubtreeIfNeeded()
            if let origin, let scroll = self.preview.documentView?.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        restoreViewport()
        // PDFKit may finish its document layout on the next main-loop iteration.
        DispatchQueue.main.async { restoreViewport() }
    }
    private func updateSignatureHistoryButtons() {
        undoSignatureButton?.isEnabled = !busy && !signatureUndo.isEmpty
        redoSignatureButton?.isEnabled = !busy && !signatureRedo.isEmpty
    }
    @objc private func undoSignature() {
        guard !busy, let edit = signatureUndo.last else { return }
        do {
            try restoreSignaturePage(edit.before, index: edit.index)
            signatureUndo.removeLast()
            signatureRedo.append(edit)
            insertedSignatures = max(0, insertedSignatures - 1)
            updateSignatureHistoryButtons()
        } catch { showError(error) }
    }
    @objc private func redoSignature() {
        guard !busy, let edit = signatureRedo.last else { return }
        do {
            try restoreSignaturePage(edit.after, index: edit.index)
            signatureRedo.removeLast()
            signatureUndo.append(edit)
            insertedSignatures += 1
            updateSignatureHistoryButtons()
        } catch { showError(error) }
    }
    private func restoreSignaturePage(_ data: Data, index: Int) throws {
        guard let edited = PDFDocument(data: try snapshot()), index >= 0, index < edited.pageCount,
              let owner = PDFDocument(data: data), let page = owner.page(at: 0)?.copy() as? PDFPage else { throw ConversionError.readFailed }
        edited.removePage(at: index)
        edited.insert(page, at: index)
        let restored: PDFDocument = try withExtendedLifetime(owner) {
            guard let bytes = edited.dataRepresentation(), let result = PDFDocument(data: bytes) else { throw ConversionError.writeFailed("Firma") }
            return result
        }
        installSignatureDocument(restored, selected: index)
    }

    @objc private func qualityChanged() { updateEstimate() }
    private func updateEstimate() {
        estimateWork?.cancel()
        estimateGeneration += 1
        let generation = estimateGeneration
        let value = quality.doubleValue
        compressionPercent.stringValue = "\(Int(value * 100))%"
        if compressionSize.stringValue.isEmpty { compressionSize.stringValue = "..." }
        guard let data = try? snapshot() else { return }
        let source = self.source
        let work = DispatchWorkItem { [weak self] in
            do {
                let compressed = try PDFActions.compressedData(source: source, quality: value, snapshot: data)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.estimateGeneration else { return }
                    self.compressionSize.stringValue = "≈ \(ByteCountFormatter.string(fromByteCount: Int64(compressed.count), countStyle: .file))"
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.estimateGeneration else { return }
                    self.compressionSize.stringValue = "..."
                }
            }
        }
        estimateWork = work
        estimateQueue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func detectText() {
        guard action == .ocrPDF, !busy else { return }
        let index = table.selectedRow
        guard index >= 0, let page = pdfDocument.page(at: index) else { return }
        if let current = ocrPage, ocrCache[current] != nil { ocrCache[current] = recognizedText.string }
        ocrWork?.cancel()
        ocrGeneration += 1
        let generation = ocrGeneration
        ocrPage = index
        if let text = ocrCache[index] {
            recognizedText.string = text
            recognizedText.isEditable = true
            exportButton.isEnabled = true
            exportButton.title = exportTitle
            layoutOCRText()
            recognizedText.scrollToBeginningOfDocument(nil)
            return
        }
        // Serialize only the selected page, never the entire loaded document.
        guard let data = page.dataRepresentation else { return }
        recognizedText.string = ""
        recognizedText.isEditable = false
        exportButton.isEnabled = false
        exportButton.title = "Rilevamento…"
        layoutOCRText()
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try PDFActions.recognizedText(snapshot: data) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.action == .ocrPDF, generation == self.ocrGeneration,
                      self.ocrPage == index else { return }
                self.exportButton.isEnabled = true
                self.exportButton.title = self.exportTitle
                self.recognizedText.isEditable = true
                switch result {
                case .success(let text):
                    self.ocrCache[index] = text
                    self.recognizedText.string = text
                    self.layoutOCRText()
                    self.recognizedText.scrollToBeginningOfDocument(nil)
                case .failure(let error): self.showError(error)
                }
            }
        }
        ocrWork = work
        // Collapse rapid page changes and process at most one page at a time.
        ocrQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func exportPDF() {
        guard !busy else { return }
        do {
            let ranges: [[Int]] = action == .splitPDF ? try PDFActions.groups(range.stringValue, count: pdfDocument.pageCount) : []
            let selected = ranges.flatMap { $0 }
            if action == .signPDF, insertedSignatures == 0 { throw ConversionError.processFailed("Inserisci prima la firma nella pagina.") }
            let snapshot = action == .ocrPDF ? Data() : try self.snapshot()
            let text = recognizedText.string
            let ocrPage = self.ocrPage
            if action == .ocrPDF, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ConversionError.processFailed("Nessun testo da esportare.") }
            let operation = action
            let source = self.source
            let splitMode = self.splitMode.indexOfSelectedItem
            let quality = self.quality.doubleValue
            busy = true
            exportButton.isEnabled = false
            setControlsEnabled(false)
            exportButton.title = "Esportazione…"
            Task { @MainActor [self] in
                defer {
                    busy = false
                    exportButton.isEnabled = true
                    exportButton.title = exportTitle
                    setControlsEnabled(true)
                }
                do {
                    output = try await Task.detached(priority: .userInitiated) {
                        if operation == .compressPDF { return [try PDFActions.compress(source: source, quality: quality, snapshot: snapshot)] }
                        if operation == .ocrPDF { return [try PDFActions.saveText(text, source: source, page: ocrPage)] }
                        guard let doc = PDFDocument(data: snapshot) else { throw ConversionError.readFailed }
                        if operation == .splitPDF {
                            let groups = splitMode == 2 ? selected.map { [$0] } : splitMode == 1 ? ranges : [selected]
                            var results: [URL] = []
                            do {
                                for group in groups {
                                    let part = try PDFActions.extract(doc, indices: group)
                                    results.append(try PDFActions.save(part, source: source, suffix: splitMode == 2 ? "pagina-\(group[0] + 1)" : splitMode == 1 ? "pagine-\(group[0] + 1)-\(group[group.count - 1] + 1)" : "estratto"))
                                }
                            } catch {
                                for url in results { try? FileManager.default.removeItem(at: url) }
                                throw error
                            }
                            return results
                        }
                        return [try PDFActions.save(doc, source: source, suffix: operation == .mergePDF ? "unito" : operation == .signPDF ? "firmato" : "riordinato")]
                    }.value
                    NSSound(named: "Blow")?.play()
                    onExportCompleted?()
                } catch { showError(error) }
            }
        } catch { showError(error) }
    }
    private func setControlsEnabled(_ enabled: Bool) {
        func update(_ view: NSView) {
            (view as? NSControl)?.isEnabled = enabled
            view.subviews.forEach(update)
        }
        update(controls)
        update(sideControls)
        updateSignatureHistoryButtons()
    }
}

