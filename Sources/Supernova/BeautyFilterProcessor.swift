import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Metal

class BeautyFilterProcessor {
    private let context: CIContext

    var smoothSkinEnabled: Bool = false
    var warmToneEnabled: Bool = false
    var smoothIntensity: Float = 0.5
    var warmthIntensity: Float = 0.5

    var faceOnlySmoothEnabled: Bool = false
    var faceSmoothIntensity: Float = 0.5

    var faceColorTintEnabled: Bool = false
    var faceColorTintRed: Float = 0.0
    var faceColorTintGreen: Float = 0.0
    var faceColorTintBlue: Float = 0.0
    var faceColorTintIntensity: Float = 0.3

    var brightness: Float = 0.0
    // Contrast slider was removed from the panel; ship every frame with a fixed punchy look.
    var contrast: Float = 1.4
    var saturation: Float = 1.0

    var lipPlumpEnabled: Bool = false
    var lipPlumpIntensity: Float = 0.0

    var milkySkinEnabled: Bool = false
    var milkySkinIntensity: Float = 0.0

    var backgroundBlurEnabled: Bool = false
    var backgroundBlurIntensity: Float = 0.0

    var detectedFaces: [DetectedFace] = [] {
        didSet { updateMotionFade(previous: oldValue, current: detectedFaces) }
    }

    /// External per-pixel skin mask, set by FaceParsingService on the main / parsing queue.
    /// When present, milky and face-only-smooth use this instead of the Vision-landmark polygon mask.
    /// Thread-safe via the lock — accessed from the render queue and written from the parsing queue.
    private let externalMaskLock = NSLock()
    private var _externalSkinMask: CIImage?
    var externalSkinMask: CIImage? {
        get { externalMaskLock.lock(); defer { externalMaskLock.unlock() }; return _externalSkinMask }
        set { externalMaskLock.lock(); _externalSkinMask = newValue; externalMaskLock.unlock() }
    }

    /// Cached extra-softened polygon mask used by plump only. Plump needs a wider feather than
    /// the milky/smooth-shared base mask, but we don't want to recompute that extra blur on every
    /// frame. Keyed off the base mask's cache key so it auto-invalidates whenever the base updates.
    private var cachedPlumpExtraMask: CIImage?
    private var cachedPlumpExtraMaskKey: String = ""

    /// Returns the external (ML) skin mask scaled and translated to match the given target extent.
    /// The mask is set by FaceParsingService at the original sensor resolution; for live preview
    /// the pipeline downsamples to a working extent, so the mask must be scaled to match.
    /// Returns nil if no ML mask is set or it doesn't intersect the target.
    private func resolvedExternalMask(for targetExtent: CGRect) -> CIImage? {
        guard let mask = externalSkinMask, mask.extent.intersects(targetExtent) else { return nil }
        if mask.extent == targetExtent { return mask }
        let sx = targetExtent.width  / mask.extent.width
        let sy = targetExtent.height / mask.extent.height
        var scaled = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let dx = targetExtent.origin.x - scaled.extent.origin.x
        let dy = targetExtent.origin.y - scaled.extent.origin.y
        if dx != 0 || dy != 0 {
            scaled = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
        return scaled
    }

    // Motion-aware fade: pro apps hide the effect while the face is moving and bring it back once it
    // settles, because a rendered mask always lags reality by some milliseconds. Matching that here.
    private var motionFade: Float = 1.0
    private var lastFaceWidth: CGFloat = 0
    /// Heavily-smoothed reference position. Decoupled from the rendering smoothing (which has to be
    /// light so the mask tracks the face responsively) — we use a separate slow EMA here so that the
    /// jitter in Vision's bounding box averages to zero around the true face position. Real movement
    /// shifts the reference slowly, so |current - reference| spikes during real movement only.
    private var stableReference: CGPoint?
    /// Smoothed motion magnitude. Rejects single-frame spikes that come from detection noise.
    private var motionEMA: Float = 0

    private func updateMotionFade(previous: [DetectedFace], current: [DetectedFace]) {
        guard let face = current.first else {
            motionFade = 0
            motionEMA = 0
            stableReference = nil
            lastFaceWidth = 0
            return
        }
        let center = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        let faceWidth = face.boundingBox.width

        if let ref = stableReference, lastFaceWidth > 0 {
            // Distance from current detection to the stable reference, normalized to face width.
            // When face is still: ref converges to true center, jitter cancels → distance ≈ 0.
            // When face moves: ref lags → distance = real translation, large.
            let dx = center.x - ref.x
            let dy = center.y - ref.y
            let distance = sqrt(dx * dx + dy * dy)
            let raw = Float(distance / max(0.05, faceWidth))

            // Smooth the motion magnitude itself so single-frame detection spikes don't kill the effect.
            motionEMA = motionEMA * 0.55 + raw * 0.45

            //   > 5% smoothed motion = real movement → kill effect fast
            //   < 2% smoothed motion = held essentially still → ramp effect back in
            //   2-5% = "noisy hold" zone, motionFade holds steady (no blink)
            if motionEMA > 0.05 {
                motionFade = max(0, motionFade - 0.85)
            } else if motionEMA < 0.02 {
                motionFade = min(1.0, motionFade + 0.20)
            }
            // else: hold motionFade as-is — prevents in/out flicker from borderline shake.

            // Update reference with heavy smoothing — slow enough that detection jitter averages out
            // around the true center, but fast enough to follow real movement once the EMA decays.
            stableReference = CGPoint(
                x: ref.x * 0.85 + center.x * 0.15,
                y: ref.y * 0.85 + center.y * 0.15
            )
        } else {
            // First face we've seen — start at 0 and fade in so it eases on screen.
            motionFade = max(motionFade, 0.15)
            motionEMA = 0
            stableReference = center
        }
        lastFaceWidth = faceWidth
    }

    private var skinSmoothingProcessor: SkinSmoothingProcessor?

    private var personSegmentationRequest: Any?
    private var cachedPersonMask: CIImage?
    private var segmentationFrameCounter: Int = 0
    private var cachedMaskSourceSize: CGSize = .zero

    init() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: metalDevice, options: [
                .workingColorSpace: p3,
                .highQualityDownsample: true
            ])
        } else {
            context = CIContext(options: [.workingColorSpace: p3, .useSoftwareRenderer: false])
        }

        skinSmoothingProcessor = SkinSmoothingProcessor()

        if #available(iOS 15.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            // .fast is plenty for background blur — the person mask is heavily soft-blurred and
            // composited with a Gaussian-blurred background, so pixel-precise edges aren't visible.
            // .fast cuts segmentation cost roughly in half vs .balanced.
            request.qualityLevel = .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            personSegmentationRequest = request
        }
    }

    /// Live preview downsamples the entire pipeline to ~screen resolution (2560 longest side) so all
    /// filters work on a smaller buffer. Photo capture uses `fullResolution: true` to bypass the
    /// downsample and process at native sensor resolution for max captured-image quality.
    func processImage(_ inputImage: CIImage, fullResolution: Bool = false) -> CIImage {
        let originalExtent = inputImage.extent

        // Decide working resolution. Live preview targets 2560 px longest side — roughly matches the
        // iPhone screen's actual pixel dimensions, so Metal renders 1:1 to the display with no
        // wasted compute on pixels that won't be visible.
        let workingScale: CGFloat
        if fullResolution {
            workingScale = 1.0
        } else {
            let target: CGFloat = 2560
            let longest = max(originalExtent.width, originalExtent.height)
            workingScale = longest > target ? target / longest : 1.0
        }

        var outputImage = inputImage
        if workingScale < 1.0 {
            let downExtent = CGRect(
                x: originalExtent.origin.x * workingScale,
                y: originalExtent.origin.y * workingScale,
                width: originalExtent.width  * workingScale,
                height: originalExtent.height * workingScale
            )
            outputImage = inputImage
                .transformed(by: CGAffineTransform(scaleX: workingScale, y: workingScale))
                .cropped(to: downExtent)
        }

        if backgroundBlurEnabled && backgroundBlurIntensity > 0 {
            outputImage = applyBackgroundBlur(to: outputImage, fullResolution: fullResolution)
        }

        if faceOnlySmoothEnabled && !detectedFaces.isEmpty {
            outputImage = applyFaceOnlySmooth(to: outputImage, fullResolution: fullResolution)
        } else if smoothSkinEnabled {
            outputImage = applySmoothSkin(to: outputImage)
        }

        if milkySkinEnabled && milkySkinIntensity > 0 {
            outputImage = applyMilkySkin(to: outputImage, fullResolution: fullResolution)
        }

        if lipPlumpEnabled && lipPlumpIntensity != 0 && !detectedFaces.isEmpty {
            outputImage = applyLipPlump(to: outputImage)
        }

        if faceColorTintEnabled && !detectedFaces.isEmpty {
            outputImage = applyFaceColorTint(to: outputImage)
        }

        if warmToneEnabled {
            outputImage = applyWarmTone(to: outputImage)
        }

        if brightness != 0.0 || contrast != 1.0 || saturation != 1.0 {
            outputImage = applyColorAdjustments(to: outputImage)
        }

        // Upsample back to original sensor resolution. Lazy transform — Metal does the bilinear
        // sample at display time, no extra render cost. Display is 1:1 because target ≈ screen res.
        if workingScale < 1.0 {
            let inv = 1.0 / workingScale
            outputImage = outputImage
                .transformed(by: CGAffineTransform(scaleX: inv, y: inv))
                .cropped(to: originalExtent)
        }
        return outputImage
    }

    func invalidateSegmentationCache() {
        cachedPersonMask = nil
        cachedMaskSourceSize = .zero
        segmentationFrameCounter = 0
    }

    func hasActiveFilters() -> Bool {
        return smoothSkinEnabled
            || warmToneEnabled
            || faceOnlySmoothEnabled
            || faceColorTintEnabled
            || lipPlumpEnabled
            || milkySkinEnabled
            || backgroundBlurEnabled
            || brightness != 0.0
            || contrast != 1.0
            || saturation != 1.0
    }

    private func applyColorAdjustments(to image: CIImage) -> CIImage {
        guard let colorFilter = CIFilter(name: "CIColorControls") else { return image }
        colorFilter.setValue(image, forKey: kCIInputImageKey)
        colorFilter.setValue(Double(brightness), forKey: kCIInputBrightnessKey)
        colorFilter.setValue(Double(contrast), forKey: kCIInputContrastKey)
        colorFilter.setValue(Double(saturation), forKey: kCIInputSaturationKey)
        return colorFilter.outputImage ?? image
    }

    private func applyMilkySkin(to image: CIImage, fullResolution: Bool = false) -> CIImage {
        let imageExtent = image.extent
        let intensity = Double(milkySkinIntensity) * Double(motionFade)
        if intensity < 0.001 { return image }

        // === 1. Tone shift (brightness / saturation / contrast) ===
        // Applied directly to original image — preserves all detail (CIColorControls is per-pixel,
        // doesn't blur). Same as the previous-known-good version.
        guard let toneFilter = CIFilter(name: "CIColorControls") else { return image }
        toneFilter.setValue(image, forKey: kCIInputImageKey)
        toneFilter.setValue(intensity * 0.12, forKey: kCIInputBrightnessKey)
        toneFilter.setValue(1.0 - intensity * 0.35, forKey: kCIInputSaturationKey)
        toneFilter.setValue(1.0 - intensity * 0.05, forKey: kCIInputContrastKey)
        guard var milkyImage = toneFilter.outputImage?.cropped(to: imageExtent) else { return image }

        // === 2. Warm cast (peach / cream) ===
        // Pure desaturation pulls skin toward grey, which reads as "lifeless." A small target-neutral
        // shift toward warmer Kelvin (lower K = warmer, more orange/yellow) gives the skin a peach
        // undertone — what pro apps call "alive porcelain." Best-effort: skips silently if the filter
        // fails, leaves milkyImage as the tone-only version.
        if let warmFilter = CIFilter(name: "CITemperatureAndTint") {
            warmFilter.setValue(milkyImage, forKey: kCIInputImageKey)
            warmFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            // Up to ~700K shift at full intensity. Subtle; a 1500K shift would be obviously orange.
            warmFilter.setValue(CIVector(x: 6500 - intensity * 700, y: 0), forKey: "inputTargetNeutral")
            if let warmed = warmFilter.outputImage?.cropped(to: imageExtent) {
                milkyImage = warmed
            }
        }

        // === 3. Subtle texture smoothing ===
        // Input is already at working resolution. Just run the blur directly.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(milkyImage, forKey: kCIInputImageKey)
            blur.setValue(3.0 + intensity * 5.0, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage?.cropped(to: imageExtent),
               let dissolve = CIFilter(name: "CIDissolveTransition") {
                dissolve.setValue(milkyImage, forKey: kCIInputImageKey)
                dissolve.setValue(blurred, forKey: kCIInputTargetImageKey)
                dissolve.setValue(0.30, forKey: kCIInputTimeKey)   // 70% original detail, 30% blurred
                if let mixed = dissolve.outputImage?.cropped(to: imageExtent) {
                    milkyImage = mixed
                }
            }
        }

        // === 4. Mask onto face skin only ===
        // ML pixel-perfect mask if available, polygon fallback otherwise. Unchanged from before.
        let useMask = !detectedFaces.isEmpty || externalSkinMask != nil
        if useMask {
            let faceMask = createMilkyFaceMask(for: detectedFaces, imageExtent: imageExtent)
            if let blendFilter = CIFilter(name: "CIBlendWithMask") {
                blendFilter.setValue(milkyImage, forKey: kCIInputImageKey)
                blendFilter.setValue(image, forKey: kCIInputBackgroundImageKey)
                blendFilter.setValue(faceMask, forKey: kCIInputMaskImageKey)
                return blendFilter.outputImage?.cropped(to: imageExtent) ?? milkyImage
            }
        }
        return milkyImage
    }

    // MARK: - Frequency-separation helpers

    private func gaussianBlurredFullExtent(_ image: CIImage, radius: Double) -> CIImage? {
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        return f.outputImage?.cropped(to: image.extent)
    }

    private func milkyToneAdjust(_ image: CIImage, intensity: Double) -> CIImage? {
        guard let f = CIFilter(name: "CIColorControls") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        // Tuned for porcelain look at intensity=1.0:
        //   +0.18 brightness lift  → noticeably lighter skin
        //   -0.50 saturation        → distinctly desaturated, "creamy" tone
        //   -0.10 contrast          → softer look, less harsh shadows
        // These are applied to the LOW-FREQUENCY layer only, then propagated to the original via
        // toneShift — so detail (pores, hair, lashes) stays sharp.
        f.setValue(intensity * 0.18, forKey: kCIInputBrightnessKey)
        f.setValue(1.0 - intensity * 0.50, forKey: kCIInputSaturationKey)
        f.setValue(1.0 - intensity * 0.10, forKey: kCIInputContrastKey)
        return f.outputImage?.cropped(to: image.extent)
    }

    /// Per-channel out = scale * in + bias. Used to negate an image (-1 / 0) for signed subtraction
    /// via CIAdditionCompositing.
    private func scaleAndOffset(_ image: CIImage, scale: Double, bias: Double) -> CIImage? {
        guard let f = CIFilter(name: "CIColorMatrix") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        let s = CGFloat(scale)
        let b = CGFloat(bias)
        f.setValue(CIVector(x: s, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: s, z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: s, w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        f.setValue(CIVector(x: b, y: b, z: b, w: 0), forKey: "inputBiasVector")
        return f.outputImage?.cropped(to: image.extent)
    }

    /// out = a + b (signed, no clamp until final materialization). CIAdditionCompositing keeps
    /// out-of-range values until the working color space materializes them.
    private func additionComposite(_ a: CIImage, _ b: CIImage) -> CIImage? {
        guard let f = CIFilter(name: "CIAdditionCompositing") else { return nil }
        f.setValue(a, forKey: kCIInputImageKey)
        f.setValue(b, forKey: kCIInputBackgroundImageKey)
        return f.outputImage?.cropped(to: a.extent)
    }

    private func createMilkyFaceMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        // Highest-quality path: per-pixel ML skin mask from FaceParsingService, scaled to match the
        // working extent (live-preview pipeline downsamples; ML mask was generated at sensor res).
        if let mlMask = resolvedExternalMask(for: imageExtent) { return mlMask }
        if faces.contains(where: { $0.faceContour != nil && !($0.faceContour?.isEmpty ?? true) }) {
            return createSkinPolygonMask(for: faces, imageExtent: imageExtent)
        }
        var combinedMask: CIImage?
        for face in faces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )
            let faceMask = createEllipticalMask(for: faceRect, imageExtent: imageExtent)
            if let existing = combinedMask {
                guard let addFilter = CIFilter(name: "CIMaximumCompositing") else { continue }
                addFilter.setValue(existing, forKey: kCIInputImageKey)
                addFilter.setValue(faceMask, forKey: kCIInputBackgroundImageKey)
                combinedMask = addFilter.outputImage
            } else {
                combinedMask = faceMask
            }
        }
        return combinedMask ?? CIImage(color: CIColor.black).cropped(to: imageExtent)
    }

    // MARK: - Vision-landmark skin polygon mask

    /// Cached polygon mask, keyed by image extent + smoothed landmark fingerprint. Rebuilt on the CPU
    /// via CGContext at every detection cycle (~6 Hz) and reused for in-between frames so the per-frame
    /// cost stays near zero. The mask is feathered so the edge between smoothed and untouched pixels
    /// is invisible.
    private var cachedSkinMask: CIImage?
    private var cachedSkinMaskKey: String = ""

    private func createSkinPolygonMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        // Build a cache key from face bounding boxes — landmarks come from the same smoothing pipeline,
        // so when boxes are unchanged, the polygons are too.
        let key = "\(Int(imageExtent.width))x\(Int(imageExtent.height))|" + faces.map {
            String(format: "%.4f,%.4f,%.4f,%.4f", $0.boundingBox.origin.x, $0.boundingBox.origin.y, $0.boundingBox.width, $0.boundingBox.height)
        }.joined(separator: ";")
        if key == cachedSkinMaskKey, let cached = cachedSkinMask { return cached }

        // Mask resolution: cap the longer side at 512 px. Mask is upsampled with bilinear filtering
        // at usage time, so this is invisible visually and ~64× cheaper to render than full 4K.
        // Smaller is critical now that we're using lazy blur (blur cost scales with mask area).
        let longest: CGFloat = 512
        let scale = min(1.0, longest / max(imageExtent.width, imageExtent.height))
        let maskWidth  = Int((imageExtent.width  * scale).rounded())
        let maskHeight = Int((imageExtent.height * scale).rounded())
        guard maskWidth > 0, maskHeight > 0 else { return CIImage(color: .black).cropped(to: imageExtent) }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: maskWidth, height: maskHeight, bitsPerComponent: 8,
                                  bytesPerRow: maskWidth, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .black).cropped(to: imageExtent)
        }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))

        let toMask: (CGPoint) -> CGPoint = { p in
            // Polygon points are in Y-down screen-normalized space; CGContext is Y-up. Flip on Y so the
            // resulting mask aligns with the source CIImage (which Core Image treats as Y-up).
            CGPoint(x: p.x * CGFloat(maskWidth), y: (1.0 - p.y) * CGFloat(maskHeight))
        }

        for face in faces {
            // Fill the face contour polygon white. Vision's faceContour is an OPEN arc from one ear,
            // along the jaw, around the chin, to the other ear — so filling it directly closes the line
            // ear-to-ear and leaves the forehead OUT. We extend the polygon up to the top of the
            // bounding box on both ends so it actually covers the full face including forehead.
            if let contour = face.faceContour, contour.count >= 3 {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                fillPolygon(in: ctx, points: closedFacePolygon(contour: contour, boundingBox: face.boundingBox).map(toMask))
            } else {
                // Bounding-box ellipse fallback for faces without contour landmarks. Y-down → Y-up flip.
                let bb = face.boundingBox
                let rect = CGRect(x: bb.origin.x * CGFloat(maskWidth),
                                  y: (1.0 - bb.origin.y - bb.height) * CGFloat(maskHeight),
                                  width:  bb.width  * CGFloat(maskWidth),
                                  height: bb.height * CGFloat(maskHeight))
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fillEllipse(in: rect)
            }

            // Carve out features (eyes, lips, brows, nostril area) so smoothing doesn't touch them.
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for poly in [face.leftEye, face.rightEye, face.outerLips, face.leftEyebrow, face.rightEyebrow] {
                if let poly = poly, poly.count >= 3 {
                    fillPolygon(in: ctx, points: expandedPolygon(poly.map(toMask), pad: 4))
                }
            }
        }

        guard let cgImage = ctx.makeImage() else { return CIImage(color: .black).cropped(to: imageExtent) }
        var mask = CIImage(cgImage: cgImage)

        // Feather at the polygon's native low resolution with a proportionally scaled radius.
        // No materialization via createCGImage — that was allocating fresh IOSurfaces every detection
        // cycle and exhausting the GPU surface pool, causing the
        // "IOSurface signalled err=-536870206" flood and eventual signal-9 process kill.
        // Lazy chain is reused by Core Image internally; per-frame cost is acceptable at 512 res.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(mask, forKey: kCIInputImageKey)
            let imageSpaceRadius = max(imageExtent.width, imageExtent.height) * 0.006
            blur.setValue(imageSpaceRadius * scale, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage?.cropped(to: mask.extent) { mask = blurred }
        }

        if scale < 1.0 {
            let inv = 1.0 / scale
            mask = mask.transformed(by: CGAffineTransform(scaleX: inv, y: inv))
        }
        mask = mask.transformed(by: CGAffineTransform(translationX: imageExtent.origin.x, y: imageExtent.origin.y))

        cachedSkinMask = mask
        cachedSkinMaskKey = key
        return mask
    }

    /// Close Vision's open jaw contour into a full face polygon by adding upper points along the top
    /// of the face bounding box, so the polygon includes the forehead/upper face area.
    private func closedFacePolygon(contour: [CGPoint], boundingBox: CGRect) -> [CGPoint] {
        guard let first = contour.first, let last = contour.last else { return contour }
        // contour is roughly: left ear → jawline → chin → right ear (Y-down, screen coords).
        // Top of face = boundingBox.minY (Y-down). Push slightly above the box to include the
        // forehead / hairline (~10 % of face height above the bbox top) without going into hair.
        let foreheadY = max(0, boundingBox.minY - boundingBox.height * 0.05)
        var poly = contour
        // From the last contour point (one ear) up to the top of the bounding box, across to above
        // the first contour point, then back down. Polygon is auto-closed when filled.
        poly.append(CGPoint(x: last.x,  y: foreheadY))
        poly.append(CGPoint(x: first.x, y: foreheadY))
        return poly
    }

    private func fillPolygon(in ctx: CGContext, points: [CGPoint]) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()
    }

    /// Push polygon points slightly outward from their centroid so feature cutouts have a small
    /// safety margin around each landmark.
    private func expandedPolygon(_ points: [CGPoint], pad: CGFloat) -> [CGPoint] {
        guard !points.isEmpty else { return points }
        let cx = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        let cy = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        return points.map { p in
            let dx = p.x - cx, dy = p.y - cy
            let d = max(0.001, sqrt(dx * dx + dy * dy))
            return CGPoint(x: p.x + dx / d * pad, y: p.y + dy / d * pad)
        }
    }

    private func applyLipPlump(to image: CIImage) -> CIImage {
        guard !detectedFaces.isEmpty else { return image }
        var warped = image
        let imageExtent = image.extent

        // motionFade prevents the warp from appearing in the wrong place during head movement
        // (CIBumpDistortion centers can lag behind the face by 1-2 detection cycles).
        let intensity = Double(lipPlumpIntensity) * Double(motionFade)
        if abs(intensity) < 0.001 { return image }

        // === 1) CHEEK-APPLE bump distortion ===
        //
        // Despite the legacy field name `lipPlump`, this slider sculpts the CHEEKS:
        //   slider > 0  →  positive scale  →  CIBumpDistortion expands outward  →  fuller cheeks
        //   slider < 0  →  negative scale  →  CIBumpDistortion pinches inward   →  slimmer cheeks
        //
        // Bump centers are placed at the cheek-apple anatomical position:
        //   X: 25 % / 75 % of face width  (just inboard of the cheekbone)
        //   Y: 50 % of face height        (mid-face — between eyes and mouth)
        // Radius covers the cheek apple area without reaching eyes or lips.
        for face in detectedFaces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )

            // Landmark-based cheek positioning. This is invariant to how the face bounding box is
            // padded — front and back cameras can produce different amounts of hair / forehead in
            // the bbox depending on detection, so bbox-relative positions land slightly off on one
            // camera vs the other. Eye + mouth landmarks give the same anatomical cheek apple
            // position consistently across cameras and head poses.
            let centers: [(CGPoint, CGFloat)] = cheekCenters(for: face, imageExtent: imageExtent)
                ?? bboxFallbackCenters(faceRect: faceRect)

            // Scale bumped to 0.55 (was 0.45) to keep visible strength similar after the radius
            // shrinkage above. Smaller, more concentrated bumps that don't reach the nose or silhouette
            // — slim and plump now sculpt the cheek apple cleanly without distorting other features.
            let scale = intensity * 0.55

            for (center, radius) in centers {
                guard let bump = CIFilter(name: "CIBumpDistortion") else { continue }
                bump.setValue(warped, forKey: kCIInputImageKey)
                bump.setValue(CIVector(x: center.x, y: center.y), forKey: kCIInputCenterKey)
                bump.setValue(radius, forKey: kCIInputRadiusKey)
                bump.setValue(scale, forKey: kCIInputScaleKey)
                if let result = bump.outputImage?.cropped(to: imageExtent) { warped = result }
            }
        }

        // === 2) Mask the warp to face skin — temporally synced ===
        //
        // Plump deliberately does NOT use the ML mask (externalSkinMask). The ML mask is more
        // spatially precise (per-pixel skin segmentation) but lags 1–2 detection cycles because
        // it comes from FaceParsingService running asynchronously. For color filters like milky,
        // that lag is invisible — but for warping filters like plump, the mask edge has to track
        // the face frame-by-frame, otherwise displaced pixels show up beyond the face silhouette
        // (the "small overlay out of place" artifact, especially during head turns).
        //
        // The face-contour polygon mask is built from the SAME detection pass that produced the
        // bump centers, so the warp and the mask are always at the same face position.
        let hasContour = detectedFaces.contains { face in
            if let c = face.faceContour { return !c.isEmpty }
            return false
        }
        let baseMask: CIImage = hasContour
            ? createSkinPolygonMask(for: detectedFaces, imageExtent: imageExtent)
            : createPlumpMask(for: detectedFaces, imageExtent: imageExtent)

        // Plump-specific extra softening, cached so the blur doesn't recompute on every frame.
        // Total mask gradient = polygon's built-in feather + this extra blur ≈ wider than warp
        // displacement, so the warp transition stays smooth.
        let mask = plumpExtraSoftenedMask(baseMask, imageExtent: imageExtent)

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return warped }
        blend.setValue(warped, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: imageExtent) ?? warped
    }

    /// Apply plump-specific extra softening to the base mask. Lazy chain only — no createCGImage
    /// calls because they allocate fresh IOSurfaces per detection cycle and exhaust the GPU surface
    /// pool (caused the IOSurface error flood + signal-9 process kill).
    ///
    /// The base mask is already cached and at 512-px native resolution, so the lazy Gaussian blur
    /// here is cheap. CIContext reuses intermediate textures internally across multiple calls within
    /// a render pass, so per-frame cost stays under control.
    private func plumpExtraSoftenedMask(_ baseMask: CIImage, imageExtent: CGRect) -> CIImage {
        guard let extraSoften = CIFilter(name: "CIGaussianBlur") else { return baseMask }
        extraSoften.setValue(baseMask, forKey: kCIInputImageKey)
        extraSoften.setValue(max(imageExtent.width, imageExtent.height) * 0.018, forKey: kCIInputRadiusKey)
        return extraSoften.outputImage?.cropped(to: imageExtent) ?? baseMask
    }

    /// Anatomically-correct cheek-apple positions from Vision face landmarks. Returns each cheek's
    /// (center, radius) in CIImage Y-up coordinates. Returns nil if any required landmark is missing.
    ///
    /// Cheek X is horizontally aligned with the eye center; Y is midway between eye and mouth — the
    /// classic "where the cheek bone is most visible" anatomical landmark. Radius is derived from
    /// inter-eye distance (not bbox width), so it's invariant to how much hair / forehead the face
    /// bounding box happens to include — which is what was producing the front-camera-only artifact
    /// we saw with the previous bbox-relative positioning.
    private func cheekCenters(for face: DetectedFace, imageExtent: CGRect) -> [(CGPoint, CGFloat)]? {
        guard let leftEye = centroid(of: face.leftEye),
              let rightEye = centroid(of: face.rightEye),
              let mouth = centroid(of: face.outerLips) else { return nil }

        // Inter-eye distance in normalized space. Used both as a scale reference for the radius and
        // for the outboard offset that places cheek centers laterally outside the eye axis (where
        // the cheekbone actually is anatomically).
        let dxN = rightEye.x - leftEye.x
        let eyeDistanceN = abs(dxN)
        let direction: CGFloat = dxN >= 0 ? 1 : -1
        // 15% outboard offset — places cheek center on the cheekbone line (lateral to eye), not
        // directly under the pupil. This also pushes the two bumps apart so they don't overlap at
        // the nose, which was producing the "stretched nose" artifact at strong slim values.
        let outboardN = eyeDistanceN * 0.15

        let leftCheekN  = CGPoint(x: leftEye.x  - direction * outboardN,
                                  y: (leftEye.y  + mouth.y) / 2)
        let rightCheekN = CGPoint(x: rightEye.x + direction * outboardN,
                                  y: (rightEye.y + mouth.y) / 2)

        // Convert to CI Y-up image coordinates.
        func toCIPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * imageExtent.width + imageExtent.origin.x,
                    y: (1.0 - p.y) * imageExtent.height + imageExtent.origin.y)
        }
        let leftCheek = toCIPoint(leftCheekN)
        let rightCheek = toCIPoint(rightCheekN)

        // Radius in image pixels. Reduced from 0.50 → 0.28 of inter-eye distance so:
        //   • bumps don't overlap at the nose (gap between bumps now ~0.70 × eye-distance, well
        //     wider than typical nose width)
        //   • bumps don't reach the face silhouette (gap to silhouette ~0.30 × eye-distance)
        let dyN = rightEye.y - leftEye.y
        let dxImg = dxN * imageExtent.width
        let dyImg = dyN * imageExtent.height
        let eyeDistance = sqrt(dxImg * dxImg + dyImg * dyImg)

        // Radius: 0.32 × eye-distance is wide enough for a clearly visible cheek effect, narrow
        // enough that the bumps don't overlap at the nose (gap remains ~0.66 × eye-distance). On
        // very-close-up front-camera shots the eye distance can be huge, which makes the bump
        // expensive to compute — cap at 200 px so frame rate stays solid even at extreme close-ups.
        let baseRadius = eyeDistance * 0.32
        let radius = min(baseRadius, 200.0)
        return [(leftCheek, radius), (rightCheek, radius)]
    }

    /// Fallback cheek positions when landmarks aren't available: 30 / 70 % of bbox width, mid-height.
    private func bboxFallbackCenters(faceRect: CGRect) -> [(CGPoint, CGFloat)] {
        let cheekY = faceRect.origin.y + faceRect.height * 0.50
        let leftCheekX  = faceRect.origin.x + faceRect.width * 0.30
        let rightCheekX = faceRect.origin.x + faceRect.width * 0.70
        let radius = faceRect.width * 0.16
        return [(CGPoint(x: leftCheekX, y: cheekY), radius),
                (CGPoint(x: rightCheekX, y: cheekY), radius)]
    }

    private func centroid(of points: [CGPoint]?) -> CGPoint? {
        guard let pts = points, !pts.isEmpty else { return nil }
        let n = CGFloat(pts.count)
        let sx = pts.reduce(0) { $0 + $1.x }
        let sy = pts.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / n, y: sy / n)
    }

    /// Soft elliptical mask covering the cheek-apple region of each face (middle 60 % vertically,
    /// 90 % horizontally). Used only as a fallback — when the ML skin mask is available, plump uses
    /// that instead. The mask must comfortably contain the bump-distortion radius around each cheek
    /// center; a tighter mask would clip the warp at its edges and produce visible artifacts.
    private func createPlumpMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        var combined: CIImage?
        for face in faces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )

            // CIImage uses Y-up: faceRect.origin.y is the face bottom. Cheek band runs from ~20 % to
            // ~80 % of face height — well around the cheek-apple bump centers at 50 %.
            let insetX = faceRect.width * 0.05
            let cheekBandStartY = faceRect.origin.y + faceRect.height * 0.20
            let cheekBandHeight = faceRect.height * 0.60
            let maskRect = CGRect(
                x: faceRect.origin.x + insetX,
                y: cheekBandStartY,
                width: faceRect.width - insetX * 2,
                height: cheekBandHeight
            )
            let mask = createEllipticalMask(for: maskRect, imageExtent: imageExtent, softEdge: true)
            if let existing = combined {
                guard let add = CIFilter(name: "CIMaximumCompositing") else { continue }
                add.setValue(existing, forKey: kCIInputImageKey)
                add.setValue(mask, forKey: kCIInputBackgroundImageKey)
                combined = add.outputImage
            } else {
                combined = mask
            }
        }
        return combined?.cropped(to: imageExtent) ?? CIImage(color: CIColor.black).cropped(to: imageExtent)
    }

    private func applyBackgroundBlur(to image: CIImage, fullResolution: Bool = false) -> CIImage {
        guard #available(iOS 15.0, *),
              let request = personSegmentationRequest as? VNGeneratePersonSegmentationRequest else {
            return image
        }

        let imageExtent = image.extent
        segmentationFrameCounter += 1
        let imageSizeChanged = abs(imageExtent.width  - cachedMaskSourceSize.width)  > 100
                            || abs(imageExtent.height - cachedMaskSourceSize.height) > 100

        if segmentationFrameCounter % 8 == 0 || cachedPersonMask == nil || imageSizeChanged {
            // Render the input at half resolution for VN segmentation. The person mask comes back at
            // VN's own model resolution regardless of input size, then we scale it to imageExtent
            // anyway — so a 4K input is wasted. Half-res input cuts createCGImage cost ~4× and is
            // visually identical after the soft mask blur.
            let segScale: CGFloat = 0.5
            let segExtent = CGRect(
                x: imageExtent.origin.x * segScale, y: imageExtent.origin.y * segScale,
                width:  imageExtent.width  * segScale, height: imageExtent.height * segScale
            )
            let segInput = image.transformed(by: CGAffineTransform(scaleX: segScale, y: segScale))
            guard let cgImage = context.createCGImage(segInput, from: segExtent) else { return image }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                if let result = request.results?.first {
                    var maskImage = CIImage(cvPixelBuffer: result.pixelBuffer)
                    let scaleX = imageExtent.width  / maskImage.extent.width
                    let scaleY = imageExtent.height / maskImage.extent.height
                    maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                    if let maskBlur = CIFilter(name: "CIGaussianBlur") {
                        maskBlur.setValue(maskImage, forKey: kCIInputImageKey)
                        maskBlur.setValue(4.0, forKey: kCIInputRadiusKey)
                        if let softMask = maskBlur.outputImage?.cropped(to: imageExtent) { maskImage = softMask }
                    }
                    cachedPersonMask = maskImage
                    cachedMaskSourceSize = imageExtent.size
                }
            } catch { return image }
        }

        guard let personMask = cachedPersonMask else { return image }

        let blurRadius = Double(5 + backgroundBlurIntensity * 20)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        // Even at 2560 working extent, a CIGaussianBlur with radius up to 25 dominates the frame.
        // CIGaussianBlur cost scales with pixel count × radius². Downsample 4× and blur at 1/4 the
        // radius — same visual result for a soft Gaussian (it's about to be blended behind a person
        // mask anyway), ~16× cheaper. Upsample is lazy; Metal does the bilinear at display time.
        let blurScale: CGFloat = 0.25
        let blurDownExtent = CGRect(
            x: imageExtent.origin.x * blurScale, y: imageExtent.origin.y * blurScale,
            width:  imageExtent.width  * blurScale, height: imageExtent.height * blurScale
        )
        let blurInput = image
            .transformed(by: CGAffineTransform(scaleX: blurScale, y: blurScale))
            .cropped(to: blurDownExtent)
        blurFilter.setValue(blurInput, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius * Double(blurScale), forKey: kCIInputRadiusKey)
        guard let blurredSmall = blurFilter.outputImage?.cropped(to: blurDownExtent) else { return image }
        let inv = 1.0 / blurScale
        let blurredImage = blurredSmall
            .transformed(by: CGAffineTransform(scaleX: inv, y: inv))
            .cropped(to: imageExtent)

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return image }
        blendFilter.setValue(image, forKey: kCIInputImageKey)
        blendFilter.setValue(blurredImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(personMask, forKey: kCIInputMaskImageKey)
        return blendFilter.outputImage?.cropped(to: imageExtent) ?? image
    }

    private func applyFaceOnlySmooth(to image: CIImage, fullResolution: Bool) -> CIImage {
        guard !detectedFaces.isEmpty else { return image }
        let effectiveIntensity = faceSmoothIntensity * motionFade
        if effectiveIntensity < 0.01 { return image }

        // Input is already at the working resolution (downsampled by processImage for live preview,
        // or full sensor for photo capture). No per-filter downsampling needed.
        if let processor = skinSmoothingProcessor {
            processor.sigmaSpace = 5.0 + effectiveIntensity * 5.0
            processor.sigmaColor = 0.05 + (1.0 - effectiveIntensity) * 0.1
            return processor.processImage(image, faces: detectedFaces, intensity: effectiveIntensity)
        }
        return applyFaceOnlySmoothFallback(to: image)
    }

    private func applyFaceColorTint(to image: CIImage) -> CIImage {
        guard !detectedFaces.isEmpty else { return image }
        let imageExtent = image.extent
        let tintColor = CIColor(red: CGFloat(faceColorTintRed), green: CGFloat(faceColorTintGreen),
                                blue: CGFloat(faceColorTintBlue), alpha: 1.0)
        let tintImage = CIImage(color: tintColor).cropped(to: imageExtent)

        guard let blendFilter = CIFilter(name: "CISoftLightBlendMode") else { return image }
        blendFilter.setValue(tintImage, forKey: kCIInputImageKey)
        blendFilter.setValue(image, forKey: kCIInputBackgroundImageKey)
        guard let tintedImage = blendFilter.outputImage?.cropped(to: imageExtent) else { return image }

        guard let intensityBlend = CIFilter(name: "CIDissolveTransition") else { return image }
        intensityBlend.setValue(image, forKey: kCIInputImageKey)
        intensityBlend.setValue(tintedImage, forKey: kCIInputTargetImageKey)
        intensityBlend.setValue(Double(faceColorTintIntensity), forKey: kCIInputTimeKey)
        guard let intensityAdjusted = intensityBlend.outputImage?.cropped(to: imageExtent) else { return image }

        let faceMask = createFaceMaskForColorTint(for: detectedFaces, imageExtent: imageExtent)
        guard let maskBlend = CIFilter(name: "CIBlendWithMask") else { return image }
        maskBlend.setValue(intensityAdjusted, forKey: kCIInputImageKey)
        maskBlend.setValue(image, forKey: kCIInputBackgroundImageKey)
        maskBlend.setValue(faceMask, forKey: kCIInputMaskImageKey)
        return maskBlend.outputImage ?? image
    }

    private func createFaceMaskForColorTint(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        var combinedMask: CIImage?
        for face in faces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )
            let expandedRect = faceRect.insetBy(dx: -faceRect.width * 0.1, dy: -faceRect.height * 0.1)
            var faceMask = createEllipticalMask(for: expandedRect, imageExtent: imageExtent)

            if let leftEyeRegion = face.leftEyeRegion {
                let r = convertNormalizedToImage(leftEyeRegion, imageExtent: imageExtent, expandBy: 1.2)
                faceMask = subtractMask(createEllipticalMask(for: r, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let rightEyeRegion = face.rightEyeRegion {
                let r = convertNormalizedToImage(rightEyeRegion, imageExtent: imageExtent, expandBy: 1.2)
                faceMask = subtractMask(createEllipticalMask(for: r, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let mouthRegion = face.mouthRegion {
                let r = convertNormalizedToImage(mouthRegion, imageExtent: imageExtent, expandBy: 1.1)
                faceMask = subtractMask(createEllipticalMask(for: r, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }

            if let existing = combinedMask {
                guard let addFilter = CIFilter(name: "CIMaximumCompositing") else { continue }
                addFilter.setValue(existing, forKey: kCIInputImageKey)
                addFilter.setValue(faceMask, forKey: kCIInputBackgroundImageKey)
                combinedMask = addFilter.outputImage
            } else {
                combinedMask = faceMask
            }
        }
        return combinedMask ?? CIImage(color: CIColor.black).cropped(to: imageExtent)
    }

    private func applyFaceOnlySmoothFallback(to image: CIImage) -> CIImage {
        let imageExtent = image.extent
        let blurRadius = Double(3 + faceSmoothIntensity * 7)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredImage = blurFilter.outputImage?.cropped(to: imageExtent) else { return image }
        let faceMask = createFaceMask(for: detectedFaces, imageExtent: imageExtent)
        return applyEdgePreservingBlend(original: image, blurred: blurredImage, mask: faceMask)
    }

    private func createFaceMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        // Highest-quality path: per-pixel ML skin mask, scaled to working extent.
        if let mlMask = resolvedExternalMask(for: imageExtent) { return mlMask }
        if faces.contains(where: { $0.faceContour != nil && !($0.faceContour?.isEmpty ?? true) }) {
            return createSkinPolygonMask(for: faces, imageExtent: imageExtent)
        }
        var combinedMask: CIImage?
        for face in faces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )
            let expandedRect = faceRect.insetBy(dx: -faceRect.width * 0.15, dy: -faceRect.height * 0.15)
            var faceMask = createEllipticalMask(for: expandedRect, imageExtent: imageExtent)

            if let r = face.leftEyeRegion {
                let er = convertNormalizedToImage(r, imageExtent: imageExtent, expandBy: 1.4)
                faceMask = subtractMask(createEllipticalMask(for: er, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let r = face.rightEyeRegion {
                let er = convertNormalizedToImage(r, imageExtent: imageExtent, expandBy: 1.4)
                faceMask = subtractMask(createEllipticalMask(for: er, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let r = face.noseRegion {
                let nr = convertNormalizedToImage(r, imageExtent: imageExtent, expandBy: 1.2)
                faceMask = subtractMask(createEllipticalMask(for: nr, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let r = face.mouthRegion {
                let mr = convertNormalizedToImage(r, imageExtent: imageExtent, expandBy: 1.3)
                faceMask = subtractMask(createEllipticalMask(for: mr, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let r = face.leftEyeRegion {
                let eyebrow = CGRect(x: r.origin.x - r.width*0.1, y: r.origin.y - r.height*1.8, width: r.width*1.2, height: r.height*0.7)
                let ebr = convertNormalizedToImage(eyebrow, imageExtent: imageExtent, expandBy: 1.0)
                faceMask = subtractMask(createEllipticalMask(for: ebr, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }
            if let r = face.rightEyeRegion {
                let eyebrow = CGRect(x: r.origin.x - r.width*0.1, y: r.origin.y - r.height*1.8, width: r.width*1.2, height: r.height*0.7)
                let ebr = convertNormalizedToImage(eyebrow, imageExtent: imageExtent, expandBy: 1.0)
                faceMask = subtractMask(createEllipticalMask(for: ebr, imageExtent: imageExtent, softEdge: true), from: faceMask, imageExtent: imageExtent)
            }

            if let existing = combinedMask {
                guard let addFilter = CIFilter(name: "CIMaximumCompositing") else { continue }
                addFilter.setValue(existing, forKey: kCIInputImageKey)
                addFilter.setValue(faceMask, forKey: kCIInputBackgroundImageKey)
                combinedMask = addFilter.outputImage
            } else {
                combinedMask = faceMask
            }
        }
        return combinedMask ?? CIImage(color: CIColor.black).cropped(to: imageExtent)
    }

    private func convertNormalizedToImage(_ normalizedRect: CGRect, imageExtent: CGRect, expandBy: CGFloat) -> CGRect {
        let imageRect = CGRect(
            x: normalizedRect.origin.x * imageExtent.width + imageExtent.origin.x,
            y: (1 - normalizedRect.origin.y - normalizedRect.height) * imageExtent.height + imageExtent.origin.y,
            width: normalizedRect.width * imageExtent.width,
            height: normalizedRect.height * imageExtent.height
        )
        let expandX = imageRect.width  * (expandBy - 1) / 2
        let expandY = imageRect.height * (expandBy - 1) / 2
        return imageRect.insetBy(dx: -expandX, dy: -expandY)
    }

    private func subtractMask(_ subtraction: CIImage, from base: CIImage, imageExtent: CGRect) -> CIImage {
        guard let invertFilter = CIFilter(name: "CIColorInvert") else { return base }
        invertFilter.setValue(subtraction, forKey: kCIInputImageKey)
        guard let inverted = invertFilter.outputImage?.cropped(to: imageExtent) else { return base }
        guard let multiplyFilter = CIFilter(name: "CIMultiplyCompositing") else { return base }
        multiplyFilter.setValue(base, forKey: kCIInputImageKey)
        multiplyFilter.setValue(inverted, forKey: kCIInputBackgroundImageKey)
        return multiplyFilter.outputImage?.cropped(to: imageExtent) ?? base
    }

    private func createEllipticalMask(for rect: CGRect, imageExtent: CGRect, softEdge: Bool = false, extraSoft: Bool = false) -> CIImage {
        let centerX = rect.midX, centerY = rect.midY
        let radiusX = rect.width / 2, radiusY = rect.height / 2
        guard let radialGradient = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }
        let avgRadius = (radiusX + radiusY) / 2
        let innerFactor: CGFloat = extraSoft ? 0.20 : (softEdge ? 0.4 : 0.6)
        let outerFactor: CGFloat = extraSoft ? 1.85 : (softEdge ? 1.4 : 1.2)

        radialGradient.setValue(CIVector(x: centerX, y: centerY), forKey: "inputCenter")
        radialGradient.setValue(avgRadius * innerFactor, forKey: "inputRadius0")
        radialGradient.setValue(avgRadius * outerFactor, forKey: "inputRadius1")
        radialGradient.setValue(CIColor.white, forKey: "inputColor0")
        radialGradient.setValue(CIColor.black, forKey: "inputColor1")

        guard var mask = radialGradient.outputImage else {
            return CIImage(color: CIColor.black).cropped(to: imageExtent)
        }

        if abs(radiusX - radiusY) > 1 {
            let scaleX = radiusX / avgRadius, scaleY = radiusY / avgRadius
            let transform = CGAffineTransform(translationX: -centerX, y: -centerY)
                .scaledBy(x: scaleX, y: scaleY)
                .translatedBy(x: centerX / scaleX, y: centerY / scaleY)
            mask = mask.transformed(by: transform)
        }
        return mask.cropped(to: imageExtent)
    }

    private func applyEdgePreservingBlend(original: CIImage, blurred: CIImage, mask: CIImage) -> CIImage {
        guard let edgeFilter = CIFilter(name: "CIEdges") else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        edgeFilter.setValue(original, forKey: kCIInputImageKey)
        edgeFilter.setValue(1.0, forKey: kCIInputIntensityKey)
        guard let edges = edgeFilter.outputImage else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        guard let invertFilter = CIFilter(name: "CIColorInvert") else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        invertFilter.setValue(edges, forKey: kCIInputImageKey)
        guard let invertedEdges = invertFilter.outputImage?.cropped(to: original.extent) else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        guard let multiplyFilter = CIFilter(name: "CIMultiplyCompositing") else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        multiplyFilter.setValue(mask, forKey: kCIInputImageKey)
        multiplyFilter.setValue(invertedEdges, forKey: kCIInputBackgroundImageKey)
        guard let combinedMask = multiplyFilter.outputImage else {
            return blendWithMask(original: original, blurred: blurred, mask: mask)
        }
        return blendWithMask(original: original, blurred: blurred, mask: combinedMask)
    }

    private func blendWithMask(original: CIImage, blurred: CIImage, mask: CIImage) -> CIImage {
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return original }
        blendFilter.setValue(blurred, forKey: kCIInputImageKey)
        blendFilter.setValue(original, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)
        return blendFilter.outputImage ?? original
    }

    private func applySmoothSkin(to image: CIImage) -> CIImage {
        let blurRadius = Double(2 + smoothIntensity * 4)
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return image }
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredImage = blurFilter.outputImage else { return image }
        let croppedBlurred = blurredImage.cropped(to: image.extent)
        let blendAmount = Double(0.3 + smoothIntensity * 0.4)
        guard let dissolveFilter = CIFilter(name: "CIDissolveTransition") else { return croppedBlurred }
        dissolveFilter.setValue(image, forKey: kCIInputImageKey)
        dissolveFilter.setValue(croppedBlurred, forKey: kCIInputTargetImageKey)
        dissolveFilter.setValue(blendAmount, forKey: kCIInputTimeKey)
        return dissolveFilter.outputImage ?? croppedBlurred
    }

    private func applyWarmTone(to image: CIImage) -> CIImage {
        let temperature = 6500 - (warmthIntensity * 1500)
        let tint = warmthIntensity * 20
        guard let tempFilter = CIFilter(name: "CITemperatureAndTint") else { return image }
        tempFilter.setValue(image, forKey: kCIInputImageKey)
        tempFilter.setValue(CIVector(x: CGFloat(temperature), y: 0), forKey: "inputNeutral")
        tempFilter.setValue(CIVector(x: CGFloat(6500), y: CGFloat(tint)), forKey: "inputTargetNeutral")
        guard let tempOutput = tempFilter.outputImage else { return image }
        guard let colorFilter = CIFilter(name: "CIColorControls") else { return tempOutput }
        colorFilter.setValue(tempOutput, forKey: kCIInputImageKey)
        colorFilter.setValue(1.0 + Double(warmthIntensity * 0.1), forKey: kCIInputSaturationKey)
        colorFilter.setValue(Double(warmthIntensity * 0.05), forKey: kCIInputBrightnessKey)
        colorFilter.setValue(1.0 + Double(warmthIntensity * 0.05), forKey: kCIInputContrastKey)
        return colorFilter.outputImage ?? tempOutput
    }

    func renderToPixelBuffer(_ image: CIImage, to pixelBuffer: CVPixelBuffer) {
        context.render(image, to: pixelBuffer)
    }

    func renderToCGImage(_ image: CIImage) -> CGImage? {
        return context.createCGImage(image, from: image.extent)
    }
}
