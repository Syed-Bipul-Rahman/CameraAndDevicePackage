import Foundation
import CoreImage
import UIKit
import Vision
import Metal

struct DetectedFace {
    let boundingBox: CGRect  // Normalized 0-1, Y-down (screen) coordinates
    let landmarks: [String: CGPoint]?
    let confidence: Float
    let leftEyeRegion: CGRect?
    let rightEyeRegion: CGRect?
    let noseRegion: CGRect?
    let mouthRegion: CGRect?

    // Full landmark polygons in image-normalized Y-down coordinates. Used to build a precise skin mask
    // (face contour minus eyes/lips/brows/nostrils) instead of the bounding-box ellipse.
    let faceContour: [CGPoint]?
    let leftEye: [CGPoint]?
    let rightEye: [CGPoint]?
    let outerLips: [CGPoint]?
    let leftEyebrow: [CGPoint]?
    let rightEyebrow: [CGPoint]?
    let nose: [CGPoint]?

    func expandedBoundingBox(by percentage: CGFloat) -> CGRect {
        let expandX = boundingBox.width * percentage
        let expandY = boundingBox.height * percentage
        return CGRect(
            x: boundingBox.origin.x - expandX / 2,
            y: boundingBox.origin.y - expandY / 2,
            width: boundingBox.width + expandX,
            height: boundingBox.height + expandY
        )
    }
}

class FaceDetectionService {
    private var lastDetectedFaces: [DetectedFace] = []
    private var frameCount: Int = 0
    // Run detection every 2 frames (~15x/sec at 30fps). At Vision-downsample resolution (480 px) this is
    // ~5-10 ms per frame on A14+, well within the 33 ms frame budget — and tight enough that the mask
    // catches up to the face within ~65 ms, below visual perception of lag.
    private let detectionInterval: Int = 2
    private var isDetecting: Bool = false
    private let detectionQueue = DispatchQueue(label: "com.supernova.facedetection", qos: .userInitiated)
    // Very light smoothing — at 15 Hz detection, a low factor keeps the mask close to the face while
    // still removing single-frame jitter. Higher values cause visible "milky region trails the face".
    private let smoothingFactor: CGFloat = 0.15

    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    var lastFaces: [DetectedFace] { lastDetectedFaces }

    func detectFaces(in image: CIImage, imageSize: CGSize, completion: @escaping ([DetectedFace]) -> Void) {
        frameCount += 1
        if frameCount % detectionInterval != 0 {
            completion(lastDetectedFaces)
            return
        }
        guard !isDetecting else {
            completion(lastDetectedFaces)
            return
        }
        isDetecting = true

        detectionQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            // Downsample — Vision doesn't need full resolution
            let longestSide: CGFloat = 480
            let scale = longestSide / max(imageSize.width, imageSize.height)
            let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            // Rotate to portrait if the buffer arrived in landscape
            let finalImage: CIImage
            let isRotated: Bool
            if scaledImage.extent.width > scaledImage.extent.height {
                finalImage = scaledImage.oriented(.right)
                isRotated = true
            } else {
                finalImage = scaledImage
                isRotated = false
            }

            guard let cgImage = self.ciContext.createCGImage(finalImage, from: finalImage.extent) else {
                self.isDetecting = false
                DispatchQueue.main.async { completion(self.lastDetectedFaces) }
                return
            }

            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                self.isDetecting = false
                DispatchQueue.main.async { completion(self.lastDetectedFaces) }
                return
            }

            self.isDetecting = false

            let observations = request.results ?? []
            var detectedFaces: [DetectedFace] = []

            for observation in observations {
                // Vision uses Y-up (bottom-left origin). Convert to Y-down (top-left / screen).
                var visionBox = observation.boundingBox
                var screenBox = CGRect(
                    x: visionBox.origin.x,
                    y: 1.0 - visionBox.origin.y - visionBox.height,
                    width: visionBox.width,
                    height: visionBox.height
                )

                // Un-rotate bounding box if we rotated the image for detection.
                // .right rotation maps: portrait_x = landscape_y, portrait_y = 1 - landscape_x - landscape_w
                if isRotated {
                    screenBox = CGRect(
                        x: screenBox.origin.y,
                        y: 1.0 - screenBox.origin.x - screenBox.width,
                        width: screenBox.height,
                        height: screenBox.width
                    )
                }

                // Estimate feature regions proportionally from the face bounding box
                let (leftEye, rightEye, nose, mouth) = self.estimateFeatureRegions(from: screenBox)

                // Extract landmark screen positions for face-detection overlays
                var landmarks: [String: CGPoint] = [:]
                var contourPoints: [CGPoint]?
                var leftEyePoints: [CGPoint]?
                var rightEyePoints: [CGPoint]?
                var outerLipPoints: [CGPoint]?
                var leftBrowPoints: [CGPoint]?
                var rightBrowPoints: [CGPoint]?
                var nosePoints: [CGPoint]?

                if let faceLandmarks = observation.landmarks {
                    if let leftEyeLM = faceLandmarks.leftEye {
                        landmarks["leftEye"] = self.landmarkCenter(leftEyeLM, in: visionBox, isRotated: isRotated)
                        leftEyePoints = self.landmarkPoints(leftEyeLM, in: visionBox, isRotated: isRotated)
                    }
                    if let rightEyeLM = faceLandmarks.rightEye {
                        landmarks["rightEye"] = self.landmarkCenter(rightEyeLM, in: visionBox, isRotated: isRotated)
                        rightEyePoints = self.landmarkPoints(rightEyeLM, in: visionBox, isRotated: isRotated)
                    }
                    if let noseLM = faceLandmarks.nose {
                        landmarks["noseBase"] = self.landmarkCenter(noseLM, in: visionBox, isRotated: isRotated)
                        nosePoints = self.landmarkPoints(noseLM, in: visionBox, isRotated: isRotated)
                    }
                    if let mouthLM = faceLandmarks.outerLips {
                        landmarks["mouthLeft"]   = self.landmarkCenter(mouthLM, in: visionBox, isRotated: isRotated)
                        landmarks["mouthRight"]  = self.landmarkCenter(mouthLM, in: visionBox, isRotated: isRotated)
                        landmarks["mouthBottom"] = self.landmarkCenter(mouthLM, in: visionBox, isRotated: isRotated)
                        outerLipPoints = self.landmarkPoints(mouthLM, in: visionBox, isRotated: isRotated)
                    }
                    if let contourLM = faceLandmarks.faceContour {
                        contourPoints = self.landmarkPoints(contourLM, in: visionBox, isRotated: isRotated)
                    }
                    if let lbLM = faceLandmarks.leftEyebrow {
                        leftBrowPoints = self.landmarkPoints(lbLM, in: visionBox, isRotated: isRotated)
                    }
                    if let rbLM = faceLandmarks.rightEyebrow {
                        rightBrowPoints = self.landmarkPoints(rbLM, in: visionBox, isRotated: isRotated)
                    }
                }

                detectedFaces.append(DetectedFace(
                    boundingBox: screenBox,
                    landmarks: landmarks.isEmpty ? nil : landmarks,
                    confidence: observation.confidence,
                    leftEyeRegion: leftEye,
                    rightEyeRegion: rightEye,
                    noseRegion: nose,
                    mouthRegion: mouth,
                    faceContour: contourPoints,
                    leftEye: leftEyePoints,
                    rightEye: rightEyePoints,
                    outerLips: outerLipPoints,
                    leftEyebrow: leftBrowPoints,
                    rightEyebrow: rightBrowPoints,
                    nose: nosePoints
                ))
            }

            let smoothed = self.smoothFaces(detectedFaces)
            self.lastDetectedFaces = smoothed
            DispatchQueue.main.async { completion(smoothed) }
        }
    }

    // MARK: - Helpers

    /// Estimate eye/nose/mouth regions proportionally from the face bounding box.
    private func estimateFeatureRegions(from box: CGRect) -> (leftEye: CGRect, rightEye: CGRect, nose: CGRect, mouth: CGRect) {
        let w = box.width, h = box.height
        let eyeW = w * 0.28, eyeH = h * 0.15
        let leftEye  = CGRect(x: box.minX + w * 0.18, y: box.minY + h * 0.28, width: eyeW, height: eyeH)
        let rightEye = CGRect(x: box.minX + w * 0.54, y: box.minY + h * 0.28, width: eyeW, height: eyeH)
        let noseW = w * 0.25, noseH = h * 0.25
        let nose = CGRect(x: box.minX + (w - noseW) / 2, y: box.minY + h * 0.42, width: noseW, height: noseH)
        let mouthW = w * 0.45, mouthH = h * 0.18
        let mouth = CGRect(x: box.minX + (w - mouthW) / 2, y: box.minY + h * 0.68, width: mouthW, height: mouthH)
        return (leftEye, rightEye, nose, mouth)
    }

    /// Convert a Vision landmark's center from face-relative normalized coords to image-normalized Y-down coords.
    /// Vision uses Y-up everywhere — both the bounding box AND the per-feature normalized points. Convert to
    /// image-Y-up first, then flip once to screen-Y-down.
    private func landmarkCenter(_ landmark: VNFaceLandmarkRegion2D, in faceBox: CGRect, isRotated: Bool) -> CGPoint {
        guard !landmark.normalizedPoints.isEmpty else { return .zero }
        let avg = landmark.normalizedPoints.reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let n = CGFloat(landmark.normalizedPoints.count)
        let visionX = faceBox.origin.x + (avg.x / n) * faceBox.width
        let visionY = faceBox.origin.y + (avg.y / n) * faceBox.height  // image Y-up
        var pt = CGPoint(x: visionX, y: 1.0 - visionY)                  // → screen Y-down
        if isRotated { pt = CGPoint(x: pt.y, y: 1.0 - pt.x) }
        return pt
    }

    /// Convert all of a Vision landmark's points to image-normalized Y-down coordinates (matching face.boundingBox).
    private func landmarkPoints(_ landmark: VNFaceLandmarkRegion2D, in faceBox: CGRect, isRotated: Bool) -> [CGPoint] {
        landmark.normalizedPoints.map { p in
            let visionX = faceBox.origin.x + p.x * faceBox.width
            let visionY = faceBox.origin.y + p.y * faceBox.height       // image Y-up
            var pt = CGPoint(x: visionX, y: 1.0 - visionY)               // → screen Y-down
            if isRotated { pt = CGPoint(x: pt.y, y: 1.0 - pt.x) }
            return pt
        }
    }

    // MARK: - Smoothing (identical to original)

    private func smoothFaces(_ newFaces: [DetectedFace]) -> [DetectedFace] {
        guard !lastDetectedFaces.isEmpty else { return newFaces }
        return newFaces.map { newFace in
            guard let matching = findClosestFace(to: newFace, in: lastDetectedFaces) else { return newFace }
            let f = smoothingFactor
            let smoothedBox = CGRect(
                x: matching.boundingBox.origin.x * f + newFace.boundingBox.origin.x * (1 - f),
                y: matching.boundingBox.origin.y * f + newFace.boundingBox.origin.y * (1 - f),
                width: matching.boundingBox.width * f + newFace.boundingBox.width * (1 - f),
                height: matching.boundingBox.height * f + newFace.boundingBox.height * (1 - f)
            )
            return DetectedFace(
                boundingBox: smoothedBox,
                landmarks: newFace.landmarks,
                confidence: newFace.confidence,
                leftEyeRegion: smoothRect(matching.leftEyeRegion, newFace.leftEyeRegion),
                rightEyeRegion: smoothRect(matching.rightEyeRegion, newFace.rightEyeRegion),
                noseRegion: smoothRect(matching.noseRegion, newFace.noseRegion),
                mouthRegion: smoothRect(matching.mouthRegion, newFace.mouthRegion),
                faceContour: smoothPoints(matching.faceContour, newFace.faceContour),
                leftEye:     smoothPoints(matching.leftEye,     newFace.leftEye),
                rightEye:    smoothPoints(matching.rightEye,    newFace.rightEye),
                outerLips:   smoothPoints(matching.outerLips,   newFace.outerLips),
                leftEyebrow: smoothPoints(matching.leftEyebrow, newFace.leftEyebrow),
                rightEyebrow:smoothPoints(matching.rightEyebrow,newFace.rightEyebrow),
                nose:        smoothPoints(matching.nose,        newFace.nose)
            )
        }
    }

    /// Per-point exponential smoothing to remove jitter between detection cycles. Falls back to the
    /// new polygon when the count changes (Vision occasionally returns a different number of points).
    private func smoothPoints(_ old: [CGPoint]?, _ new: [CGPoint]?) -> [CGPoint]? {
        guard let new = new else { return nil }
        guard let old = old, old.count == new.count else { return new }
        let f = smoothingFactor
        return zip(old, new).map { o, n in
            CGPoint(x: o.x * f + n.x * (1 - f), y: o.y * f + n.y * (1 - f))
        }
    }

    private func smoothRect(_ oldRect: CGRect?, _ newRect: CGRect?) -> CGRect? {
        guard let newRect = newRect else { return nil }
        guard let oldRect = oldRect else { return newRect }
        let f = smoothingFactor
        return CGRect(
            x: oldRect.origin.x * f + newRect.origin.x * (1 - f),
            y: oldRect.origin.y * f + newRect.origin.y * (1 - f),
            width: oldRect.width * f + newRect.width * (1 - f),
            height: oldRect.height * f + newRect.height * (1 - f)
        )
    }

    private func findClosestFace(to face: DetectedFace, in faces: [DetectedFace]) -> DetectedFace? {
        let faceCenter = CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY)
        var closest: DetectedFace?
        var closestDist: CGFloat = .greatestFiniteMagnitude
        for existing in faces {
            let c = CGPoint(x: existing.boundingBox.midX, y: existing.boundingBox.midY)
            let d = hypot(faceCenter.x - c.x, faceCenter.y - c.y)
            if d < closestDist && d < 0.3 { closestDist = d; closest = existing }
        }
        return closest
    }
}
