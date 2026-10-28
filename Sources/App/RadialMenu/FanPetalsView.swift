import AppKit
import CoreText
import AudioToolbox
import Carbon.HIToolbox
import QuartzCore

/// Wedges only — annular sectors with a small fixed corner radius (not round-cap pills).
final class FanPetalsView: NSView {
    var actions: [FanAction] = []
    var mode: FanMode = .convert
    var fileLabel: String = ""
    var highlightedIndex: Int?
    var ringInnerRatio: CGFloat = 0.30
    var ringOuterRatio: CGFloat = 0.88
    var gapPoints: CGFloat = 5
    /// Soft corner on each petal — keep low so wedges stay wedge-shaped.
    private let cornerRadius: CGFloat = 14

    override var isOpaque: Bool { false }
    override var wantsDefaultClipping: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let half = min(bounds.width, bounds.height) / 2
        let ringInner = half * ringInnerRatio
        let ringOuter = half * ringOuterRatio
        let outer = ringOuter - gapPoints
        let inner = ringInner + gapPoints
        guard outer > inner + 4 else { return }
        let n = actions.count
        guard n > 0 else { return }

        let midR = (inner + outer) / 2
        let slice = (2 * .pi) / CGFloat(n)
        // Cap gap so a slice never collapses near the hub.
        let gap = min(gapPoints, midR * slice * 0.45)

        for i in 0..<n {
            let bisector = (.pi / 2) - (CGFloat(i) + 0.5) * slice
            let highlighted = i == highlightedIndex

            if let path = Self.constantGapPetalPath(
                center: c,
                inner: inner,
                outer: outer,
                bisector: bisector,
                slice: slice,
                gap: gap,
                corner: cornerRadius
            ) {
                let fill: NSColor = highlighted
                    ? NSColor(calibratedWhite: 1.0, alpha: 0.48)
                    : NSColor(calibratedWhite: 0.95, alpha: 0.22)
                let rim: NSColor = highlighted
                    ? NSColor.white.withAlphaComponent(0.85)
                    : NSColor.white.withAlphaComponent(0.45)

                path.lineJoinStyle = .round
                fill.setFill()
                path.fill()
                rim.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            drawLabel(
                actions[i].radialTitle,
                at: CGPoint(x: c.x + cos(bisector) * midR, y: c.y + sin(bisector) * midR),
                highlighted: highlighted
            )
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, highlighted: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.withAlphaComponent(highlighted ? 1 : 0.9).cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let ink = CTLineGetImageBounds(line, nil)
        guard !ink.isNull else { return }
        ctx.saveGState()
        ctx.setShadow(offset: NSSize(width: 0, height: -0.5), blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.textMatrix = .identity
        ctx.translateBy(x: point.x, y: point.y)
        if isFlipped { ctx.scaleBy(x: 1, y: -1) }
        ctx.textPosition = NSPoint(x: -ink.midX, y: -ink.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Petal with constant-width gap. Each corner is a circle tangent to the rim
    /// and to the curved side (true normal), drawn as the minor arc only.
    private static func constantGapPetalPath(
        center: CGPoint,
        inner: CGFloat,
        outer: CGFloat,
        bisector: CGFloat,
        slice: CGFloat,
        gap: CGFloat,
        corner crIn: CGFloat
    ) -> NSBezierPath? {
        let thickness = outer - inner
        guard thickness > 2, slice > 0.02 else { return nil }

        func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
        }
        func halfAngle(_ r: CGFloat) -> CGFloat {
            max(0.02, slice / 2 - gap / (2 * max(r, gap)))
        }
        func theta(_ r: CGFloat, _ side: Side) -> CGFloat {
            switch side {
            case .start: return bisector + halfAngle(r)
            case .end: return bisector - halfAngle(r)
            }
        }
        /// Unit normal pointing into the petal, for side curve θ(r) = β ± (slice/2 − g/(2r)).
        func inwardNormal(_ r: CGFloat, _ side: Side) -> CGPoint {
            let th = theta(r, side)
            let u = CGPoint(x: cos(th), y: sin(th))
            let ut = CGPoint(x: -sin(th), y: cos(th))
            let kr = (gap / 2) / max(r, 1)
            let inv = 1 / sqrt(1 + kr * kr)
            switch side {
            case .end:
                return CGPoint(x: (ut.x + kr * u.x) * inv, y: (ut.y + kr * u.y) * inv)
            case .start:
                return CGPoint(x: (-ut.x + kr * u.x) * inv, y: (-ut.y + kr * u.y) * inv)
            }
        }
        func unwrap(_ angle: CGFloat, near: CGFloat) -> CGFloat {
            var d = angle - near
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            return near + d
        }
        func radiusOf(_ p: CGPoint) -> CGFloat {
            hypot(p.x - center.x, p.y - center.y)
        }

        let cr = max(
            1,
            min(
                crIn,
                thickness / 2 - 1,
                halfAngle(inner) * inner * 0.42,
                halfAngle(outer) * outer * 0.42
            )
        )

        struct Fillet {
            var fc: CGPoint
            var rim: CGPoint
            var side: CGPoint
            var sideR: CGFloat
            var rimAngle: CGFloat
        }

        /// Fillet tangent to `rimRadius` and to the side. `target` is |FC| (outer−cr or inner+cr).
        func solveFillet(side: Side, rimRadius: CGFloat, target: CGFloat) -> Fillet? {
            let r0 = inner + 0.5
            let r1 = outer - 0.5
            guard r1 > r0 else { return nil }
            var bestR = r0
            var bestErr = CGFloat.greatestFiniteMagnitude
            let steps = 64
            for i in 0...steps {
                let r = r0 + (r1 - r0) * CGFloat(i) / CGFloat(steps)
                let s = polar(r, theta(r, side))
                let n = inwardNormal(r, side)
                let fc = CGPoint(x: s.x + n.x * cr, y: s.y + n.y * cr)
                let err = abs(radiusOf(fc) - target)
                if err < bestErr {
                    bestErr = err
                    bestR = r
                }
            }
            guard bestErr < 2 else { return nil }
            let span = (r1 - r0) / CGFloat(steps)
            var lo = max(r0, bestR - span)
            var hi = min(r1, bestR + span)
            for _ in 0..<12 {
                let m1 = lo + (hi - lo) / 3
                let m2 = hi - (hi - lo) / 3
                func err(at r: CGFloat) -> CGFloat {
                    let s = polar(r, theta(r, side))
                    let n = inwardNormal(r, side)
                    let fc = CGPoint(x: s.x + n.x * cr, y: s.y + n.y * cr)
                    return abs(radiusOf(fc) - target)
                }
                if err(at: m1) < err(at: m2) { hi = m2 } else { lo = m1 }
            }
            bestR = (lo + hi) / 2

            let s = polar(bestR, theta(bestR, side))
            let n = inwardNormal(bestR, side)
            let fc = CGPoint(x: s.x + n.x * cr, y: s.y + n.y * cr)
            let ang = atan2(fc.y - center.y, fc.x - center.x)
            let rim = polar(rimRadius, ang)
            return Fillet(
                fc: fc,
                rim: rim,
                side: s,
                sideR: bestR,
                rimAngle: unwrap(ang, near: theta(rimRadius, side))
            )
        }

        func appendMinorArc(_ path: NSBezierPath, fc: CGPoint, from a: CGPoint, to b: CGPoint) {
            let start = atan2(a.y - fc.y, a.x - fc.x)
            let end = atan2(b.y - fc.y, b.x - fc.x)
            var delta = end - start
            while delta > .pi { delta -= 2 * .pi }
            while delta <= -.pi { delta += 2 * .pi }
            guard abs(delta) < 2.4 else { return }
            path.appendArc(
                withCenter: fc,
                radius: cr,
                startAngle: start * 180 / .pi,
                endAngle: (start + delta) * 180 / .pi,
                clockwise: delta < 0
            )
        }

        func appendSide(_ path: NSBezierPath, side: Side, from r0: CGFloat, to r1: CGFloat) {
            let steps = max(10, Int(abs(r1 - r0) / 2))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let r = r0 + (r1 - r0) * t
                path.line(to: polar(r, theta(r, side)))
            }
        }

        guard
            let os = solveFillet(side: .start, rimRadius: outer, target: outer - cr),
            let oe = solveFillet(side: .end, rimRadius: outer, target: outer - cr),
            let is_ = solveFillet(side: .start, rimRadius: inner, target: inner + cr),
            let ie = solveFillet(side: .end, rimRadius: inner, target: inner + cr),
            os.sideR > is_.sideR + 1,
            oe.sideR > ie.sideR + 1,
            os.rimAngle > oe.rimAngle,
            is_.rimAngle > ie.rimAngle
        else {
            return sharpPetalPath(
                center: center, inner: inner, outer: outer,
                bisector: bisector, slice: slice, gap: gap
            )
        }

        let path = NSBezierPath()
        path.move(to: os.rim)
        path.appendArc(
            withCenter: center, radius: outer,
            startAngle: os.rimAngle * 180 / .pi,
            endAngle: oe.rimAngle * 180 / .pi,
            clockwise: true
        )
        appendMinorArc(path, fc: oe.fc, from: oe.rim, to: oe.side)
        appendSide(path, side: .end, from: oe.sideR, to: ie.sideR)
        appendMinorArc(path, fc: ie.fc, from: ie.side, to: ie.rim)
        path.appendArc(
            withCenter: center, radius: inner,
            startAngle: ie.rimAngle * 180 / .pi,
            endAngle: is_.rimAngle * 180 / .pi,
            clockwise: false
        )
        appendMinorArc(path, fc: is_.fc, from: is_.rim, to: is_.side)
        appendSide(path, side: .start, from: is_.sideR, to: os.sideR)
        appendMinorArc(path, fc: os.fc, from: os.side, to: os.rim)
        path.close()
        return path
    }

    private enum Side { case start, end }

    /// Constant-gap wedge with sharp corners — used only if a fillet cannot be solved.
    private static func sharpPetalPath(
        center: CGPoint,
        inner: CGFloat,
        outer: CGFloat,
        bisector: CGFloat,
        slice: CGFloat,
        gap: CGFloat
    ) -> NSBezierPath? {
        func polar(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
        }
        func half(_ r: CGFloat) -> CGFloat {
            max(0.02, slice / 2 - gap / (2 * max(r, gap)))
        }
        let a0 = bisector + half(outer)
        let a1 = bisector - half(outer)
        let b0 = bisector + half(inner)
        let b1 = bisector - half(inner)
        guard a0 > a1, b0 > b1 else { return nil }

        let path = NSBezierPath()
        path.move(to: polar(outer, a0))
        path.appendArc(
            withCenter: center, radius: outer,
            startAngle: a0 * 180 / .pi, endAngle: a1 * 180 / .pi, clockwise: true
        )
        let steps = 16
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let r = outer + (inner - outer) * t
            path.line(to: polar(r, bisector - half(r)))
        }
        path.appendArc(
            withCenter: center, radius: inner,
            startAngle: b1 * 180 / .pi, endAngle: b0 * 180 / .pi, clockwise: false
        )
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let r = inner + (outer - inner) * t
            path.line(to: polar(r, bisector + half(r)))
        }
        path.close()
        return path
    }
}

private extension FanAction {
    /// Compact petal label; full `title` shows in the hub.
    var radialTitle: String {
        switch self {
        case .imagesToPDF: return "PDF+"
        case .pdfToPNG: return "PNG"
        case .pdfToJPEG: return "JPEG"
        case .pdfToTXT: return "TXT"
        case .stripMetadata: return "STRIP"
        case .unzipArchive: return "EXTRACT"
        case .srtToVTT: return "VTT"
        case .vttToSRT: return "SRT"
        case .srtToTXT, .vttToTXT: return "TXT"
        case .revealInFinder: return "REVEAL"
        case .copyPath: return "PATH"
        case .copyFiles: return "COPY"
        case .airDrop: return "AIRDROP"
        case .openInTerminal: return "TERM"
        case .floatFiles: return "FLOAT"
        case .compressImage: return "COMPRESS"
        default:
            let t = title.replacingOccurrences(of: " → ", with: "→")
            return t.count <= 8 ? t.uppercased() : String(t.prefix(7)).uppercased()
        }
    }
}
