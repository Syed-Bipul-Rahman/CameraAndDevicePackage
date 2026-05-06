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
    // Locked to slider value 100 in the old UI (formula: 0.5 + value/100). Contrast slider was removed
    // from the panel; keep the default at 1.5 so every frame ships with the punchy look.
    var contrast: Float = 1.5
    var saturation: Float = 1.0

    var lipPlumpEnabled: Bool = false
    var lipPlumpIntensity: Float = 0.0

    var milkySkinEnabled: Bool = false
    var milkySkinIntensity: Float = 0.0

    var backgroundBlurEnabled: Bool = false
    var backgroundBlurIntensity: Float = 0.0

    var detectedFaces: [DetectedFace] = []

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
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            personSegmentationRequest = request
        }
    }

    func processImage(_ inputImage: CIImage) -> CIImage {
        var outputImage = inputImage

        if backgroundBlurEnabled && backgroundBlurIntensity > 0 {
            outputImage = applyBackgroundBlur(to: outputImage)
        }

        if faceOnlySmoothEnabled && !detectedFaces.isEmpty {
            outputImage = applyFaceOnlySmooth(to: outputImage)
        } else if smoothSkinEnabled {
            outputImage = applySmoothSkin(to: outputImage)
        }

        if milkySkinEnabled && milkySkinIntensity > 0 {
            outputImage = applyMilkySkin(to: outputImage)
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

    private func applyMilkySkin(to image: CIImage) -> CIImage {
        let imageExtent = image.extent
        let intensity = Double(milkySkinIntensity) * 0.5

        let downscale: CGFloat = 0.5
        let downTransform = CGAffineTransform(scaleX: downscale, y: downscale)
        let upTransform   = CGAffineTransform(scaleX: 1.0 / downscale, y: 1.0 / downscale)

        var milkyImage = image.transformed(by: downTransform)
        let workingExtent = milkyImage.extent

        if let blurFilter = CIFilter(name: "CIGaussianBlur"),
           let dissolve  = CIFilter(name: "CIDissolveTransition") {
            blurFilter.setValue(milkyImage, forKey: kCIInputImageKey)
            blurFilter.setValue((2.0 + intensity * 4.0) * downscale, forKey: kCIInputRadiusKey)
            if let blurred = blurFilter.outputImage?.cropped(to: workingExtent) {
                dissolve.setValue(milkyImage, forKey: kCIInputImageKey)
                dissolve.setValue(blurred, forKey: kCIInputTargetImageKey)
                dissolve.setValue(intensity * 0.5, forKey: kCIInputTimeKey)
                if let result = dissolve.outputImage?.cropped(to: workingExtent) { milkyImage = result }
            }
        }

        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(milkyImage, forKey: kCIInputImageKey)
            colorFilter.setValue(intensity * 0.12, forKey: kCIInputBrightnessKey)
            colorFilter.setValue(1.0 - intensity * 0.30, forKey: kCIInputSaturationKey)
            colorFilter.setValue(1.0 - intensity * 0.10, forKey: kCIInputContrastKey)
            if let result = colorFilter.outputImage?.cropped(to: workingExtent) { milkyImage = result }
        }

        milkyImage = milkyImage.transformed(by: upTransform).cropped(to: imageExtent)

        if !detectedFaces.isEmpty {
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

    private func createMilkyFaceMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
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

    private func applyLipPlump(to image: CIImage) -> CIImage {
        guard !detectedFaces.isEmpty else { return image }
        var warped = image
        let imageExtent = image.extent

        // 1) Apply bump distortion at jaw points with a much tighter radius so the warp stays inside the face.
        for face in detectedFaces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )

            // Slightly above the chin, pulled inward from the silhouette edge.
            let jawY = faceRect.origin.y + faceRect.height * 0.18
            let leftJawX  = faceRect.origin.x + faceRect.width * 0.26
            let rightJawX = faceRect.origin.x + faceRect.width * 0.74

            // Radius capped at ~22% of face width — well inside the face cheek region.
            let radius = faceRect.width * 0.22
            let intensity = Double(lipPlumpIntensity)
            // Symmetric, gentler distortion so realism holds at full slider extent.
            let scale = intensity > 0 ? -intensity * 0.10 : -intensity * 0.14

            for centerX in [leftJawX, rightJawX] {
                guard let bump = CIFilter(name: "CIBumpDistortion") else { continue }
                bump.setValue(warped, forKey: kCIInputImageKey)
                bump.setValue(CIVector(x: centerX, y: jawY), forKey: kCIInputCenterKey)
                bump.setValue(radius, forKey: kCIInputRadiusKey)
                bump.setValue(scale, forKey: kCIInputScaleKey)
                if let result = bump.outputImage?.cropped(to: imageExtent) { warped = result }
            }
        }

        // 2) Mask the warp to the lower face only — anything outside the mask uses the untouched original,
        //    so background and shoulders never bend even if a stray bump radius reached them.
        let mask = createPlumpMask(for: detectedFaces, imageExtent: imageExtent)
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return warped }
        blend.setValue(warped, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage?.cropped(to: imageExtent) ?? warped
    }

    /// Soft elliptical mask covering the lower 60% of each face — the jaw + lower cheeks zone.
    /// Inset from the bounding box by ~10% so the mask stays strictly inside the face silhouette,
    /// with a soft falloff so the transition between warped and original is invisible.
    private func createPlumpMask(for faces: [DetectedFace], imageExtent: CGRect) -> CIImage {
        var combined: CIImage?
        for face in faces {
            let faceRect = CGRect(
                x: face.boundingBox.origin.x * imageExtent.width + imageExtent.origin.x,
                y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * imageExtent.height + imageExtent.origin.y,
                width: face.boundingBox.width * imageExtent.width,
                height: face.boundingBox.height * imageExtent.height
            )

            let insetX = faceRect.width * 0.10
            let lowerHeight = faceRect.height * 0.60
            // CIImage uses Y-up: faceRect.origin.y is the face bottom, so anchor the mask there.
            let maskRect = CGRect(
                x: faceRect.origin.x + insetX,
                y: faceRect.origin.y,
                width: faceRect.width - insetX * 2,
                height: lowerHeight
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

    private func applyBackgroundBlur(to image: CIImage) -> CIImage {
        guard #available(iOS 15.0, *),
              let request = personSegmentationRequest as? VNGeneratePersonSegmentationRequest else {
            return image
        }

        let imageExtent = image.extent
        segmentationFrameCounter += 1
        let imageSizeChanged = abs(imageExtent.width  - cachedMaskSourceSize.width)  > 100
                            || abs(imageExtent.height - cachedMaskSourceSize.height) > 100

        if segmentationFrameCounter % 8 == 0 || cachedPersonMask == nil || imageSizeChanged {
            guard let cgImage = context.createCGImage(image, from: imageExtent) else { return image }
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
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
        guard let blurredImage = blurFilter.outputImage?.cropped(to: imageExtent) else { return image }

        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return image }
        blendFilter.setValue(image, forKey: kCIInputImageKey)
        blendFilter.setValue(blurredImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(personMask, forKey: kCIInputMaskImageKey)
        return blendFilter.outputImage?.cropped(to: imageExtent) ?? image
    }

    private func applyFaceOnlySmooth(to image: CIImage) -> CIImage {
        guard !detectedFaces.isEmpty else { return image }
        if let processor = skinSmoothingProcessor {
            processor.sigmaSpace = 5.0 + faceSmoothIntensity * 5.0
            processor.sigmaColor = 0.05 + (1.0 - faceSmoothIntensity) * 0.1
            return processor.processImage(image, faces: detectedFaces, intensity: faceSmoothIntensity)
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
