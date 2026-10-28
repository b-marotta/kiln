import AppKit
import ImageIO

/// Embedded in the shelf, sharing its glass surface and export lifecycle.
final class ImageEditorWindowController: NSObject, NSTextViewDelegate {
    let editorView: NSView
    var onExportCompleted: (() -> Void)?
    var contentHeight: CGFloat { action == .cropImage ? 380 : action == .upscaleImage ? 480 : action == .compressImage ? 436 : action == .adjustImage ? 528 : 548 }
    private let footer = ImageEditorContentView()
    private weak var controlsContainer: NSView?
    private weak var controlsHost: NSView?
    private let ratioControls = ImageEditorContentView()
    private weak var previewContainer: NSView?
    private var compressionMode = 0
    private let percentage = NSTextField()
    private var ratioText = "Libero"
    private let compare = ImageOriginalButton()
    private weak var compareContainer: NSView?

    private let source: URL
    private var action: FanAction
    private var original: CGImage?
    private var small: CGImage?
    private var adjustments = ImageAdjustments()
    private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var ratio: CGFloat?
    private var quality = 0.8
    private var scale = 1.0
    private var cropFormat: ConversionFormat = .png
    private var outputFormat: ConversionFormat = .png
    private let availableFormats = ImageEditing.exportFormats
    private var encoded: Data?
    private var text: String?
    private var busy = false
    private var generation = 0
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label: "io.leapstudio.kiln.image-editor", qos: .userInitiated)
    private let preview = ImageCropPreview()
    private let controls = ImageEditorContentView()
    private let status = NSTextField(wrappingLabelWithString: "Caricamento…")
    private let exportButton = GlassCenteredIconButton(title: "Esporta PNG", target: nil, action: nil)
    private let recognized = GlassTextView()
    private var sliders: [NSSlider] = []
    private var adjustmentLabels: [Int: (String, NSTextField)] = [:]
    private var originalBytes = 0
    private var upscaleFactor: ImageUpscaleFactor = .x2
    private var upscaleCancellation: ImageUpscaleCancellation?

    deinit { upscaleCancellation?.cancel(); work?.cancel() }

    init(source: URL, action: FanAction, embeddedWidth: CGFloat) {
        self.source = source
        self.action = action
        editorView = ImageEditorContentView(frame: NSRect(x: 0, y: 0, width: embeddedWidth, height: 480))
        super.init()
        outputFormat = availableFormats.first { $0.pathExtension == source.pathExtension.lowercased() || ($0 == .jpeg && ["jpg", "jpeg"].contains(source.pathExtension.lowercased())) } ?? .png
        if source.pathExtension.lowercased() == "heif", availableFormats.contains(.heic) { outputFormat = .heic }
        cropFormat = outputFormat
        build()
        queue.async { [weak self] in
            let result = Result { () -> (CGImage, CGImage, Int) in
                let image = try ImageEditing.load(source)
                let bytes = (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (image, try ImageEditing.thumbnail(image), bytes)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let value):
                    self.original = value.0; self.small = value.1; self.originalBytes = value.2
                    self.preview.magnificationImage = value.0
                    self.buildControls()
                    self.refresh()
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    @discardableResult func selectAction(_ selected: FanAction) -> Bool {
        guard !busy, selected.isImageAction else { return false }
        if action == .ocrImage, text != nil { text = recognized.string }
        action = selected
        if let small { preview.image = small }
        buildControls()
        refresh()
        return true
    }

    private func build() {
        let width = editorView.bounds.width
        preview.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        preview.onCropChange = { [weak self] rect in
            guard let self else { return }
            self.crop = rect
            self.updateCropStatus()
        }
        let previewBox = ImageEditorContentView(frame: NSRect(x: 0, y: 0, width: width, height: 324))
        preview.frame = NSRect(x: 16, y: 12, width: width - 32, height: 276)
        previewBox.addSubview(preview)
        ratioControls.frame = NSRect(x: width - 132, y: 12, width: 116, height: 44)
        previewBox.addSubview(ratioControls)
        status.font = .systemFont(ofSize: 11)
        status.alignment = .center
        status.textColor = LiquidGlass.secondaryText
        status.frame = NSRect(x: 16, y: 292, width: width - 32, height: 20)
        previewBox.addSubview(status)
        previewContainer = LiquidGlass.place(previewBox, in: editorView, frame: previewBox.frame, cornerRadius: 24)
        controlsContainer = addGlassBox(controls, frame: NSRect(x: 0, y: 336, width: width, height: 128))
        controlsHost = controls.superview
        editorView.addSubview(footer)
        compare.title = ""
        compare.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Mostra originale")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        compare.imagePosition = .imageOnly
        compare.imageScaling = .scaleNone
        compare.fixedIconSize = NSSize(width: 12, height: 12)
        compare.isBordered = false
        compare.contentTintColor = LiquidGlass.primaryText
        compare.setAccessibilityLabel("Tieni premuto per mostrare l’originale")
        compare.onHold = { [weak self] held in
            guard let self else { return }
            self.preview.comparisonImage = held ? (self.action == .upscaleImage ? self.original : self.small) : nil
        }
        // Non-interactive glass: press morph reads as a size jump on small chips.
        compareContainer = LiquidGlass.placeControl(
            compare,
            in: preview,
            frame: NSRect(x: preview.bounds.width - 30, y: 6, width: 22, height: 22),
            interactive: false
        )
        exportButton.target = self; exportButton.action = #selector(export)
        buildControls()
    }


    @discardableResult
    private func addGlassBox(_ content: NSView, frame: NSRect, radius: CGFloat = 24, padding: NSSize = NSSize(width: 16, height: 12)) -> NSView {
        let host = GlassContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.frame = host.bounds.insetBy(dx: padding.width, dy: padding.height)
        host.addSubview(content)
        return LiquidGlass.place(host, in: editorView, frame: frame, cornerRadius: radius, interactive: false)
    }

    private func addGlassButton(_ button: NSButton, frame: NSRect, to parent: NSView, interactive: Bool = true) {
        button.alignment = .center
        button.font = .systemFont(ofSize: 13)
        LiquidGlass.placeControl(button, in: parent, frame: frame, interactive: interactive)
    }

    @discardableResult
    private func label(_ title: String, frame: NSRect, parent: NSView? = nil, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: title)
        field.font = .systemFont(ofSize: 11)
        field.textColor = secondary ? LiquidGlass.secondaryText : LiquidGlass.primaryText
        field.frame = frame
        (parent ?? controls).addSubview(field)
        return field
    }

    private func slider(_ title: String, value: Double, min: Double, max: Double, tag: Int, x: CGFloat, y: CGFloat, width: CGFloat) {
        let hasReset = action == .adjustImage
        let percent = Int(((value - min) / (max - min) * 100).rounded())
        // Keep the 22pt reset chip inside the content bounds (no negative y into the glass pad).
        let titleY: CGFloat = hasReset ? y + 3 : y
        let titleLabel = label(hasReset ? "\(title) · \(percent)%" : title, frame: NSRect(x: x, y: titleY, width: width - (hasReset ? 28 : 0), height: 16))
        if hasReset { adjustmentLabels[tag] = (title, titleLabel) }
        if hasReset {
            let reset = GlassCenteredIconButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Ripristina \(title.lowercased())")!, target: self, action: #selector(resetAdjustment(_:)))
            reset.fixedIconSize = NSSize(width: 12, height: 12)
            reset.tag = tag
            reset.title = ""
            reset.imagePosition = .imageOnly
            reset.contentTintColor = LiquidGlass.primaryText
            reset.setAccessibilityLabel("Ripristina \(title.lowercased())")
            addGlassButton(reset, frame: NSRect(x: x + width - 22, y: y, width: 22, height: 22), to: controls, interactive: false)
        }
        let control = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged(_:)))
        control.tag = tag
        control.isContinuous = true
        control.setAccessibilityLabel(title)
        control.frame = NSRect(x: x, y: y + (hasReset ? 26 : 20), width: width, height: 22)
        controls.addSubview(control)
        sliders.append(control)
    }

    private func buildControls() {
        controls.subviews.forEach { $0.removeFromSuperview() }
        sliders = []
        adjustmentLabels = [:]
        let isOCR = action == .ocrImage
        let isCompression = action == .compressImage
        let width = editorView.bounds.width - (isOCR ? 24 : isCompression ? 0 : 32)
        let third = (width - 24) / 3
        ratioControls.subviews.forEach { $0.removeFromSuperview() }
        ratioControls.isHidden = action != .cropImage
        preview.frame.size.width = editorView.bounds.width - 32
        compareContainer?.setFrameOrigin(NSPoint(x: preview.bounds.width - 30, y: 6))
        editorView.setFrameSize(NSSize(width: editorView.bounds.width, height: contentHeight))
        footer.subviews.forEach { $0.removeFromSuperview() }
        let footerHeight: CGFloat = 44
        footer.frame = NSRect(x: 0, y: contentHeight - footerHeight, width: editorView.bounds.width, height: footerHeight)
        previewContainer?.isHidden = false
        status.isHidden = isOCR
        previewContainer?.frame.size.height = isOCR ? 300 : 324

        // Adjust: 16pt glass pad + two 48pt rows with 8pt gap. OCR keeps a tighter inset for the text view.
        let padX: CGFloat = isOCR ? 12 : 16
        let padY: CGFloat = isOCR ? 4 : action == .adjustImage ? 16 : 12
        let optionsHeight: CGFloat = action == .upscaleImage ? 88 : action == .compressImage ? 44 : action == .adjustImage ? 136 : 180
        controlsContainer?.isHidden = action == .cropImage || isCompression
        controlsContainer?.frame = NSRect(x: 0, y: isOCR ? 312 : 336, width: editorView.bounds.width, height: optionsHeight)
        if isCompression {
            if controls.superview !== editorView { controls.removeFromSuperview(); editorView.addSubview(controls) }
            controls.frame = NSRect(x: 0, y: 336, width: width, height: 44)
        } else {
            if controls.superview !== controlsHost { controls.removeFromSuperview(); controlsHost?.addSubview(controls) }
            controlsHost?.frame.size = NSSize(width: editorView.bounds.width, height: optionsHeight)
            controls.frame = NSRect(x: padX, y: padY, width: width, height: optionsHeight - padY * 2)
        }
        addGlassButton(exportButton, frame: NSRect(x: 0, y: 0, width: editorView.bounds.width, height: 44), to: footer)
        let selectedFormat: ConversionFormat = action == .upscaleImage ? .png : action == .cropImage ? cropFormat : outputFormat
        let inputExtension = source.pathExtension.lowercased()
        let sameFormat = selectedFormat.pathExtension == inputExtension || (selectedFormat == .jpeg && ["jpg", "jpeg"].contains(inputExtension)) || (selectedFormat == .heic && ["heic", "heif"].contains(inputExtension))
        exportButton.title = isOCR ? "Esporta TXT" : sameFormat ? "Esporta" : "Esporta \(selectedFormat.pathExtension.uppercased())"

        compare.isHidden = action != .adjustImage && action != .upscaleImage
        compareContainer?.isHidden = action != .adjustImage && action != .upscaleImage
        preview.comparisonImage = nil
        exportButton.isEnabled = false
        preview.cropEnabled = action == .cropImage
        preview.magnificationEnabled = action == .upscaleImage
        preview.magnificationImage = original
        preview.crop = crop
        switch action {
        case .cropImage:
            let mode = NSPopUpButton()
            mode.addItems(withTitles: ["Libero", "1:1", "4:3", "3:2", "16:9", "3:4", "2:3", "9:16"])
            mode.selectItem(withTitle: ratioText)
            mode.target = self; mode.action = #selector(ratioModeChanged(_:))
            mode.font = .systemFont(ofSize: 13)
            mode.alignment = .center
            mode.setAccessibilityLabel("Proporzioni ritaglio")
            LiquidGlass.placeControl(mode, in: ratioControls, frame: ratioControls.bounds, horizontalPadding: 6, verticalPadding: 0)
        case .adjustImage:
            let items: [(String, Double, Double, Double)] = [
                ("Luminosità", adjustments.brightness, -0.5, 0.5), ("Contrasto", adjustments.contrast, 0.25, 2),
                ("Saturazione", adjustments.saturation, 0, 2), ("Esposizione", adjustments.exposure, -3, 3),
                ("Temperatura", adjustments.temperature, 2500, 10000), ("Nitidezza", adjustments.sharpness, 0, 2)]
            // 48pt block (22 reset + 4 gap + 22 slider) + 8pt between rows → fits 16+104+16 glass.
            let rowStride: CGFloat = 56
            for (i, item) in items.enumerated() {
                slider(item.0, value: item.1, min: item.2, max: item.3, tag: i, x: CGFloat(i % 3) * (third + 12), y: CGFloat(i / 3) * rowStride, width: third)
            }
        case .compressImage:
            let rowHeight: CGFloat = 44
            let mode = NSPopUpButton()
            mode.addItems(withTitles: ["Qualità", "Dimensioni"])
            mode.selectItem(at: compressionMode)
            mode.target = self; mode.action = #selector(compressionModeChanged(_:))
            mode.setAccessibilityLabel("Parametro di compressione")
            mode.isBordered = false
            mode.font = .systemFont(ofSize: 13)
            mode.alignment = .center
            LiquidGlass.placeControl(mode, in: controls, frame: NSRect(x: 0, y: 0, width: 118, height: rowHeight), horizontalPadding: 6, verticalPadding: 0)
            let value = compressionMode == 0 ? quality : scale
            let control = NSSlider(value: value, minValue: 0.1, maxValue: 1, target: self, action: #selector(sliderChanged(_:)))
            control.tag = compressionMode == 0 ? 6 : 7
            control.isContinuous = true
            control.setAccessibilityLabel(compressionMode == 0 ? "Qualità" : "Dimensioni")
            LiquidGlass.placeControl(control, in: controls, frame: NSRect(x: 130, y: 0, width: width - 220, height: rowHeight), horizontalPadding: 12, verticalPadding: 4)
            sliders.append(control)
            if !(percentage.cell is ImageEditorCenteredTextFieldCell) {
                let cell = ImageEditorCenteredTextFieldCell(textCell: percentage.stringValue)
                cell.isEditable = true
                cell.isSelectable = true
                cell.isBordered = false
                cell.drawsBackground = false
                cell.font = .systemFont(ofSize: 13)
                cell.textColor = LiquidGlass.primaryText
                cell.alignment = .center
                percentage.cell = cell
            }
            percentage.stringValue = "\(Int((value * 100).rounded()))%"
            percentage.alignment = .center
            percentage.target = self; percentage.action = #selector(percentageChanged(_:))
            percentage.setAccessibilityLabel("Percentuale")
            percentage.isBordered = false
            percentage.drawsBackground = false
            percentage.font = .systemFont(ofSize: 13)
            percentage.textColor = LiquidGlass.primaryText
            LiquidGlass.placeControl(percentage, in: controls, frame: NSRect(x: width - 78, y: 0, width: 78, height: rowHeight), horizontalPadding: 8, verticalPadding: 0)
        case .upscaleImage:
            let picker = NSPopUpButton()
            picker.addItems(withTitles: ImageUpscaleFactor.allCases.map(\.title))
            picker.selectItem(at: ImageUpscaleFactor.allCases.firstIndex(of: upscaleFactor) ?? 0)
            picker.target = self; picker.action = #selector(upscaleFactorChanged(_:))
            picker.font = .systemFont(ofSize: 13)
            picker.setAccessibilityLabel("Fattore upscaling AI")
            LiquidGlass.placeControl(picker, in: controls, frame: NSRect(x: 0, y: 0, width: width, height: 36), horizontalPadding: 8, verticalPadding: 0)
            let credit = label("PiperSR by Ben Racicot / ModelPiper · CC BY 4.0", frame: NSRect(x: 0, y: 44, width: width, height: 16), secondary: true)
            credit.alignment = .center
            credit.toolTip = "https://modelpiper.com · https://creativecommons.org/licenses/by/4.0/"
            picker.toolTip = "PiperSR nativo 2×. 3×, 4× e 5× usano più passaggi; 3× e 5× includono un ridimensionamento Lanczos."
        case .ocrImage:
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: controls.bounds.width, height: controls.bounds.height))
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            recognized.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height)
            recognized.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            recognized.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            recognized.isVerticallyResizable = true
            recognized.isHorizontallyResizable = false
            recognized.autoresizingMask = [.width]
            recognized.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            recognized.textContainer?.widthTracksTextView = true
            recognized.textContainerInset = NSSize(width: 4, height: 8)
            recognized.isRichText = false
            recognized.drawsBackground = false
            recognized.textColor = LiquidGlass.primaryText
            recognized.font = .systemFont(ofSize: 12)
            recognized.delegate = self
            recognized.string = text ?? ""
            recognized.isEditable = true
            recognized.isSelectable = true
            recognized.setAccessibilityLabel("Testo riconosciuto, modificabile")
            scroll.documentView = recognized
            controls.addSubview(scroll)
        default: break
        }
        preview.isEnabled = original != nil
        for slider in sliders { slider.isEnabled = original != nil }
        LiquidGlass.prepareTree(controls)
    }

    private func refresh() {
        generation += 1
        let token = generation
        work?.cancel()
        upscaleCancellation?.cancel()
        encoded = nil
        exportButton.isEnabled = false
        guard let original, let small else { return }
        // Keep the last rendered frame while the replacement is being computed.
        if preview.image == nil || action == .cropImage || action == .ocrImage {
            preview.image = small
        }
        preview.crop = crop
        if action == .upscaleImage { refreshUpscale(original, token: token); return }
        if action == .cropImage { updateCropStatus(); exportButton.isEnabled = true; return }
        if action == .ocrImage, let text {
            recognized.string = text
            recognized.isEditable = true
            status.stringValue = text.isEmpty ? "0 caratteri" : "\(recognized.string.count) caratteri"
            updateTextExport(); return
        }
        status.stringValue = action == .ocrImage ? "Riconoscimento testo…" : "Aggiornamento preview…"
        let operation = action, a = adjustments, q = quality, s = scale, selectedFormat = outputFormat, sourceURL = source
        let job = DispatchWorkItem { [weak self] in
            let result = Result { () -> (CGImage?, Data?, String?, Int, Int) in
                if operation == .ocrImage { return (nil, nil, try ImageEditing.recognize(original), 0, 0) }
                if operation == .adjustImage { return (try ImageEditing.render(small, adjustments: a), nil, nil, original.width, original.height) }
                let output = s == 1 ? original : try ImageEditing.render(original, scale: s)
                let result = try ImageEditing.compress(output, source: sourceURL, format: selectedFormat, quality: q, preserveOriginal: s == 1)
                let decoded: CGImage
                if result.reusedOriginal { decoded = original }
                else {
                    guard let source = CGImageSourceCreateWithData(result.data as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.readFailed }
                    decoded = image
                }
                return (try ImageEditing.thumbnail(decoded), result.data, nil, output.width, output.height)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let result):
                    if let image = result.0 { self.preview.image = image }
                    self.encoded = result.1
                    if operation == .ocrImage {
                        self.text = result.2 ?? ""
                        self.recognized.string = self.text ?? ""
                        self.recognized.isEditable = true
                        self.status.stringValue = self.recognized.string.isEmpty ? "0 caratteri" : "\(self.recognized.string.count) caratteri"
                        self.updateTextExport()
                    } else if let data = result.1 {
                        let savings = self.originalBytes > 0 ? (1 - Double(data.count) / Double(self.originalBytes)) * 100 : 0
                        self.status.stringValue = "\(result.3) × \(result.4) px · \(Self.bytes(data.count)) · " + String(format: "%+.1f%%", -savings)
                        self.exportButton.isEnabled = data.count < self.originalBytes
                    } else {
                        self.status.stringValue = "\(original.width) × \(original.height) px"
                        self.exportButton.isEnabled = true
                    }
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        work = job
        queue.asyncAfter(deadline: .now() + 0.15, execute: job)
    }

    @objc private func upscaleFactorChanged(_ sender: NSPopUpButton) {
        guard !busy, ImageUpscaleFactor.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        upscaleFactor = ImageUpscaleFactor.allCases[sender.indexOfSelectedItem]
        buildControls()
        refresh()
    }

    private func refreshUpscale(_ original: CGImage, token: Int) {
        let cancellation = ImageUpscaleCancellation()
        upscaleCancellation = cancellation
        let factor = upscaleFactor
        preview.image = small
        preview.magnificationImage = original
        status.stringValue = "PiperSR \(factor.title)…"
        queue.async { [weak self] in
            let start = Date()
            let result = Result { () -> (CGImage, CGImage, Data) in
                let output = try ImageUpscaling.upscale(original, factor: factor, cancellation: cancellation) { done, total in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.status.stringValue = "PiperSR \(factor.title) · \(done * 100 / total)%"
                    }
                }
                try cancellation.check()
                return (output, try ImageEditing.thumbnail(output), try ImageEditing.encode(output, format: .png, quality: 1))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let value):
                    self.preview.image = value.1
                    self.preview.magnificationImage = value.0
                    self.encoded = value.2
                    self.exportButton.isEnabled = true
                    self.status.stringValue = "\(value.0.width) × \(value.0.height) px · \(Self.bytes(value.2.count)) · " + String(format: "%.1f s", Date().timeIntervalSince(start))
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    private static func bytes(_ count: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
    private func updateCropStatus() {
        guard let original else { return }
        status.stringValue = "Ritaglio: \(Int((crop.width * CGFloat(original.width)).rounded())) × \(Int((crop.height * CGFloat(original.height)).rounded())) px · originale \(original.width) × \(original.height) px"
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        switch sender.tag {
        case 0: adjustments.brightness = sender.doubleValue
        case 1: adjustments.contrast = sender.doubleValue
        case 2: adjustments.saturation = sender.doubleValue
        case 3: adjustments.exposure = sender.doubleValue
        case 4: adjustments.temperature = sender.doubleValue
        case 5: adjustments.sharpness = sender.doubleValue
        case 6: quality = sender.doubleValue
        case 7: scale = sender.doubleValue
        default: break
        }
        if let (title, label) = adjustmentLabels[sender.tag] {
            let percent = Int(((sender.doubleValue - sender.minValue) / (sender.maxValue - sender.minValue) * 100).rounded())
            label.stringValue = "\(title) · \(percent)%"
        }
        if sender.tag == 6 || sender.tag == 7 { percentage.stringValue = "\(Int((sender.doubleValue * 100).rounded()))%" }
        refresh()
    }
    @objc private func resetAdjustment(_ sender: NSButton) {
        guard !busy, action == .adjustImage,
              let slider = sliders.first(where: { $0.tag == sender.tag }) else { return }
        let defaults = ImageAdjustments()
        let values = [defaults.brightness, defaults.contrast, defaults.saturation,
                      defaults.exposure, defaults.temperature, defaults.sharpness]
        guard values.indices.contains(sender.tag) else { return }
        slider.doubleValue = values[sender.tag]
        sliderChanged(slider)
    }

    @objc private func compressionModeChanged(_ sender: NSPopUpButton) {
        compressionMode = sender.indexOfSelectedItem
        buildControls()
        refresh()
    }
    @objc private func percentageChanged(_ sender: NSTextField) {
        let raw = sender.stringValue.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let number = Double(raw), number.isFinite, let slider = sliders.first else {
            sender.stringValue = "\(Int(((compressionMode == 0 ? quality : scale) * 100).rounded()))%"
            return
        }
        slider.doubleValue = max(0.1, min(1, number / 100))
        sliderChanged(slider)
    }
    @objc private func ratioModeChanged(_ sender: NSPopUpButton) {
        let input = NSTextField(string: sender.titleOfSelectedItem ?? "Libero")
        ratioChanged(input)
        buildControls()
        refresh()
    }
    @objc private func ratioChanged(_ sender: NSTextField) {
        guard let original else { return }
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased() == "libero" || value.isEmpty {
            ratio = nil; ratioText = "Libero"
        } else {
            let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
                  w.isFinite, h.isFinite, w > 0, h > 0, (w / h).isFinite,
                  min(w / h, 1) * Double(original.width) >= 1,
                  min(h / w, 1) * Double(original.height) >= 1 else { sender.stringValue = ratioText; return }
            ratio = CGFloat(w / h); ratioText = value
        }
        sender.stringValue = ratioText
        preview.normalizedRatio = ratio.map { $0 * CGFloat(original.height) / CGFloat(original.width) }
        if let r = preview.normalizedRatio {
            let width = min(1, r), height = min(1, 1 / r)
            crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
        preview.crop = crop
        updateCropStatus()
    }
    func textDidChange(_ notification: Notification) {
        text = recognized.string
        generation += 1
        work?.cancel()
        updateTextExport()
    }
    private func updateTextExport() { exportButton.isEnabled = !busy && !recognized.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @objc private func export() {
        guard !busy, let original, exportButton.isEnabled else { return }
        let operation = action, a = adjustments, rect = crop, selectedFormat: ConversionFormat = action == .upscaleImage ? .png : action == .cropImage ? cropFormat : outputFormat, q = quality, cached = encoded
        let txt = recognized.string, source = source, selectedUpscaleFactor = upscaleFactor
        generation += 1; work?.cancel()
        busy = true
        setEnabled(false)
        status.stringValue = "Esportazione…"
        queue.async { [self] in
            let result = Result { () -> URL in
                if operation == .ocrImage { return try ImageEditing.save(Data(txt.utf8), source: source, suffix: "testo", ext: "txt") }
                let data: Data
                if operation == .compressImage || operation == .upscaleImage {
                    guard let cached else { throw ConversionError.processFailed("Attendi il completamento dell’elaborazione.") }
                    data = cached
                } else {
                    let image = try ImageEditing.render(original, crop: operation == .cropImage ? rect : CGRect(x: 0, y: 0, width: 1, height: 1), adjustments: operation == .adjustImage ? a : .init())
                    data = try ImageEditing.encode(image, format: selectedFormat, quality: q)
                }
                let suffix = operation == .upscaleImage ? selectedUpscaleFactor.suffix : operation == .cropImage ? "ritaglio" : operation == .compressImage ? "compresso" : "modificata"
                return try ImageEditing.save(data, source: source, suffix: suffix, ext: selectedFormat.pathExtension)
            }
            DispatchQueue.main.async { [self] in
                busy = false
                setEnabled(true)
                switch result {
                case .success(let url): status.stringValue = "Salvato: \(url.lastPathComponent)"; NSSound(named: "Blow")?.play(); onExportCompleted?()
                case .failure(let error): status.stringValue = error.localizedDescription
                }
            }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        func update(_ view: NSView) {
            (view as? NSControl)?.isEnabled = enabled
            view.subviews.forEach(update)
        }
        update(editorView)
        preview.isEnabled = enabled
        recognized.isEditable = enabled && text != nil
        sliders.first(where: { $0.tag == 6 })?.isEnabled = enabled && original != nil
    }
}

