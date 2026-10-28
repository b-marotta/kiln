import AppKit
import AVFoundation
import Carbon.HIToolbox

final class AudioWaveformView: NSView {
    var peaks: [Float] = []
    var selection: ClosedRange<Double> = 0...1
    var showsSelectionBackground = false
    var minimumSelection: Double = 0.0001
    var isInteractive = false
    var playhead: Double? { didSet { needsDisplay = true } }
    var onSelection: ((Double, Double) -> Void)?
    var volumePoints: [AudioVolumePoint]?
    var onVolumeChange: (([AudioVolumePoint]) -> Void)?
    private var movingVolumePoint: Int?
    private var movingStart = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Waveform audio. Trascina i bordi o usa i campi Inizio e Fine per selezionare il taglio.")
    }

    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 8, dy: 8)
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let lower = area.minX + CGFloat(selection.lowerBound) * area.width
        let upper = area.minX + CGFloat(selection.upperBound) * area.width
        if showsSelectionBackground {
            NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
            NSRect(x: lower, y: area.minY, width: upper - lower, height: area.height).fill()
        }
        let path = NSBezierPath()
        let maxPeak = max(peaks.max() ?? 1, 0.01)
        for (i, peak) in peaks.enumerated() {
            let x = area.minX + CGFloat(i) / CGFloat(max(1, peaks.count - 1)) * area.width
            let gain = volumeGain(at: Double(i) / Double(max(1, peaks.count - 1)))
            let amplitude = max(0.6, CGFloat(peak / maxPeak) * CGFloat(gain) * (area.height / 2 - 5))
            path.move(to: NSPoint(x: x, y: area.midY - amplitude))
            path.line(to: NSPoint(x: x, y: area.midY + amplitude))
        }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()
        if isInteractive && volumePoints == nil {
            for x in [lower, upper] {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 3, y: area.minY, width: 6, height: area.height), xRadius: 3, yRadius: 3).fill()
            }
        }
        if let volumePoints {
            let curve = NSBezierPath()
            if let first = volumePoints.first {
                curve.move(to: NSPoint(x: area.minX, y: pointPosition(first, in: area).y))
            }
            for point in volumePoints {
                let position = pointPosition(point, in: area)
                curve.line(to: position)
            }
            if let last = volumePoints.last {
                curve.line(to: NSPoint(x: area.maxX, y: pointPosition(last, in: area).y))
            }
            NSColor.white.withAlphaComponent(0.92).setStroke()
            curve.lineWidth = 2
            curve.stroke()
            for (index, point) in volumePoints.enumerated() {
                let position = pointPosition(point, in: area)
                let radius: CGFloat = movingVolumePoint == index ? 6 : 5
                let dot = NSBezierPath(ovalIn: NSRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2))
                NSColor.white.setFill()
                dot.fill()
                NSColor.controlAccentColor.setStroke()
                dot.lineWidth = 1.5
                dot.stroke()
            }
        }
        if let playhead {
            let x = area.minX + CGFloat(playhead) * area.width
            NSColor.labelColor.setFill()
            NSRect(x: x - 1, y: area.minY, width: 2, height: area.height).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard isInteractive else { return }
        if var points = volumePoints {
            let area = bounds.insetBy(dx: 8, dy: 8)
            let mouse = convert(event.locationInWindow, from: nil)
            let nearest = points.indices.min { first, second in
                let a = pointPosition(points[first], in: area)
                let b = pointPosition(points[second], in: area)
                return hypot(a.x - mouse.x, a.y - mouse.y) < hypot(b.x - mouse.x, b.y - mouse.y)
            }
            if let nearest,
               hypot(pointPosition(points[nearest], in: area).x - mouse.x, pointPosition(points[nearest], in: area).y - mouse.y) <= 14 {
                movingVolumePoint = nearest
            } else {
                let x = position(event)
                // Keep distinct times even if a click shares a point's x coordinate.
                if let sameTime = points.indices.first(where: { abs(CGFloat(points[$0].position - x) * area.width) < 8 }) {
                    movingVolumePoint = sameTime
                } else {
                    let gain = min(1, max(0, 1 - Double((mouse.y - area.minY) / max(1, area.height))))
                    let index = points.firstIndex { $0.position > x } ?? points.count
                    points.insert(AudioVolumePoint(position: x, gain: gain), at: index)
                    movingVolumePoint = index
                    volumePoints = points
                }
                moveVolumePoint(event)
            }
            needsDisplay = true
            return
        }
        let fraction = position(event)
        movingStart = abs(fraction - selection.lowerBound) <= abs(fraction - selection.upperBound)
        moveSelection(event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        if volumePoints != nil { moveVolumePoint(event) } else { moveSelection(event) }
    }
    override func mouseUp(with event: NSEvent) {
        movingVolumePoint = nil
        needsDisplay = true
    }

    private func pointPosition(_ point: AudioVolumePoint, in area: NSRect) -> NSPoint {
        NSPoint(x: area.minX + CGFloat(point.position) * area.width,
                y: area.minY + CGFloat(1 - point.gain) * area.height)
    }

    private func volumeGain(at position: Double) -> Double {
        guard let points = volumePoints, let firstPoint = points.first else { return 1 }
        guard points.count >= 2 else { return firstPoint.gain }
        let index = points.indices.dropLast().first { position <= points[$0 + 1].position } ?? points.count - 2
        let first = points[index]
        let next = points[index + 1]
        let fraction = min(1, max(0, (position - first.position) / max(0.000001, next.position - first.position)))
        return first.gain + (next.gain - first.gain) * fraction
    }

    private func moveVolumePoint(_ event: NSEvent) {
        guard var points = volumePoints, let index = movingVolumePoint, points.indices.contains(index) else { return }
        let area = bounds.insetBy(dx: 8, dy: 8)
        let mouse = convert(event.locationInWindow, from: nil)
        points[index].gain = min(1, max(0, 1 - Double((mouse.y - area.minY) / max(1, area.height))))
        let previous = index > 0 ? points[index - 1].position : 0
        let next = index < points.count - 1 ? points[index + 1].position : 1
        let gap = min(2 / Double(max(1, area.width)), (next - previous) / 3)
        let lower = index > 0 ? previous + gap : 0
        let upper = index < points.count - 1 ? next - gap : 1
        points[index].position = min(upper, max(lower, position(event)))
        volumePoints = points
        onVolumeChange?(points)
        needsDisplay = true
    }
    private func position(_ event: NSEvent) -> Double {
        min(1, max(0, Double((convert(event.locationInWindow, from: nil).x - 8) / max(1, bounds.width - 16))))
    }
    private func moveSelection(_ event: NSEvent) {
        let fraction = position(event)
        let start = movingStart ? min(fraction, selection.upperBound - minimumSelection) : selection.lowerBound
        let end = movingStart ? selection.upperBound : max(fraction, selection.lowerBound + minimumSelection)
        onSelection?(max(0, start), min(1, end))
    }
}
