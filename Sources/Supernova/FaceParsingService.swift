import Foundation
import CoreImage
import CoreML
import Vision

/// Runs a Core ML face-parsing model (BiSeNet trained on CelebAMask-HQ, 19 classes)
/// and returns a per-pixel skin mask aligned to the source image's extent.
///
/// The mask treats CelebAMask-HQ classes 1 (skin) and 14 (neck) as foreground; everything else
/// (eyes, eyebrows, lips, nose, hair, glasses, ears, clothing, background) is excluded automatically.
/// This is the per-pixel equivalent of what we were approximating with the Vision-landmark polygon —
/// no jaw-only arc, no ear-to-ear closure hack, no eye/lip cutouts: the model labels every pixel.
///
/// Place the Core ML model at `Sources/Supernova/Resources/FaceParsing.{mlmodel,mlmodelc,mlpackage}`.
/// If it isn't present at runtime, `isAvailable` is false and callers fall back to the polygon mask.
final class FaceParsingService {

    /// CelebAMask-HQ class indices we treat as skin foreground.
    /// 0 background  · 1 skin  · 2 l_brow  · 3 r_brow  · 4 l_eye  · 5 r_eye  · 6 eye_g  · 7 l_ear
    /// 8 r_ear      · 9 ear_r · 10 nose   · 11 mouth  · 12 u_lip · 13 l_lip · 14 neck  · 15 neck_l
    /// 16 cloth     · 17 hair · 18 hat
    private static let skinClasses: Set<Int> = [1, 14]

    private let visionModel: VNCoreMLModel?
    private let inputWidth: Int
    private let inputHeight: Int
    private let parsingQueue = DispatchQueue(label: "com.supernova.faceparsing", qos: .userInitiated)

    private let stateLock = NSLock()
    private var isProcessing = false
    private var cachedMask: CIImage?

    var isAvailable: Bool { visionModel != nil }

    init() {
        let bundle = Bundle.module

        // Look for the model under several common names. john-rocky's repo ships .mlmodel, while
        // models converted via the script we provided produce .mlpackage. Both work.
        let candidateNames = ["FaceParsing", "face_parsing", "BiSeNet", "FaceParser", "face-parsing"]
        let extensions = ["mlpackage", "mlmodelc", "mlmodel"]

        var modelURL: URL?
        outer: for name in candidateNames {
            for ext in extensions {
                if let url = bundle.url(forResource: name, withExtension: ext) {
                    modelURL = url
                    break outer
                }
            }
        }

        guard let url = modelURL else {
            print("[FaceParsing] ❌ Model NOT FOUND in Bundle.module. Falling back to polygon mask. " +
                  "Looked for: \(candidateNames.map { $0 }) × \(extensions)")
            self.visionModel = nil
            self.inputWidth = 512
            self.inputHeight = 512
            return
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all   // CPU + GPU + Neural Engine

        do {
            // .mlpackage / .mlmodel must be compiled at runtime. Pre-compiled .mlmodelc uses url directly.
            let compiledURL: URL
            if url.pathExtension == "mlmodelc" {
                compiledURL = url
            } else {
                compiledURL = try MLModel.compileModel(at: url)
            }
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
            self.visionModel = try VNCoreMLModel(for: mlModel)

            // Introspect input size so we don't hard-code 512.
            if let input = mlModel.modelDescription.inputDescriptionsByName.values.first {
                if let imageConstraint = input.imageConstraint {
                    self.inputWidth = imageConstraint.pixelsWide
                    self.inputHeight = imageConstraint.pixelsHigh
                } else if let arrayConstraint = input.multiArrayConstraint, arrayConstraint.shape.count >= 4 {
                    // [batch, channels, H, W]
                    self.inputHeight = arrayConstraint.shape[2].intValue
                    self.inputWidth  = arrayConstraint.shape[3].intValue
                } else {
                    self.inputWidth = 512
                    self.inputHeight = 512
                }
            } else {
                self.inputWidth = 512
                self.inputHeight = 512
            }
            print("[FaceParsing] ✅ Model loaded — input \(self.inputWidth)×\(self.inputHeight), URL=\(url.lastPathComponent)")
        } catch {
            print("[FaceParsing] ❌ Model load FAILED: \(error). Falling back to polygon mask.")
            self.visionModel = nil
            self.inputWidth = 512
            self.inputHeight = 512
        }
    }

    /// Counter for first-parse diagnostic. Logged once.
    private var hasLoggedFirstParse = false

    var lastMask: CIImage? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedMask
    }

    /// Run parsing on the face region of `image`, return a single-channel skin mask aligned to
    /// `imageExtent`. Drops requests if a previous one is still in flight (returns the cached mask).
    /// Mask resolution is the model's input resolution upscaled — small (~512×512) so blending is cheap.
    func parse(
        image: CIImage,
        faceBBox: CGRect,
        imageExtent: CGRect,
        completion: @escaping (CIImage?) -> Void
    ) {
        guard visionModel != nil else { completion(nil); return }

        stateLock.lock()
        if isProcessing {
            let cached = cachedMask
            stateLock.unlock()
            completion(cached)
            return
        }
        isProcessing = true
        stateLock.unlock()

        parsingQueue.async { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.isProcessing = false
                self.stateLock.unlock()
            }

            let mask = self.produceMask(image: image, faceBBox: faceBBox, imageExtent: imageExtent)

            if let mask = mask {
                self.stateLock.lock()
                self.cachedMask = mask
                let firstParse = !self.hasLoggedFirstParse
                self.hasLoggedFirstParse = true
                self.stateLock.unlock()
                if firstParse {
                    print("[FaceParsing] 🎯 First mask produced — ML pipeline is live. " +
                          "Mask extent: \(mask.extent.size)")
                }
                completion(mask)
            } else {
                completion(self.cachedMaskSafe())
            }
        }
    }

    /// Synchronous version. Use for one-shot photo capture where we want a mask matching the captured
    /// photo's pixels (not the lagged live-preview mask). Blocking is fine off the main thread —
    /// inference + mask construction is ~10–20 ms on A14+.
    func parseSync(image: CIImage, faceBBox: CGRect, imageExtent: CGRect) -> CIImage? {
        guard visionModel != nil else { return nil }
        return produceMask(image: image, faceBBox: faceBBox, imageExtent: imageExtent)
    }

    /// Shared crop/inference/positioning pipeline used by both async parse() and sync parseSync().
    private func produceMask(image: CIImage, faceBBox: CGRect, imageExtent: CGRect) -> CIImage? {
        guard let visionModel = visionModel else { return nil }

        // Crop the face region with extra context so the model can see hairline / neck.
        // faceBBox is image-normalized Y-DOWN; CIImage extent is Y-UP.
        let pad: CGFloat = 0.30
        let bboxX = faceBBox.origin.x * imageExtent.width + imageExtent.origin.x
        let bboxYUp = imageExtent.maxY - (faceBBox.origin.y + faceBBox.height) * imageExtent.height
        let bboxW = faceBBox.width  * imageExtent.width
        let bboxH = faceBBox.height * imageExtent.height

        let padX = bboxW * pad
        let padY = bboxH * pad
        let cropX = max(imageExtent.minX, bboxX - padX)
        let cropY = max(imageExtent.minY, bboxYUp - padY)
        let cropMaxX = min(imageExtent.maxX, bboxX + bboxW + padX)
        let cropMaxY = min(imageExtent.maxY, bboxYUp + bboxH + padY)
        let cropRect = CGRect(x: cropX, y: cropY, width: cropMaxX - cropX, height: cropMaxY - cropY)
        guard cropRect.width > 32, cropRect.height > 32 else { return nil }

        let faceCrop = image.cropped(to: cropRect)

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(ciImage: faceCrop, options: [:])
        do { try handler.perform([request]) } catch { return nil }

        guard let results = request.results as? [VNCoreMLFeatureValueObservation],
              let multiArray = results.first?.featureValue.multiArrayValue,
              let cropMask = makeSkinMask(from: multiArray) else { return nil }

        let maskScaleX = cropRect.width  / cropMask.extent.width
        let maskScaleY = cropRect.height / cropMask.extent.height
        var positionedMask = cropMask
            .transformed(by: CGAffineTransform(scaleX: maskScaleX, y: maskScaleY))
            .transformed(by: CGAffineTransform(translationX: cropRect.origin.x, y: cropRect.origin.y))

        let blackBg = CIImage(color: CIColor.black).cropped(to: imageExtent)
        positionedMask = positionedMask.composited(over: blackBg).cropped(to: imageExtent)

        // Heavier feather (1.2% of longest side, was 0.5%) so any residual mask-vs-face misalignment
        // fades into a smooth gradient instead of a visible hard edge.
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(positionedMask, forKey: kCIInputImageKey)
            let radius = max(imageExtent.width, imageExtent.height) * 0.012
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage?.cropped(to: imageExtent) {
                positionedMask = blurred
            }
        }
        return positionedMask
    }

    private func cachedMaskSafe() -> CIImage? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedMask
    }

    /// Convert the model's output MLMultiArray into a single-channel skin mask CIImage.
    ///
    /// Two layouts are supported:
    ///   1. **Argmax baked in** (john-rocky's `faceParsing.mlmodelc`): output is class indices per pixel,
    ///      shape `[1, H, W]`, `[H, W]`, or `[1, 1, H, W]`. We just compare each index to `skinClasses`.
    ///   2. **Raw logits** (any custom conversion of BiSeNet): output is `[1, C, H, W]` or `[C, H, W]`
    ///      with C = 19. We argmax across channels, then compare.
    private func makeSkinMask(from array: MLMultiArray) -> CIImage? {
        let shape = array.shape.map { $0.intValue }
        guard !shape.isEmpty else { return nil }

        // Strip leading singleton dims so we end up with either [H, W] (argmax baked) or [C, H, W] (logits).
        var s = shape
        var strides = array.strides.map { $0.intValue }
        while s.count > 2, s.first == 1 {
            s.removeFirst()
            strides.removeFirst()
        }

        let H: Int, W: Int
        let isLogits: Bool
        let C: Int
        let cStride: Int, yStride: Int, xStride: Int

        if s.count == 2 {
            // Argmax-baked: [H, W]
            isLogits = false
            H = s[0]; W = s[1]
            yStride = strides[0]; xStride = strides[1]
            C = 0; cStride = 0
        } else if s.count == 3, s[0] >= 15 {
            // Raw logits: [C, H, W]
            isLogits = true
            C = s[0]; H = s[1]; W = s[2]
            cStride = strides[0]; yStride = strides[1]; xStride = strides[2]
        } else if s.count == 3 {
            // 3D but first dim is small — assume a singleton class dim and treat as [_, H, W]
            isLogits = false
            H = s[1]; W = s[2]
            yStride = strides[1]; xStride = strides[2]
            C = 0; cStride = 0
        } else {
            return nil
        }

        // Allocate a 4-channel BGRA buffer. Replicate the mask value into all four channels so any CI
        // operation that reads alpha OR luminance gets the same value — robust regardless of how
        // CIBlendWithMask interprets the mask on a given iOS version.
        var bgra = [UInt8](repeating: 0, count: H * W * 4)

        // Per-supported-data-type pixel reader. Argmax-baked path: read class index, compare.
        // Logits path: walk the C channels, find max, compare.
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            buildMask(ptr: ptr, isLogits: isLogits, C: C, H: H, W: W,
                      cStride: cStride, yStride: yStride, xStride: xStride,
                      bgra: &bgra) { $0 }
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
            buildMask(ptr: ptr, isLogits: isLogits, C: C, H: H, W: W,
                      cStride: cStride, yStride: yStride, xStride: xStride,
                      bgra: &bgra) { Float32(Float16(bitPattern: $0)) }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            buildMask(ptr: ptr, isLogits: isLogits, C: C, H: H, W: W,
                      cStride: cStride, yStride: yStride, xStride: xStride,
                      bgra: &bgra) { Float32($0) }
        case .int32:
            let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            buildMask(ptr: ptr, isLogits: isLogits, C: C, H: H, W: W,
                      cStride: cStride, yStride: yStride, xStride: xStride,
                      bgra: &bgra) { Float32($0) }
        default:
            return nil
        }

        // CRITICAL: wrap bytes in Data so CIImage owns the storage. The previous version passed a Swift
        // Array's internal pointer to CGContext, which goes out of scope when the function returns —
        // the resulting CIImage was reading freed memory, causing the IOSurface allocation flood and
        // undefined-behavior visual artifacts. Data is retained by CIImage's bitmapData init.
        let data = Data(bgra)
        return CIImage(
            bitmapData: data,
            bytesPerRow: W * 4,
            size: CGSize(width: W, height: H),
            format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    @inline(__always)
    private func buildMask<T>(
        ptr: UnsafePointer<T>,
        isLogits: Bool,
        C: Int, H: Int, W: Int,
        cStride: Int, yStride: Int, xStride: Int,
        bgra: inout [UInt8],
        toFloat: (T) -> Float32
    ) {
        if !isLogits {
            // Output is already class indices.
            for y in 0..<H {
                let rowBase = y * yStride
                for x in 0..<W {
                    let cls = Int(toFloat(ptr[rowBase + x * xStride]))
                    if Self.skinClasses.contains(cls) {
                        let off = (y * W + x) * 4
                        bgra[off + 0] = 255
                        bgra[off + 1] = 255
                        bgra[off + 2] = 255
                        bgra[off + 3] = 255
                    }
                }
            }
        } else {
            // Walk C channels, take argmax.
            for y in 0..<H {
                for x in 0..<W {
                    let base = y * yStride + x * xStride
                    var maxIdx = 0
                    var maxVal = toFloat(ptr[base])
                    for c in 1..<C {
                        let v = toFloat(ptr[c * cStride + base])
                        if v > maxVal { maxVal = v; maxIdx = c }
                    }
                    if Self.skinClasses.contains(maxIdx) {
                        let off = (y * W + x) * 4
                        bgra[off + 0] = 255
                        bgra[off + 1] = 255
                        bgra[off + 2] = 255
                        bgra[off + 3] = 255
                    }
                }
            }
        }
    }
}
