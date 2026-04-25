import Foundation
import Metal
import MetalKit
import CoreImage

class SkinSmoothingProcessor {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bilateralPipeline: MTLComputePipelineState
    private let maskPipeline: MTLComputePipelineState
    private let ciContext: CIContext

    private var cachedMaskTexture: MTLTexture?
    private var cachedOutputTexture: MTLTexture?
    private var lastTextureSize: CGSize = .zero

    var intensity: Float = 0.7
    var sigmaSpace: Float = 7.0
    var sigmaColor: Float = 0.08

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device)

        // Load shader library from the module bundle (Swift Package Manager compatible)
        let library: MTLLibrary?
        if let bundleLib = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = bundleLib
        } else {
            library = device.makeDefaultLibrary()
        }

        guard let library = library else { return nil }

        guard let bilateralFunc = library.makeFunction(name: "bilateralSkinSmooth"),
              let maskFunc = library.makeFunction(name: "createFaceMaskTexture") else { return nil }

        do {
            bilateralPipeline = try device.makeComputePipelineState(function: bilateralFunc)
            maskPipeline = try device.makeComputePipelineState(function: maskFunc)
        } catch { return nil }
    }

    func processImage(_ image: CIImage, faces: [DetectedFace], intensity: Float) -> CIImage {
        guard !faces.isEmpty else { return image }

        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)

        let inputTexture = createTexture(from: image, width: width, height: height)
        let outputTexture = getOrCreateOutputTexture(width: width, height: height)
        let maskTexture = getOrCreateMaskTexture(width: width, height: height)

        guard let input = inputTexture, let output = outputTexture, let mask = maskTexture else {
            return image
        }

        createFaceMask(faces: faces, maskTexture: mask, width: width, height: height)
        applyBilateralFilter(input: input, output: output, mask: mask, intensity: intensity, width: width, height: height)

        return ciImageFromTexture(output, extent: extent) ?? image
    }

    private func createTexture(from image: CIImage, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        ciContext.render(image, to: texture, commandBuffer: nil, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return texture
    }

    private func getOrCreateOutputTexture(width: Int, height: Int) -> MTLTexture? {
        let size = CGSize(width: width, height: height)
        if lastTextureSize == size, let cached = cachedOutputTexture { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        cachedOutputTexture = device.makeTexture(descriptor: descriptor)
        lastTextureSize = size
        return cachedOutputTexture
    }

    private func getOrCreateMaskTexture(width: Int, height: Int) -> MTLTexture? {
        let size = CGSize(width: width, height: height)
        if lastTextureSize == size, let cached = cachedMaskTexture { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        cachedMaskTexture = device.makeTexture(descriptor: descriptor)
        return cachedMaskTexture
    }

    private func createFaceMask(faces: [DetectedFace], maskTexture: MTLTexture, width: Int, height: Int) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(maskPipeline)
        encoder.setTexture(maskTexture, index: 0)

        var faceRects: [SIMD4<Float>] = []
        var excludeRects: [SIMD4<Float>] = []

        for face in faces {
            let expanded = face.expandedBoundingBox(by: 0.15)
            faceRects.append(SIMD4<Float>(Float(expanded.origin.x), Float(expanded.origin.y),
                                          Float(expanded.width), Float(expanded.height)))

            if let leftEye = face.leftEyeRegion {
                let e = expandRect(leftEye, by: 1.5)
                excludeRects.append(SIMD4<Float>(Float(e.origin.x), Float(e.origin.y), Float(e.width), Float(e.height)))
            }
            if let rightEye = face.rightEyeRegion {
                let e = expandRect(rightEye, by: 1.5)
                excludeRects.append(SIMD4<Float>(Float(e.origin.x), Float(e.origin.y), Float(e.width), Float(e.height)))
            }
            if let nose = face.noseRegion {
                let e = expandRect(nose, by: 1.3)
                excludeRects.append(SIMD4<Float>(Float(e.origin.x), Float(e.origin.y), Float(e.width), Float(e.height)))
            }
            if let mouth = face.mouthRegion {
                let e = expandRect(mouth, by: 1.4)
                excludeRects.append(SIMD4<Float>(Float(e.origin.x), Float(e.origin.y), Float(e.width), Float(e.height)))
            }
            if let leftEye = face.leftEyeRegion {
                let eyebrow = expandRect(CGRect(x: leftEye.origin.x - leftEye.width*0.15, y: leftEye.origin.y - leftEye.height*2.0,
                                                width: leftEye.width*1.3, height: leftEye.height*0.8), by: 1.0)
                excludeRects.append(SIMD4<Float>(Float(eyebrow.origin.x), Float(eyebrow.origin.y), Float(eyebrow.width), Float(eyebrow.height)))
            }
            if let rightEye = face.rightEyeRegion {
                let eyebrow = expandRect(CGRect(x: rightEye.origin.x - rightEye.width*0.15, y: rightEye.origin.y - rightEye.height*2.0,
                                                width: rightEye.width*1.3, height: rightEye.height*0.8), by: 1.0)
                excludeRects.append(SIMD4<Float>(Float(eyebrow.origin.x), Float(eyebrow.origin.y), Float(eyebrow.width), Float(eyebrow.height)))
            }
        }

        var faceCount = Int32(faceRects.count)
        var excludeCount = Int32(excludeRects.count)

        let faceBuffer = device.makeBuffer(bytes: &faceRects,
                                           length: max(MemoryLayout<SIMD4<Float>>.stride * faceRects.count, 16),
                                           options: .storageModeShared)
        let excludeBuffer = device.makeBuffer(bytes: &excludeRects,
                                              length: max(MemoryLayout<SIMD4<Float>>.stride * excludeRects.count, 16),
                                              options: .storageModeShared)

        encoder.setBuffer(faceBuffer, offset: 0, index: 0)
        encoder.setBytes(&faceCount, length: MemoryLayout<Int32>.size, index: 1)
        encoder.setBuffer(excludeBuffer, offset: 0, index: 2)
        encoder.setBytes(&excludeCount, length: MemoryLayout<Int32>.size, index: 3)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func applyBilateralFilter(input: MTLTexture, output: MTLTexture, mask: MTLTexture,
                                      intensity: Float, width: Int, height: Int) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(bilateralPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(mask, index: 2)

        var intensityValue = intensity
        var sigmaSpaceValue = sigmaSpace
        var sigmaColorValue = sigmaColor

        encoder.setBytes(&intensityValue, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&sigmaSpaceValue, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&sigmaColorValue, length: MemoryLayout<Float>.size, index: 2)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func ciImageFromTexture(_ texture: MTLTexture, extent: CGRect) -> CIImage? {
        return CIImage(mtlTexture: texture, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()])
    }

    private func expandRect(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let expandX = rect.width  * (factor - 1) / 2
        let expandY = rect.height * (factor - 1) / 2
        return rect.insetBy(dx: -expandX, dy: -expandY)
    }
}
