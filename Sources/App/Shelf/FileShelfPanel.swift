import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

final class FileShelfPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
}

