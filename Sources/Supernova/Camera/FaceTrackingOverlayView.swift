import UIKit

/// Transparent overlay that draws face bounding boxes over the camera preview.
///
/// The detection feed updates `faces` at ~15 Hz, but rendering is interpolated at the screen's
/// refresh rate via CADisplayLink — every frame the displayed boxes glide ~15 % toward the latest
/// targets. The result is a continuously-moving overlay instead of one that teleports on each
/// detection update. This is what pro camera apps do; the discrete jumps you'd otherwise see at
/// 15 Hz read as "the box is jittery" even when the underlying detection is stable.
public final class FaceTrackingOverlayView: UIView {

    /// Normalized face rects (0-1, Y-down). Setting this updates the interpolation TARGETS.
    /// The visible boxes glide toward these targets at 60 Hz (or device refresh rate).
    public var faces: [CGRect] = [] {
        didSet {
            targetFaces = faces
            ensureDisplayLink()
        }
    }

    /// What the overlay is currently drawing. Glides toward `targetFaces` each frame.
    private var displayedFaces: [CGRect] = []
    private var targetFaces: [CGRect] = []
    private var displayLink: CADisplayLink?

    /// 0 → snap to target instantly, 1 → never move. 0.85 gives a 50 % convergence in ~5 frames
    /// (~80 ms at 60 fps) — visibly smooth, no perceptible lag for normal head movement.
    private let interpolationFactor: CGFloat = 0.85

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    deinit {
        displayLink?.invalidate()
    }

    private func ensureDisplayLink() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick() {
        // Match displayed count to target count. When the count changes (face appears or disappears),
        // snap rather than interpolate — interpolating between a different number of boxes would
        // create animation artifacts.
        if displayedFaces.count != targetFaces.count {
            displayedFaces = targetFaces
            setNeedsDisplay()
            if targetFaces.isEmpty {
                displayLink?.invalidate()
                displayLink = nil
            }
            return
        }

        // Per-frame EMA: each box moves 15 % toward its target. Detection running at 15 Hz, screen
        // at 60 Hz → ~4 interpolation frames between detection updates.
        let f = interpolationFactor
        var anyMoved = false
        for i in 0..<displayedFaces.count {
            let cur = displayedFaces[i]
            let tgt = targetFaces[i]
            let next = CGRect(
                x: cur.origin.x * f + tgt.origin.x * (1 - f),
                y: cur.origin.y * f + tgt.origin.y * (1 - f),
                width: cur.width  * f + tgt.width  * (1 - f),
                height: cur.height * f + tgt.height * (1 - f)
            )
            // If we're essentially at the target, skip the redraw to save work.
            if abs(next.origin.x - cur.origin.x) > 0.0001
                || abs(next.origin.y - cur.origin.y) > 0.0001
                || abs(next.width   - cur.width)    > 0.0001
                || abs(next.height  - cur.height)   > 0.0001 {
                displayedFaces[i] = next
                anyMoved = true
            }
        }
        if anyMoved { setNeedsDisplay() }
    }

    public override func draw(_ rect: CGRect) {
        guard !displayedFaces.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }

        // Solid yellow border, no dash. Slightly thicker so the smoothness is easy to verify by eye.
        ctx.setStrokeColor(UIColor.systemYellow.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineDash(phase: 0, lengths: [])

        for face in displayedFaces {
            let drawRect = CGRect(
                x: face.origin.x * rect.width,
                y: face.origin.y * rect.height,
                width: face.width  * rect.width,
                height: face.height * rect.height
            )
            ctx.stroke(drawRect)
        }
    }
}
