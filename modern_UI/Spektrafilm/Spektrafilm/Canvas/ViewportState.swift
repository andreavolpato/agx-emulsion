//  ViewportState.swift — zoom and pan as pure arithmetic, testable without a
//  window. Capture One's rules: the image is fitted and centred; below fit it
//  cannot be panned; above fit it can be panned but an image edge can never
//  come inside the viewport edge. One clamp, here.
//
//  Units: `scale` is view points per image pixel. `offset` is the image
//  origin in view points, top-left origin (which is also how the fragment
//  shader sees it, after multiplying by the backing scale).

import CoreGraphics

struct ViewportState: Equatable, Sendable {
    var viewport = CGSize(width: 1, height: 1)
    var image = CGSize(width: 1, height: 1)
    var scale: CGFloat = 1
    var offset = CGPoint.zero
    /// Points per device pixel. 100 % means one image pixel per device pixel.
    var backingScale: CGFloat = 2

    static let minZoom: CGFloat = 0.05, maxZoom: CGFloat = 8   // as a fraction of 100 %

    var fitScale: CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }
    var hundredScale: CGFloat { 1 / backingScale }
    var isFit: Bool { abs(scale - fitScale) < 1e-6 }
    /// Zoom relative to 100 %, e.g. 0.5 → "50 %".
    var zoomFraction: CGFloat { scale / hundredScale }
    var zoomPercent: Int { Int((zoomFraction * 100).rounded()) }
    var imageFrame: CGRect { CGRect(origin: offset, size: CGSize(width: image.width * scale, height: image.height * scale)) }

    mutating func fit() {
        scale = fitScale
        centre()
    }

    /// Fit a rect given in **normalised image coordinates**, leaving `margin`
    /// view points clear on every side. The crop tool's fit.
    ///
    /// Not `fit()`: that one is the axis-aligned fit of the whole image and is
    /// what "Fit" means everywhere else. This fits an arbitrary box — the
    /// turned photograph's bounding box in edit space — and it deliberately
    /// does not touch `image`, which stays the whole frame, so every mapping
    /// between view points, image points and edit space is unchanged. The
    /// margin is what keeps the crop's grips and the rotate zone around it
    /// reachable, and it is why the crop tool's fit is slightly tighter than
    /// the plain one even at 0°.
    ///
    /// No clamp: the rect is the photograph, so the fit is by construction
    /// inside the viewport and centred on it, which is what `clamp()` would
    /// have to say about it anyway.
    mutating func fit(toNormalised rect: CGRect, margin: CGFloat = 0) {
        let w = rect.width * image.width, h = rect.height * image.height
        guard w > 0, h > 0 else { return }
        // A canvas narrower than twice the margin would give a negative
        // scale, which mirrors the picture rather than shrinking it.
        let avail = CGSize(width: max(viewport.width - 2 * margin, 1),
                           height: max(viewport.height - 2 * margin, 1))
        scale = min(avail.width / w, avail.height / h)
        let c = CGPoint(x: rect.midX * image.width, y: rect.midY * image.height)
        offset = CGPoint(x: viewport.width / 2 - c.x * scale,
                         y: viewport.height / 2 - c.y * scale)
    }

    mutating func centre() {
        offset = CGPoint(x: (viewport.width - image.width * scale) / 2,
                         y: (viewport.height - image.height * scale) / 2)
    }

    /// Called when the view or image changes size: keep the fit if we were
    /// fitted, otherwise keep the centre of view stable.
    mutating func resize(viewport newViewport: CGSize, image newImage: CGSize? = nil) {
        let wasFit = isFit
        let centreImage = imagePoint(atView: CGPoint(x: viewport.width / 2, y: viewport.height / 2))
        if let newImage, newImage != image {
            image = newImage
            viewport = newViewport
            fit()
            return
        }
        viewport = newViewport
        if wasFit { fit() } else {
            offset = CGPoint(x: viewport.width / 2 - centreImage.x * scale,
                             y: viewport.height / 2 - centreImage.y * scale)
            clamp()
        }
    }

    func imagePoint(atView p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }
    func viewPoint(atImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
    }
    /// Normalised (0…1) image coordinate at a view point, or nil if outside.
    func normalised(atView p: CGPoint) -> CGPoint? {
        let ip = imagePoint(atView: p)
        let n = CGPoint(x: ip.x / image.width, y: ip.y / image.height)
        return (0...1).contains(n.x) && (0...1).contains(n.y) ? n : nil
    }

    /// Zoom by `factor` keeping the image point under `anchor` (view coords) fixed.
    mutating func zoom(by factor: CGFloat, about anchor: CGPoint) {
        setScale(scale * factor, about: anchor)
    }

    mutating func setScale(_ s: CGFloat, about anchor: CGPoint) {
        let lo = min(fitScale, hundredScale * ViewportState.minZoom)
        let hi = hundredScale * ViewportState.maxZoom
        let target = s.clamped(to: lo...hi)
        let ip = imagePoint(atView: anchor)
        scale = target
        offset = CGPoint(x: anchor.x - ip.x * scale, y: anchor.y - ip.y * scale)
        clamp()
    }

    mutating func pan(by delta: CGSize) {
        offset.x += delta.width
        offset.y += delta.height
        clamp()
    }

    /// The one clamp. Along an axis where the image is smaller than the
    /// viewport it is centred; where it is larger, its edges stay outside.
    mutating func clamp() {
        let w = image.width * scale, h = image.height * scale
        if w <= viewport.width { offset.x = (viewport.width - w) / 2 }
        else { offset.x = offset.x.clamped(to: (viewport.width - w)...0) }
        if h <= viewport.height { offset.y = (viewport.height - h) / 2 }
        else { offset.y = offset.y.clamped(to: (viewport.height - h)...0) }
    }

    /// `Z` / double-click: fit ↔ 100 % about a point.
    mutating func toggleHundred(about anchor: CGPoint) {
        if abs(scale - hundredScale) < 1e-6 { fit() } else { setScale(hundredScale, about: anchor) }
    }

    static let zoomSteps: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.66, 1, 1.5, 2, 3, 4, 6, 8]
    mutating func stepZoom(_ direction: Int, about anchor: CGPoint) {
        let f = zoomFraction
        let next: CGFloat
        if direction > 0 { next = ViewportState.zoomSteps.first { $0 > f + 1e-3 } ?? ViewportState.maxZoom }
        else { next = ViewportState.zoomSteps.last { $0 < f - 1e-3 } ?? ViewportState.minZoom }
        setScale(next * hundredScale, about: anchor)
    }
}
