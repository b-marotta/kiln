import AppKit
import PDFKit
import UniformTypeIdentifiers

final class SignaturePDFView: PDFView {
    override func setCursorFor(_ area: PDFAreaOfInterest) {
        updateSignatureCursor()
    }

    private var signatureCursorTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let signatureCursorTracking { removeTrackingArea(signatureCursorTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        signatureCursorTracking = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        updateSignatureCursor()
    }

    private func updateSignatureCursor() {
        if placingSignature, signatureDrag != nil {
            NSCursor.closedHand.set()
        } else if placingSignature, let window, let target = signatureTarget?(),
                  target.annotation.bounds.contains(convert(convert(window.mouseLocationOutsideOfEventStream, from: nil), to: target.page)) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    var placingSignature = false
    var onPlace: ((PDFPage, NSPoint) -> Void)?
    var signatureTarget: (() -> (page: PDFPage, annotation: PDFAnnotation)?)?
    private var signatureDrag: (page: PDFPage, annotation: PDFAnnotation, offset: NSPoint)?
    private var scrollMonitor: Any?
    private var forwardingScroll = false
    private weak var fittedPage: PDFPage?
    private var fittedViewport: NSSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        guard window != nil else { return }
        // PDFKit's internal scroll view can turn horizontal gestures into page navigation.
        // Intercept before those child views receive the event, and pan only within this page.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe, .magnify, .smartMagnify, .rightMouseDown, .rightMouseUp, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            if event.type == .leftMouseDown {
                return event.modifierFlags.contains(.control) ? nil : event
            }
            if event.type == .scrollWheel { self.panPage(with: event) }
            return nil
        }
    }
    deinit { if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) } }

    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) {}

    private func panPage(with event: NSEvent) {
        guard !forwardingScroll else { return }
        guard let scroll = documentView?.enclosingScrollView else { return }
        let clip = scroll.contentView
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        var bounds = clip.bounds
        bounds.origin.x -= event.scrollingDeltaX * multiplier
        bounds.origin.y += event.scrollingDeltaY * multiplier * (clip.isFlipped ? -1 : 1)
        let constrained = clip.constrainBoundsRect(bounds)
        let reachesEdge = abs(bounds.minX - constrained.minX) > 0.01 || abs(bounds.minY - constrained.minY) > 0.01
        if reachesEdge {
            // Stop precisely at the page edge, without handing PDFKit an overscroll that can turn a page.
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
        } else {
            // Keep AppKit's native high-resolution scrolling and trackpad momentum in the page interior.
            // Ignore a responder-chain fallback from the internal scroll view to PDFView.
            forwardingScroll = true
            defer { forwardingScroll = false }
            scroll.scrollWheel(with: event)
        }
    }
    override func swipe(with event: NSEvent) {}
    override func goToNextPage(_ sender: Any?) {}
    override func goToPreviousPage(_ sender: Any?) {}
    override func goToFirstPage(_ sender: Any?) {}
    override func goToLastPage(_ sender: Any?) {}

    override func layout() {
        super.layout()
        if let scroll = documentView?.enclosingScrollView {
            if !scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = true }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            scroll.scrollsDynamically = true
            scroll.usesPredominantAxisScrolling = false
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .none
            if let page = currentPage, fittedPage !== page || fittedViewport != scroll.contentSize {
                let size = scroll.contentSize
                let bounds = page.bounds(for: .cropBox)
                let rotated = page.rotation % 180 != 0
                let pageSize = rotated ? NSSize(width: bounds.height, height: bounds.width) : bounds.size
                guard size.width > 0, size.height > 0, pageSize.width > 0, pageSize.height > 0 else { return }
                fittedPage = page
                fittedViewport = size
                // Leave a little more of the page visible than the edge-filling zoom.
                scaleFactor = max(size.width / pageSize.width, size.height / pageSize.height) * 0.75
            }
        }
    }
    override func scrollWheel(with event: NSEvent) { panPage(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard placingSignature, let hit, !(hit is NSScroller) else { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        signatureDrag = nil
        guard placingSignature else { super.mouseDown(with: event); return }
        let point = convert(event.locationInWindow, from: nil)
        if let target = signatureTarget?() {
            let pagePoint = convert(point, to: target.page)
            let bounds = target.annotation.bounds
            if bounds.contains(pagePoint) {
                signatureDrag = (target.page, target.annotation,
                                 NSPoint(x: pagePoint.x - bounds.minX, y: pagePoint.y - bounds.minY))
                updateSignatureCursor()
                return
            }
        }
        guard let page = page(for: point, nearest: false) else { return }
        onPlace?(page, convert(point, to: page))
        updateSignatureCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard placingSignature else { super.mouseDragged(with: event); return }
        guard let drag = signatureDrag,
              let target = signatureTarget?(), target.annotation === drag.annotation else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: drag.page)
        let pageBounds = drag.page.bounds(for: .cropBox)
        var bounds = drag.annotation.bounds
        bounds.origin.x = min(max(point.x - drag.offset.x, pageBounds.minX), pageBounds.maxX - bounds.width)
        bounds.origin.y = min(max(point.y - drag.offset.y, pageBounds.minY), pageBounds.maxY - bounds.height)
        drag.annotation.bounds = bounds
        updateSignatureCursor()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        signatureDrag = nil
        updateSignatureCursor()
        guard !placingSignature else { return }
        super.mouseUp(with: event)
    }
}

