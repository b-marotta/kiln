import AppKit
import AVFoundation
import Carbon.HIToolbox

/// One file, one effect at a time. Preview and export share the rendered audio.
final class AudioEditorWindowController: NSWindowController, NSWindowDelegate, AVAudioPlayerDelegate, NSTextFieldDelegate {
    private let source: URL
    private var settings: AudioEditSettings
    private var duration: Double = 0
    private var job: AudioEditJob?
    private var ready = false
    private var busy = false
    private var closed = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var cachedPreview: URL?
    private var cachedSettings: AudioEditSettings?
    private var previewGeneration = 0
    private var preparingPreview = false
    private var waitingForPreview = false
    private var previewWorkItem: DispatchWorkItem?
    private var lastExport: URL?
    let editorView: NSView
    static let embeddedHeight: CGFloat = 324
    var contentHeight: CGFloat { Self.embeddedHeight + (settings.operation == .speed || settings.operation == .pitch ? 48 : 0) }
    var onContentHeightChange: ((CGFloat) -> Void)?
    var onExportCompleted: (() -> Void)?
    private var hostWindow: NSWindow? { editorView.window }

    private let waveform = AudioWaveformView()
    private let operation = NSPopUpButton()
    private let slider = NSSlider(value: 0, minValue: -12, maxValue: 12, target: nil, action: nil)
    private let parameter = NSTextField(labelWithString: "")
    private let speedSlider = NSSlider(value: 1, minValue: 0.05, maxValue: 2, target: nil, action: nil)
    private let speedParameter = NSTextField(labelWithString: "1.00×")
    private var speedSliderBox: NSView?
    private var speedButtonBoxes: [NSView] = []
    private var pitchButtonBoxes: [NSView] = []
    private var pitchButtons: [NSButton] = []
    private var pitchBox: NSView?
    private var trimBox: NSView?
    private var preservePitchBox: NSView?
    private var revealContainer: NSView?
    private var speedButtons: [NSButton] = []
    private let resetVolume = GlassCenteredIconButton(title: "Reset", target: nil, action: nil)
    private weak var resetVolumeContainer: NSView?
    private let preservePitch = GlassCenteredIconButton(title: "Tonalità", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "Premi Play o la barra spaziatrice per ascoltare l’anteprima.")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let play = GlassCenteredIconButton(title: "Play", target: nil, action: nil)
    private let exportButton = GlassCenteredIconButton(title: "Esporta", target: nil, action: nil)
    private let format = NSPopUpButton()
    private let reveal = GlassCenteredIconButton(title: "Mostra nel Finder", target: nil, action: nil)
    private let clock = NSTextField(labelWithString: "00:00.000")
    private let loadingIndicator = NSProgressIndicator()
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let startLabel = NSTextField(labelWithString: "Inizio")
    private let endLabel = NSTextField(labelWithString: "Fine")

    init(source: URL, action: FanAction, embeddedWidth: CGFloat? = nil) {
        self.source = source
        settings = AudioEditSettings(operation: AudioEditOperation(action: action) ?? .trim)
        editorView = AudioEditorContentView(frame: NSRect(x: 0, y: 0, width: embeddedWidth ?? 704, height: Self.embeddedHeight))
        let editorWindow: NSWindow?
        if embeddedWidth == nil {
            let window = NSWindow(contentRect: editorView.bounds,
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Editor audio · \(source.lastPathComponent)"
            window.isReleasedWhenClosed = false
            editorWindow = window
        } else {
            editorWindow = nil
        }
        super.init(window: editorWindow)
        editorWindow?.delegate = self
        if let editorWindow { editorWindow.contentView = editorView }
        buildInterface(embedded: embeddedWidth != nil)
        editorWindow?.center()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.editorView.window != nil, self.hostWindow?.isKeyWindow == true,
                  event.keyCode == UInt16(kVK_Space),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(self.hostWindow?.firstResponder is NSTextView)
            else { return event }
            if !event.isARepeat { self.togglePlayback() }
            return nil
        }
        loadAudio()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        previewWorkItem?.cancel()
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        job?.cancel()
    }

    private func buildInterface(embedded: Bool) {
        let root = editorView
        let width = root.bounds.width
        let sideWidth: CGFloat = 136
        let gap: CGFloat = 12
        let trackWidth = width - sideWidth - gap
        @discardableResult
        func box(_ content: NSView, frame: NSRect, radius: CGFloat = 24, interactive: Bool = false) -> NSView {
            // Panels share the same non-interactive glass as image/PDF; controls stay interactive below.
            LiquidGlass.place(content, in: root, frame: frame, cornerRadius: radius, interactive: interactive)
        }
        @discardableResult
        func controlBox(_ control: NSView, frame: NSRect, horizontalPadding: CGFloat = 0) -> NSView {
            LiquidGlass.placeControl(control, in: root, frame: frame, horizontalPadding: horizontalPadding)
        }
        operation.addItems(withTitles: AudioEditOperation.allCases.map(\.title))
        operation.selectItem(at: settings.operation.rawValue)
        operation.target = self
        operation.action = #selector(operationChanged)

        let track = AudioEditorContentView(frame: NSRect(x: 0, y: 0, width: trackWidth, height: 172))
        clock.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        clock.frame = NSRect(x: 16, y: 14, width: 86, height: 22)
        track.addSubview(clock)
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.frame = NSRect(x: 110, y: 17, width: 14, height: 14)
        loadingIndicator.setAccessibilityLabel("Caricamento audio")
        track.addSubview(loadingIndicator)
        rangeLabel.alignment = .right
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rangeLabel.textColor = LiquidGlass.secondaryText
        rangeLabel.frame = NSRect(x: 140, y: 15, width: trackWidth - 156, height: 22)
        track.addSubview(rangeLabel)
        waveform.frame = NSRect(x: 12, y: 44, width: trackWidth - 24, height: 86)
        track.addSubview(waveform)
        hint.textColor = LiquidGlass.secondaryText
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 16, y: 138, width: trackWidth - 32, height: 26)
        track.addSubview(hint)
        box(track, frame: track.bounds)
        waveform.onSelection = { [weak self] start, end in
            guard let self, self.ready, !self.busy else { return }
            self.settings.start = start * self.duration
            self.settings.end = end * self.duration
            self.invalidatePreview()
            self.updateControls()
        }
        waveform.onVolumeChange = { [weak self] points in
            guard let self, self.ready, !self.busy else { return }
            self.settings.volumePoints = points
            self.invalidatePreview()
            self.updateControls()
        }

        play.isBordered = false
        play.target = self
        play.action = #selector(playPressed)
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.imagePosition = .imageLeading
        play.imageHugsTitle = true
        play.alignment = .center
        play.setAccessibilityLabel("Play o pausa · barra spaziatrice")
        let playGlass = controlBox(play, frame: NSRect(x: trackWidth + gap, y: 0, width: sideWidth, height: 50))

        format.addItems(withTitles: AudioExportFormat.allCases.map { "." + $0.rawValue })
        format.isBordered = false
        format.alignment = .center
        format.setAccessibilityLabel("Formato di esportazione")
        let formatGlass = controlBox(format, frame: NSRect(x: trackWidth + gap, y: 62, width: sideWidth, height: 48), horizontalPadding: 6)
        exportButton.target = self
        exportButton.action = #selector(exportPressed)
        exportButton.isBordered = false
        exportButton.alignment = .center
        let exportGlass = controlBox(exportButton, frame: NSRect(x: trackWidth + gap, y: 122, width: sideWidth, height: 50))
        // Let native glass render its effects beyond the rectangular view bounds.
        if LiquidGlass.isLiquidGlassAvailable {
            for glass in [playGlass, formatGlass, exportGlass] {
                if glass.responds(to: NSSelectorFromString("setClipsToBounds:")) {
                    glass.setValue(false, forKey: "clipsToBounds")
                }
            }
        }

        let trimContent = AudioEditorContentView(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        let trimRowY: CGFloat = 11
        let trimRowH: CGFloat = 22
        for label in [startLabel, endLabel] {
            let cell = VerticallyCenteredTextFieldCell(textCell: label.stringValue)
            cell.isEditable = false
            cell.isSelectable = false
            cell.isBordered = false
            cell.drawsBackground = false
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = LiquidGlass.secondaryText
            label.cell = cell
            label.font = .systemFont(ofSize: 11)
            label.textColor = LiquidGlass.secondaryText
        }
        startLabel.frame = NSRect(x: 16, y: trimRowY, width: 44, height: trimRowH)
        endLabel.frame = NSRect(x: 200, y: trimRowY, width: 36, height: trimRowH)
        for field in [startField, endField] {
            let cell = VerticallyCenteredTextFieldCell(textCell: "")
            cell.isEditable = true
            cell.isSelectable = true
            cell.isBordered = false
            cell.drawsBackground = false
            cell.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            cell.textColor = LiquidGlass.primaryText
            cell.alignment = .left
            field.cell = cell
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            field.textColor = LiquidGlass.primaryText
            field.alignment = .left
            field.delegate = self
        }
        startField.frame = NSRect(x: 64, y: trimRowY, width: 120, height: trimRowH)
        endField.frame = NSRect(x: 240, y: trimRowY, width: 120, height: trimRowH)
        startField.stringValue = Self.time(settings.start)
        endField.stringValue = Self.time(settings.end)
        startField.setAccessibilityLabel("Inizio selezione")
        endField.setAccessibilityLabel("Fine selezione")
        for view in [startLabel, startField, endLabel, endField] { trimContent.addSubview(view) }
        trimBox = box(trimContent, frame: NSRect(x: 0, y: 184, width: width, height: 44), radius: 22, interactive: true)

        let pitchContent = AudioEditorContentView(frame: trimContent.bounds)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(parameterChanged)
        slider.frame = NSRect(x: 16, y: 8, width: width - 202, height: 28)
        pitchContent.addSubview(slider)
        parameter.frame = NSRect(x: width - 174, y: 10, width: 158, height: 26)
        parameter.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        parameter.alignment = .right
        pitchContent.addSubview(parameter)
        pitchBox = box(pitchContent, frame: NSRect(x: 0, y: 184, width: width, height: 44), radius: 22, interactive: true)

        let speedContent = AudioEditorContentView(frame: NSRect(x: 0, y: 0, width: trackWidth, height: 44))
        speedSlider.frame = NSRect(x: 14, y: 8, width: trackWidth - 130, height: 28)
        speedSlider.target = self
        speedSlider.action = #selector(speedSliderChanged)
        speedSlider.isContinuous = true
        speedSlider.setAccessibilityLabel("Velocità da 0.05 a 2 volte")
        speedContent.addSubview(speedSlider)
        speedParameter.frame = NSRect(x: trackWidth - 104, y: 10, width: 88, height: 26)
        speedParameter.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        speedParameter.alignment = .right
        speedContent.addSubview(speedParameter)
        speedSliderBox = box(speedContent, frame: NSRect(x: 0, y: 184, width: trackWidth, height: 44), radius: 22, interactive: true)

        let pitchCheckContent = AudioEditorContentView(frame: NSRect(x: 0, y: 0, width: sideWidth, height: 44))
        preservePitch.target = self
        preservePitch.action = #selector(preservePitchChanged)
        preservePitch.isBordered = false
        preservePitch.font = .systemFont(ofSize: 12, weight: .semibold)
        preservePitch.imagePosition = .imageLeading
        preservePitch.imageHugsTitle = true
        preservePitch.alignment = .center
        preservePitch.toolTip = "Disattiva per far cambiare la tonalità insieme alla velocità."
        preservePitch.setAccessibilityLabel("Mantieni tonalità")
        preservePitch.frame = pitchCheckContent.bounds.insetBy(dx: 4, dy: 4)
        preservePitch.autoresizingMask = [.width, .height]
        pitchCheckContent.addSubview(preservePitch)
        syncPreservePitchButton()
        preservePitchBox = box(pitchCheckContent, frame: NSRect(x: trackWidth + gap, y: 184, width: sideWidth, height: 44), radius: 22, interactive: true)

        let deltas = [-50, -25, -5, 5, 25, 50]
        let titles = ["−0.5", "−0.25", "−0.05", "+0.05", "+0.25", "+0.5"]
        let buttonGap: CGFloat = 8
        let buttonWidth = (width - buttonGap * 5) / 6
        for (index, delta) in deltas.enumerated() {
            let button = GlassCenteredIconButton(title: titles[index], target: self, action: #selector(adjustSpeed(_:)))
            button.tag = delta
            button.isBordered = false
            button.alignment = .center
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.setAccessibilityLabel("Modifica velocità di \(titles[index])")
            let glass = controlBox(button, frame: NSRect(x: CGFloat(index) * (buttonWidth + buttonGap), y: 240, width: buttonWidth, height: 36))
            speedButtons.append(button)
            speedButtonBoxes.append(glass)
        }

        let pitchDeltas = [-12, -5, -1, 1, 5, 12]
        for (index, delta) in pitchDeltas.enumerated() {
            let title = delta > 0 ? "+\(delta)" : "−\(-delta)"
            let button = GlassCenteredIconButton(title: title, target: self, action: #selector(adjustPitch(_:)))
            button.tag = delta
            button.isBordered = false
            button.alignment = .center
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            button.setAccessibilityLabel("Modifica tonalità di \(title) semitoni")
            let glass = controlBox(button, frame: NSRect(x: CGFloat(index) * (buttonWidth + buttonGap), y: 240, width: buttonWidth, height: 36))
            pitchButtons.append(button)
            pitchButtonBoxes.append(glass)
        }

        resetVolume.target = self
        resetVolume.action = #selector(resetVolumePressed)
        resetVolume.isBordered = false
        resetVolume.font = .systemFont(ofSize: 13, weight: .semibold)
        resetVolume.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        resetVolume.imagePosition = .imageLeading
        resetVolume.imageHugsTitle = true
        resetVolume.alignment = .center
        resetVolume.setAccessibilityLabel("Ripristina il pallino centrale del volume al 100%")
        resetVolumeContainer = controlBox(resetVolume, frame: NSRect(x: 0, y: 184, width: 110, height: 36))
        status.font = .systemFont(ofSize: 12)
        status.textColor = LiquidGlass.secondaryText
        status.frame = NSRect(x: 0, y: 280, width: width - 180, height: 40)
        root.addSubview(status)
        reveal.target = self
        reveal.action = #selector(revealExport)
        reveal.isBordered = false
        revealContainer = controlBox(reveal, frame: NSRect(x: width - 168, y: 280, width: 168, height: 32))
        revealContainer?.isHidden = true
        updateControls()
    }

    private func loadAudio() {
        do {
            let job = try AudioEditJob()
            self.job = job
            let source = self.source
            setBusy(true)
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try AudioEditorMedia.load(source: source, job: job) }
                }.value
                guard let self, !self.closed else { return }
                self.setBusy(false)
                switch result {
                case .success(let data):
                    self.duration = data.duration
                    self.settings.end = data.duration
                    self.waveform.peaks = data.peaks
                    self.ready = true
                    self.status.stringValue = ""
                    self.updateControls()
                    self.preloadPreview()
                case .failure(let error): self.showError(error)
                }
            }
        } catch { showError(error) }
    }

    private func setBusy(_ value: Bool) {
        busy = value
        status.textColor = LiquidGlass.secondaryText
        status.stringValue = ""
        updateControls()
    }

    private func updateControls() {
        let enabled = ready && !busy
        if busy || preparingPreview || waitingForPreview {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        operation.isEnabled = enabled
        let previewReady = cachedSettings == settings && cachedPreview != nil && player != nil
        play.isEnabled = enabled && previewReady
        exportButton.isEnabled = enabled && previewReady
        format.isEnabled = enabled
        slider.isEnabled = enabled
        let isSpeed = settings.operation == .speed
        speedSliderBox?.isHidden = !isSpeed
        for box in speedButtonBoxes { box.isHidden = !isSpeed }
        for box in pitchButtonBoxes { box.isHidden = settings.operation != .pitch }
        for button in pitchButtons {
            button.isEnabled = enabled && (button.tag < 0 ? settings.semitones > -12 : settings.semitones < 12)
        }
        pitchBox?.isHidden = settings.operation != .pitch
        trimBox?.isHidden = settings.operation != .trim
        preservePitchBox?.isHidden = !isSpeed
        speedSlider.isEnabled = enabled
        speedSlider.doubleValue = settings.speed
        speedParameter.stringValue = String(format: "%.2f×", settings.speed)
        for button in speedButtons {
            button.isEnabled = enabled && (button.tag < 0 ? settings.speed > 0.05 : settings.speed < 2)
        }
        resetVolume.isEnabled = enabled
        resetVolumeContainer?.isHidden = settings.operation != .volume
        preservePitch.isEnabled = enabled
        preservePitch.isHidden = settings.operation != .speed
        syncPreservePitchButton()
        let offset: CGFloat = isSpeed || settings.operation == .pitch ? 48 : 0
        status.frame.origin.y = 280 + offset
        revealContainer?.frame.origin.y = 280 + offset
        // Keep fields enabled so borderless text stays full-opacity on glass;
        // gate typing with isEditable instead of isEnabled.
        startField.isEnabled = true
        endField.isEnabled = true
        startField.isEditable = enabled
        endField.isEditable = enabled
        startField.isSelectable = enabled
        endField.isSelectable = enabled
        waveform.isInteractive = enabled && (settings.operation == .trim || settings.operation == .volume)
        waveform.volumePoints = settings.operation == .volume ? settings.volumePoints : nil
        waveform.setAccessibilityLabel(settings.operation == .volume
            ? "Curva del volume. Trascina i punti, clicca lontano da un punto per aggiungerne uno. In alto 100%, in basso silenzio."
            : "Waveform audio. Trascina i bordi o usa i campi Inizio e Fine per selezionare il taglio.")
        waveform.showsSelectionBackground = settings.operation == .trim
        waveform.selection = settings.operation == .trim && duration > 0
            ? settings.start / duration ... settings.end / duration : 0...1
        waveform.minimumSelection = duration > 0 ? min(1, 0.01 / duration) : 1
        let trim = settings.operation == .trim
        for view in [startField, endField, startLabel, endLabel] as [NSView] { view.isHidden = !trim }
        if startField.currentEditor() == nil {
            startField.stringValue = Self.time(settings.start)
        }
        if endField.currentEditor() == nil {
            endField.stringValue = Self.time(settings.end)
        }
        slider.isHidden = settings.operation != .pitch
        parameter.isHidden = slider.isHidden
        switch settings.operation {
        case .pitch:
            slider.minValue = -12; slider.maxValue = 12; slider.doubleValue = settings.semitones
            slider.setAccessibilityLabel("Tonalità in semitoni")
            parameter.stringValue = String(format: "%+.1f semitoni", settings.semitones)
        default: break
        }
        let resultDuration = settings.operation == .trim ? settings.end - settings.start
            : settings.operation == .speed ? duration / settings.speed : duration
        // Trim and speed change length; pitch / reverse / volume keep the same duration.
        rangeLabel.stringValue = resultDuration == duration
            ? Self.time(duration)
            : "\(Self.time(duration)) → \(Self.time(resultDuration))"
        waveform.needsDisplay = true
        let oldHeight = editorView.frame.height
        if oldHeight != contentHeight {
            editorView.setFrameSize(NSSize(width: editorView.frame.width, height: contentHeight))
            if let window {
                var frame = window.frame
                frame.origin.y -= contentHeight - oldHeight
                frame.size.height += contentHeight - oldHeight
                window.setFrame(frame, display: true)
            }
            onContentHeightChange?(contentHeight)
        }
    }

    @objc private func operationChanged() {
        settings.operation = AudioEditOperation(rawValue: operation.indexOfSelectedItem) ?? .trim
        invalidatePreview()
        updateControls()
    }

    @discardableResult
    func selectAction(_ action: FanAction) -> Bool {
        guard !closed, (!busy || !ready), let selected = AudioEditOperation(action: action) else { return false }
        guard settings.operation != selected else { return true }
        settings.operation = selected
        operation.selectItem(at: selected.rawValue)
        if ready { invalidatePreview() }
        updateControls()
        return true
    }

    @objc private func parameterChanged() {
        if settings.operation == .pitch { settings.semitones = (slider.doubleValue * 10).rounded() / 10 }
        invalidatePreview()
        updateControls()
    }

    @objc private func speedSliderChanged() { setSpeed(speedSlider.doubleValue) }

    @objc private func adjustPitch(_ sender: NSButton) {
        guard ready, !busy, settings.operation == .pitch else { return }
        let value = min(12, max(-12, settings.semitones + Double(sender.tag)))
        guard value != settings.semitones else { return }
        settings.semitones = value
        invalidatePreview()
        updateControls()
    }

    @objc private func adjustSpeed(_ sender: NSButton) { setSpeed(settings.speed + Double(sender.tag) / 100) }

    private func setSpeed(_ value: Double) {
        guard ready, !busy, settings.operation == .speed else { return }
        let value = min(2, max(0.05, (value * 100).rounded() / 100))
        guard value != settings.speed else { return }
        settings.speed = value
        invalidatePreview()
        updateControls()
    }

    @objc private func preservePitchChanged() {
        guard ready, !busy, settings.operation == .speed else { return }
        settings.preservePitch.toggle()
        invalidatePreview()
        updateControls()
    }

    private func syncPreservePitchButton() {
        let on = settings.preservePitch
        preservePitch.image = NSImage(
            systemSymbolName: on ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: nil
        )
        preservePitch.contentTintColor = on ? LiquidGlass.primaryText : LiquidGlass.secondaryText
        preservePitch.setAccessibilityValue(on ? "attivo" : "disattivo")
    }

    @objc private func resetVolumePressed() {
        guard ready, !busy, settings.operation == .volume else { return }
        settings.volumePoints = AudioVolumePoint.initial
        invalidatePreview()
        updateControls()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard ready, !busy else { return }
        let minimum = min(duration, 0.01)
        let start = Self.parseTime(startField.stringValue)
        let end = Self.parseTime(endField.stringValue)
        if let start, let end {
            settings.start = min(max(0, start), duration - minimum)
            settings.end = min(duration, max(settings.start + minimum, end))
            invalidatePreview()
        }
        updateControls()
    }

    private func invalidatePreview() {
        previewGeneration += 1
        stopPlayback(clearPlayer: true)
        if let cachedPreview { try? FileManager.default.removeItem(at: cachedPreview) }
        cachedPreview = nil
        cachedSettings = nil
        status.textColor = LiquidGlass.secondaryText
        status.stringValue = ""
        preloadPreview(delay: 0.18)
    }

    private func preloadPreview(delay: TimeInterval = 0) {
        previewWorkItem?.cancel()
        guard ready, !closed else { return }
        waitingForPreview = true
        updateControls()
        let work = DispatchWorkItem { [weak self] in self?.preparePreview() }
        previewWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func playPressed() { togglePlayback() }

    private func togglePlayback() {
        guard ready, !busy else { return }
        hostWindow?.makeFirstResponder(waveform)
        guard cachedSettings == settings, let player else { return }
        if player.isPlaying {
            player.pause()
            timer?.invalidate(); timer = nil
            setPlayButtonPlaying(false)
            return
        }
        startPlayback()
    }

    @objc private func exportPressed() {
        // Commit a still-focused time field before taking the settings snapshot.
        hostWindow?.makeFirstResponder(waveform)
        guard ready, !busy else { return }
        guard cachedSettings == settings, let cachedPreview else { return }
        stopPlayback()
        let selected = AudioExportFormat.allCases[format.indexOfSelectedItem]
        exportAudio(cachedPreview, format: selected)
    }

    private func preparePreview() {
        guard let job, ready, !closed, !busy, !preparingPreview else { return }
        guard cachedSettings != settings || player == nil else {
            waitingForPreview = false
            updateControls()
            return
        }
        previewWorkItem?.cancel()
        previewWorkItem = nil
        waitingForPreview = false
        let snapshot = settings
        let generation = previewGeneration
        preparingPreview = true
        status.stringValue = ""
        updateControls()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AudioEditorMedia.render(settings: snapshot, job: job) }
            }.value
            guard let self, !self.closed else { return }
            self.preparingPreview = false
            guard generation == self.previewGeneration else {
                if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                self.preparePreview()
                return
            }
            switch result {
            case .success(let url):
                self.cachedPreview = url
                self.cachedSettings = snapshot
                self.finishPreview(url)
            case .failure(let error): self.showError(error)
            }
            self.updateControls()
        }
    }

    private func finishPreview(_ url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            guard player?.prepareToPlay() == true else {
                player = nil
                throw ConversionError.processFailed("Impossibile preparare l’anteprima")
            }
            status.textColor = LiquidGlass.secondaryText
            status.stringValue = ""
        } catch { showError(error) }
    }

    private func startPlayback() {
        guard let player else { return }
        // After a natural end, AVAudioPlayer can sit at duration until reset;
        // prepare again so the next play starts on the first sample immediately.
        if player.currentTime >= player.duration - 0.001 { player.currentTime = 0 }
        guard player.prepareToPlay(), player.play() else {
            showError(ConversionError.processFailed("Impossibile riprodurre l’anteprima"))
            return
        }
        setPlayButtonPlaying(true)
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.updatePlayhead() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePlayhead() {
        guard let player else { return }
        // Don't wait for audioPlayerDidFinishPlaying — it can lag after the last sample.
        if !player.isPlaying || (player.duration > 0 && player.currentTime >= player.duration - 0.001) {
            finishPlaybackToStart()
            return
        }
        clock.stringValue = Self.time(player.currentTime)
        let progress = player.duration > 0 ? player.currentTime / player.duration : 0
        let sourceProgress = settings.operation == .reverse ? 1 - progress : progress
        let lower = waveform.selection.lowerBound
        waveform.playhead = lower + sourceProgress * (waveform.selection.upperBound - lower)
    }

    private func stopPlayback(clearPlayer: Bool = false) {
        if player?.isPlaying == true { player?.stop() }
        player?.currentTime = 0
        if clearPlayer { player = nil }
        timer?.invalidate(); timer = nil
        setPlayButtonPlaying(false)
        clock.stringValue = "00:00.000"
        waveform.playhead = nil
    }

    /// Snap transport to the start as soon as the buffer ends (timer or delegate).
    private func finishPlaybackToStart() {
        guard timer != nil || play.title == "Pausa" else { return }
        stopPlayback()
    }

    private func setPlayButtonPlaying(_ playing: Bool) {
        play.title = playing ? "Pausa" : "Play"
        play.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlaybackToStart()
        if !flag { showError(ConversionError.processFailed("Riproduzione interrotta")) }
    }

    private func exportAudio(_ preview: URL, format: AudioExportFormat) {
        guard let job else { return }
        let source = self.source
        let operation = settings.operation
        setBusy(true)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AudioEditorMedia.export(preview: preview, source: source, operation: operation, format: format, job: job) }
            }.value
            guard let self, !self.closed else { return }
            self.setBusy(false)
            switch result {
            case .success(let output):
                self.lastExport = output
                self.revealContainer?.isHidden = false
                self.status.stringValue = "Salvato: \(output.lastPathComponent)"
                self.status.toolTip = output.path
                if let onExportCompleted = self.onExportCompleted { onExportCompleted() }
                else { self.close() }
            case .failure(let error): self.showError(error)
            }
        }
    }

    @objc private func revealExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }

    private func showError(_ error: Error) {
        status.stringValue = error.localizedDescription
        status.toolTip = error.localizedDescription
        status.textColor = .systemRed
    }

    func windowWillClose(_ notification: Notification) {
        shutdown()
    }

    func suspendPlayback() { stopPlayback() }

    func shutdown() {
        closed = true
        loadingIndicator.stopAnimation(nil)
        previewWorkItem?.cancel()
        previewWorkItem = nil
        stopPlayback(clearPlayer: true)
        job?.cancel()
        job = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private static func time(_ seconds: Double) -> String {
        let milliseconds = Int(max(0, seconds) * 1000)
        return String(format: "%02d:%02d.%03d", milliseconds / 60000, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    /// Accepts `mm:ss.mmm`, `m:ss`, `mm:ss`, or raw seconds (comma or dot).
    private static func parseTime(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let minutes = Double(parts[0]), minutes.isFinite, minutes >= 0,
                  let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60
            else { return nil }
            return minutes * 60 + seconds
        }
        guard let seconds = Double(text), seconds.isFinite else { return nil }
        return seconds
    }
}

