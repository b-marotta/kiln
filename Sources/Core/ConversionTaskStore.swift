import AppKit
import Combine
import Foundation

final class ConversionTaskStore: ObservableObject {
    struct TaskItem: Identifiable {
        let id = UUID()
        let source: URL
        let action: FanAction
        var status: Status
        var outputs: [URL] = []
        var errorMessage: String?

        enum Status {
            case queued
            case running
            case succeeded
            case failed
        }
    }

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    private var pendingBatches: [UUID: [URL]] = [:]
    var onImageAction: (([URL], FanAction) -> Void)?
    var onPDFAction: (([URL], FanAction) -> Void)?
    private var audioEditor: AudioEditorWindowController?

    func enqueue(urls: [URL], action: FanAction) {
        guard !urls.isEmpty else { return }
        if action.isImageAction {
            onImageAction?(urls, action)
            return
        }
        if action.isPDFAction {
            onPDFAction?(urls, action)
            return
        }
        if AudioEditOperation(action: action) != nil {
            guard urls.count == 1, FileKind.classify(url: urls[0]).isAudio else { return }
            audioEditor?.close()
            let editor = AudioEditorWindowController(source: urls[0], action: action)
            audioEditor = editor
            editor.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Instant file actions — MainActor only, no queue.
        switch action {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        case .copyPath:
            let paths = urls.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
            return
        case .copyFiles:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            return
        case .airDrop:
            do { try SharingActions.airDrop(urls: urls) }
            catch { lastError = error.localizedDescription }
            return
        case .openInTerminal:
            do { try TerminalActions.open(urls: urls) }
            catch { lastError = error.localizedDescription }
            return
        case .floatFiles:
            FloatWindowController.shared.float(urls: urls)
            return
        default:
            break
        }

        tasks.insert(
            TaskItem(source: urls[0], action: action, status: .queued),
            at: 0
        )
        let id = tasks[0].id
        pendingBatches[id] = urls
        runQueue()
    }

    private func runQueue() {
        guard !isBusy else { return }
        isBusy = true

        Task { @MainActor in
            defer { self.isBusy = false }
            while let index = self.tasks.firstIndex(where: { $0.status == .queued }) {
                self.tasks[index].status = .running
                let action = self.tasks[index].action
                let id = self.tasks[index].id
                let sources = self.pendingBatches.removeValue(forKey: id) ?? [self.tasks[index].source]
                do {
                    let outs = try await Task.detached(priority: .userInitiated) {
                        try ConversionEngine.perform(action: action, sources: sources)
                    }.value
                    self.tasks[index].status = .succeeded
                    self.tasks[index].outputs = outs
                    Self.playOutputCreatedSound()
                } catch {
                    self.tasks[index].status = .failed
                    self.tasks[index].errorMessage = error.localizedDescription
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Soft cue when conversion output lands on disk.
    private static func playOutputCreatedSound() {
        guard let sound = NSSound(named: "Blow") else { return }
        sound.volume = 0.25
        sound.play()
    }
}
