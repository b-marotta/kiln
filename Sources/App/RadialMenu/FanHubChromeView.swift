import AppKit
import CoreText
import AudioToolbox
import Carbon.HIToolbox
import QuartzCore

/// Center hub labels drawn above Liquid Glass / HUD backdrop.
final class FanHubChromeView: NSView {
    var mode: FanMode = .convert
    var fileLabel: String = ""
    var highlightedAction: FanAction?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let holeRadius = min(bounds.width, bounds.height) / 2
        let maxWidth = holeRadius * 1.7

        let iconSize: CGFloat = highlightedAction == nil ? 18 : 14
        let iconGap: CGFloat = 4
        let titleGap: CGFloat = 2

        let modeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: highlightedAction == nil ? 12 : 9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(highlightedAction == nil ? 0.95 : 0.65)
        ]
        let actionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let fileAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]

        let modeText = mode.title
        let modeSize = modeText.size(withAttributes: modeAttrs)
        let actionText = highlightedAction?.title
        let actionSize = actionText?.size(withAttributes: actionAttrs) ?? .zero
        let fileText = highlightedAction == nil ? truncatedFileLabel(maxWidth: maxWidth, attributes: fileAttrs) : ""
        let fileSize = fileText.isEmpty ? .zero : (fileText as NSString).size(withAttributes: fileAttrs)

        var stackH = iconSize + iconGap + modeSize.height
        if actionText != nil { stackH += titleGap + actionSize.height }
        if !fileText.isEmpty && highlightedAction == nil { stackH += titleGap + fileSize.height }

        var y = c.y + stackH / 2
        let iconRect = NSRect(x: c.x - iconSize / 2, y: y - iconSize, width: iconSize, height: iconSize)
        drawHubIcon(in: iconRect)
        y = iconRect.minY - iconGap

        y -= modeSize.height
        modeText.draw(
            at: NSPoint(x: c.x - min(modeSize.width, maxWidth) / 2, y: y),
            withAttributes: modeAttrs
        )

        if let actionText {
            y -= titleGap + actionSize.height
            actionText.draw(
                at: NSPoint(x: c.x - min(actionSize.width, maxWidth) / 2, y: y),
                withAttributes: actionAttrs
            )
        } else if !fileText.isEmpty {
            y -= titleGap + fileSize.height
            fileText.draw(
                at: NSPoint(x: c.x - min(fileSize.width, maxWidth) / 2, y: y),
                withAttributes: fileAttrs
            )
        }
    }

    /// One line. Keeps the count and the bullet, then cuts the names with "…".
    private func truncatedFileLabel(maxWidth: CGFloat, attributes attrs: [NSAttributedString.Key: Any]) -> String {
        guard !fileLabel.isEmpty, maxWidth > 1 else { return "" }
        if (fileLabel as NSString).size(withAttributes: attrs).width <= maxWidth { return fileLabel }
        let ellipsis = "…"
        var end = fileLabel.endIndex
        while end > fileLabel.startIndex {
            end = fileLabel.index(before: end)
            var cut = fileLabel[..<end]
            while let last = cut.last, last == " " || last == "," {
                cut = cut.dropLast()
            }
            let candidate = String(cut) + ellipsis
            if (candidate as NSString).size(withAttributes: attrs).width <= maxWidth {
                return candidate
            }
        }
        return ellipsis
    }

    private func drawHubIcon(in rect: NSRect) {
        if let symbol = NSImage(systemSymbolName: mode.hubSymbolName, accessibilityDescription: mode.title) {
            let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.85, weight: .semibold)
            let img = (symbol.withSymbolConfiguration(config) ?? symbol)
            img.isTemplate = true
            let tinted = NSImage(size: rect.size)
            tinted.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: rect.size), from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.set()
            NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.height * 0.9, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let s = mode.shortcutHint.size(withAttributes: attrs)
        mode.shortcutHint.draw(
            at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2),
            withAttributes: attrs
        )
    }
}

