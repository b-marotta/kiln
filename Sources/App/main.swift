import AppKit

// Explicit entry — more reliable than `@main` AppDelegate with plain `swiftc` bundles.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
