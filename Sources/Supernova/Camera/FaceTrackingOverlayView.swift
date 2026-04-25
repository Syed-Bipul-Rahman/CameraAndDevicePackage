import UIKit

/// Transparent overlay that draws face bounding boxes over the camera preview.
/// Update `faces` to trigger a redraw; all rects are normalized 0-1 in screen space.
public final class FaceTrackingOverlayView: UIView {

    /// Normalized face rects (0-1, Y-down). Setting this triggers setNeedsDisplay.
    public var faces: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

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

    public override func draw(_ rect: CGRect) {
        guard !faces.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.setStrokeColor(UIColor.systemGreen.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 3])

        for face in faces {
            let drawRect = CGRect(
                x: face.origin.x * rect.width,
                y: face.origin.y * rect.height,
                width: face.width * rect.width,
                height: face.height * rect.height
            )
            ctx.stroke(drawRect)
        }
    }
}
