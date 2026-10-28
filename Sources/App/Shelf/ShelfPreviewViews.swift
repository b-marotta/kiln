import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import QuartzCore

/// Capsule behind the section titles. Glass fills it like the card and the option bubbles. The view itself does not clip, so the pill can leave the capsule.
final class SectionBarView: NSView {
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }
}

final class ShelfContentView: NSView {
    override var isFlipped: Bool { true }
    // Let the shelf own drag destination handling, including over labels and buttons.
}

final class PreviewStackView: NSView {
    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }
}

/// Holds the rotated card in a box big enough for its corners, so the turn does not get sliced by the card frame.
final class RotatingPreview: NSView {
    let preview: RoundedPreview
    private let radians: CGFloat

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { false }

    init(center: NSPoint, side: CGFloat, angle: CGFloat, radius: CGFloat) {
        radians = angle * .pi / 180
        let extent = ceil(side * (abs(cos(radians)) + abs(sin(radians))) + 10)
        preview = RoundedPreview(
            frame: NSRect(x: (extent - side) / 2, y: (extent - side) / 2, width: side, height: side),
            radius: radius,
            shadow: true
        )
        super.init(frame: NSRect(x: center.x - extent / 2, y: center.y - extent / 2, width: extent, height: extent))
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(preview)
        applyRotation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applyRotation()
    }

    private func applyRotation() {
        guard let layer = preview.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.transform = CATransform3DMakeRotation(radians, 0, 0, 1)
    }
}

/// The slot stays a square. The rounded clip follows the image's own aspect-fit rect, so a wide photo is not cut by the square's corners.
final class RoundedPreview: NSView {
    private let imageView = NSImageView()
    private let maxRadius: CGFloat

    var image: NSImage? {
        get { imageView.image }
        set {
            imageView.image = newValue
            layoutImage()
        }
    }

    init(frame: NSRect, radius: CGFloat, bordered: Bool = false, shadow: Bool = true) {
        maxRadius = radius
        super.init(frame: frame)
        wantsLayer = true
        if shadow {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 3
            layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.masksToBounds = true
        imageView.layer?.cornerCurve = .continuous
        if bordered {
            imageView.layer?.borderWidth = 1
            imageView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            imageView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        }
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsDefaultClipping: Bool { false }

    private func layoutImage() {
        let fitted = fittedSize(imageView.image, max: bounds.size)
        imageView.frame = NSRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
        let short = min(fitted.width, fitted.height)
        let slot = min(bounds.width, bounds.height)
        let corner = slot > 0 ? min(short / 2, maxRadius * short / slot) : 0
        imageView.layer?.cornerRadius = corner
        if (layer?.shadowOpacity ?? 0) > 0 {
            layer?.shadowPath = CGPath(roundedRect: imageView.frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }
    }

    private func fittedSize(_ image: NSImage?, max: NSSize) -> NSSize {
        guard let image else { return max }
        let size = image.size
        guard size.width > 1, size.height > 1, max.width > 1, max.height > 1 else { return max }
        let scale = min(max.width / size.width, max.height / size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }
}

