import AppKit
import ImageIO

final class ImageCropPreview: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var comparisonImage: CGImage? { didSet { needsDisplay = true } }
    var magnificationImage: CGImage?
    var magnificationEnabled = false { didSet { lensPoint = nil; needsDisplay = true } }
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1) { didSet { needsDisplay = true } }
    var cropEnabled = false { didSet { lensPoint = nil; needsDisplay = true } }
    var isEnabled = true
    var normalizedRatio: CGFloat?
    var onCropChange: ((CGRect) -> Void)?
    private var start = CGPoint.zero
    private var initial = CGRect.zero
    private var moving = false
    private var anchor = CGPoint.zero
    private var dragging = false
    private var draggingCorner = false
    private var lensPoint: CGPoint?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var imageRect: CGRect {
        guard let image else { return .zero }
        let fit = min((bounds.width - 16) / CGFloat(image.width), (bounds.height - 16) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func displayRect(_ rect: CGRect) -> CGRect {
        let frame = imageRect
        return CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height, width: rect.width * frame.width, height: rect.height * frame.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image else { return }
        let rect = imageRect
        // Checkerboard reveals alpha before choosing an export format.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for y in stride(from: rect.minY, to: rect.maxY, by: 10) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 10) {
                let dark = (Int((x - rect.minX) / 10) + Int((y - rect.minY) / 10)) % 2 == 0
                NSColor(white: dark ? 0.7 : 0.9, alpha: 1).setFill()
                NSBezierPath(rect: CGRect(x: x, y: y, width: 10, height: 10)).fill()
            }
        }
        NSImage(cgImage: comparisonImage ?? image, size: NSSize(width: image.width, height: image.height)).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if cropEnabled {
            let selection = displayRect(crop)
            let mask = NSBezierPath(rect: rect)
            mask.append(NSBezierPath(rect: selection)); mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill(); mask.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
            for point in corners(selection) {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if cropEnabled || magnificationEnabled, let lensPoint { drawMagnifier(at: lensPoint) }
    }

    private func drawMagnifier(at point: CGPoint) {
        guard let source = comparisonImage ?? magnificationImage ?? image else { return }
        let diameter: CGFloat = 104
        let gap: CGFloat = 24
        let focus = CGPoint(x: imageRect.minX + point.x * imageRect.width,
                            y: imageRect.minY + point.y * imageRect.height)
        let proposedX = focus.x + gap + diameter <= bounds.maxX - 8
            ? focus.x + gap : focus.x - gap - diameter
        let lens = CGRect(x: max(8, min(bounds.maxX - diameter - 8, proposedX)),
                          y: max(8, min(bounds.maxY - diameter - 8, focus.y - diameter / 2)),
                          width: diameter, height: diameter)
        let circle = NSBezierPath(ovalIn: lens)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.darkGray.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        let zoom: CGFloat = 4
        let enlarged = CGSize(width: imageRect.width * zoom, height: imageRect.height * zoom)
        let destination = CGRect(x: lens.midX - point.x * enlarged.width,
                                 y: lens.midY - point.y * enlarged.height,
                                 width: enlarged.width, height: enlarged.height)
        NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
            .draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let guides = NSBezierPath()
        guides.move(to: CGPoint(x: lens.minX, y: lens.midY))
        guides.line(to: CGPoint(x: lens.maxX, y: lens.midY))
        guides.move(to: CGPoint(x: lens.midX, y: lens.minY))
        guides.line(to: CGPoint(x: lens.midX, y: lens.maxY))
        NSColor.white.withAlphaComponent(0.4).setStroke()
        guides.lineWidth = 1
        guides.stroke()
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: lens.midX - 6, y: lens.midY))
        crosshair.line(to: CGPoint(x: lens.midX + 6, y: lens.midY))
        crosshair.move(to: CGPoint(x: lens.midX, y: lens.midY - 6))
        crosshair.line(to: CGPoint(x: lens.midX, y: lens.midY + 6))
        NSColor.white.setStroke()
        crosshair.lineWidth = 1
        crosshair.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = 2
        circle.stroke()
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: max(0, min(1, (point.x - rect.minX) / rect.width)), y: max(0, min(1, (point.y - rect.minY) / rect.height)))
    }
    override func mouseDown(with event: NSEvent) {
        dragging = false
        draggingCorner = false
        lensPoint = nil
        needsDisplay = true
        if magnificationEnabled, !cropEnabled, isEnabled, image != nil {
            let point = convert(event.locationInWindow, from: nil)
            guard imageRect.contains(point) else { return }
            dragging = true
            lensPoint = normalized(point)
            return
        }
        guard cropEnabled, isEnabled, image != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.insetBy(dx: -8, dy: -8).contains(point) else { return }
        dragging = true
        start = normalized(point); initial = crop
        let handles = corners(displayRect(crop))
        if let index = handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) < 12 }) {
            anchor = corners(crop)[3 - index]; moving = false
            draggingCorner = true
            lensPoint = corners(crop)[index]
        } else if displayRect(crop).contains(point) {
            moving = true
        } else {
            anchor = start; moving = false
        }
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        draggingCorner = false
        lensPoint = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        if dragging, magnificationEnabled, !cropEnabled, isEnabled {
            lensPoint = normalized(convert(event.locationInWindow, from: nil))
            needsDisplay = true
            return
        }
        guard dragging, cropEnabled, isEnabled, image != nil else { return }
        let point = normalized(convert(event.locationInWindow, from: nil))
        if moving {
            crop.origin = CGPoint(x: max(0, min(1 - initial.width, initial.minX + point.x - start.x)), y: max(0, min(1 - initial.height, initial.minY + point.y - start.y)))
        } else {
            var width = abs(point.x - anchor.x), height = abs(point.y - anchor.y)
            let right = point.x >= anchor.x, down = point.y >= anchor.y
            if let ratio = normalizedRatio {
                width = max(width, height * ratio)
                width = min(width, right ? 1 - anchor.x : anchor.x, (down ? 1 - anchor.y : anchor.y) * ratio)
                height = width / ratio
            }
            let rect = CGRect(x: right ? anchor.x : anchor.x - width, y: down ? anchor.y : anchor.y - height, width: width, height: height)
            if width > 0.005, height > 0.005 { crop = rect }
        }
        if draggingCorner {
            // Follow the constrained handle, which can differ from the cursor for fixed ratios.
            lensPoint = corners(crop).max { lhs, rhs in
                hypot(lhs.x - anchor.x, lhs.y - anchor.y) < hypot(rhs.x - anchor.x, rhs.y - anchor.y)
            }
            needsDisplay = true
        }
        onCropChange?(crop)
    }
}

