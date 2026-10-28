import AppKit

final class FloatWindowController: NSObject {
    static let shared = FloatWindowController()

    private var windows: [NSWindow] = []

    func float(urls: [URL]) {
        for url in urls.prefix(8) {
            let panel = NSPanel(
                contentRect: NSRect(x: 120, y: 120, width: 420, height: 320),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = url.lastPathComponent
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false

            if let image = NSImage(contentsOf: url) {
                let imageView = NSImageView(frame: .zero)
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.autoresizingMask = [.width, .height]
                panel.contentView = imageView
            } else {
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
                let label = NSTextField(labelWithString: url.path)
                label.frame = NSRect(x: 16, y: 140, width: 388, height: 40)
                label.lineBreakMode = .byTruncatingMiddle
                container.addSubview(label)
                panel.contentView = container
            }

            panel.center()
            panel.makeKeyAndOrderFront(nil)
            windows.append(panel)
        }
    }
}
