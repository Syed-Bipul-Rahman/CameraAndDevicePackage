import UIKit
import AVFoundation
import Metal
import MetalKit
import Photos
import ImageIO
import Vision

public class BeautyCameraView: UIView, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Public API

    public weak var delegate: BeautyCameraViewDelegate?
    public var faceTrackingEnabled: Bool = true

    // MARK: - Private properties

    private var metalView: MTKView?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let filterProcessor = BeautyFilterProcessor()
    private let sessionQueue = DispatchQueue(label: "com.supernova.camera.session")
    private let renderQueue = DispatchQueue(label: "com.supernova.camera.render")
    private let audioQueue = DispatchQueue(label: "com.supernova.camera.audio")
    // Dedicated queue for photo decode / filter / encode / save so heavy capture work doesn't sit on
    // the session queue (which would block startRunning/setFocus/etc) or the render queue (live frames).
    private let photoProcessingQueue = DispatchQueue(label: "com.supernova.camera.photo", qos: .userInitiated)

    /// Dedicated CIContext for the photo pipeline. The live `ciContext` uses sRGB/deviceRGB as its
    /// working color space (cheap for video frames). Routing photos through it forces a sRGB ↔ P3
    /// gamut round-trip that clips highlights and dulls saturation. This context works in displayP3
    /// natively so a P3-tagged HEIC stays in P3 the whole way through.
    private lazy var photoCIContext: CIContext = {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: p3,
            .outputColorSpace: p3,
            .highQualityDownsample: true,
            .cacheIntermediates: true
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: opts)
        }
        return CIContext(options: opts)
    }()

    private var metalDevice: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var currentCIImage: CIImage?
    private var lastCapturedImage: CIImage?

    private let imageLock = NSLock()
    private var isCleanedUp = false

    // GPU back-pressure: caps in-flight command buffers on the GPU to prevent main-thread stalls.
    private let inFlightSemaphore = DispatchSemaphore(value: 2)

    private var pendingFrameForDisplay: Bool = false
    private let pendingFrameLock = NSLock()

    private var lastDrawableSize: CGSize = .zero
    private var currentCameraPosition: AVCaptureDevice.Position = .back

    // Blur overlays
    private var blurViews: [String: UIView] = [:]
    private var pendingBlurFrames: [String: CGRect] = [:]
    private var pendingBlurCornerRadius: [String: CGFloat] = [:]
    private var blurFlushScheduled = false
    private var lastAppliedBlurFrames: [String: CGRect] = [:]

    private let faceDetectionService = FaceDetectionService()
    private let faceParsingService = FaceParsingService()
    private var lastImageSize: CGSize = .zero

    /// Heavily-smoothed bounding box for the on-screen overlay. The detection-side smoothing factor is
    /// kept light (0.15) so the *mask* tracks the face responsively, but the visible overlay rectangle
    /// would jitter at that smoothing level — we apply a much heavier EMA here just for the visual.
    private var displayOverlayBBox: CGRect?

    private var photoOutput: AVCapturePhotoOutput?
    private var photoCaptureCompletion: ((Result<String, Error>) -> Void)?

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isRecordingInternal = false
    private var recordingStartTime: CMTime?
    private var currentVideoURL: URL?
    private var videoOutputWidth: Int = 1280
    private var videoOutputHeight: Int = 720
    private let recordingLock = NSLock()

    private var currentFlashMode: AVCaptureDevice.FlashMode = .off
    private var currentAspectRatioString: String = "4:3"

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        setupMetal()
        configureAudioSession()
        registerSessionObservers()
        sessionQueue.async { [weak self] in
            self?.setupCamera()
        }
    }

    /// Configure the shared AVAudioSession so AVFoundation can mix our mic capture cleanly with system audio.
    /// Without this, real devices produce FigAudioSession err=-19224 and the capture session can wedge.
    private func configureAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord,
                                  mode: .videoRecording,
                                  options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try audio.setActive(true, options: [])
        } catch {
            // Non-fatal — capture still works, but routing may be suboptimal.
        }
    }

    /// Recover from interruptions (incoming call, Control Center, screen lock, audio route change)
    /// and from runtime errors. Without these, the preview freezes after the first interruption.
    private func registerSessionObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError, object: nil)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: nil)
        nc.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        // Most runtime errors are recoverable by simply restarting the session on its queue.
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: - Public Methods

    public func setFilter(_ settings: FilterSettings) {
        filterProcessor.smoothSkinEnabled = settings.smoothSkin
        filterProcessor.warmToneEnabled = settings.warmTone
        filterProcessor.smoothIntensity = settings.smoothIntensity
        filterProcessor.warmthIntensity = settings.warmthIntensity
        filterProcessor.faceOnlySmoothEnabled = settings.faceOnlySmooth
        filterProcessor.faceSmoothIntensity = settings.faceSmoothIntensity
        filterProcessor.faceColorTintEnabled = settings.faceColorTintEnabled
        filterProcessor.faceColorTintRed = settings.faceColorTintRed
        filterProcessor.faceColorTintGreen = settings.faceColorTintGreen
        filterProcessor.faceColorTintBlue = settings.faceColorTintBlue
        filterProcessor.faceColorTintIntensity = settings.faceColorTintIntensity
        filterProcessor.brightness = settings.brightness
        filterProcessor.contrast = settings.contrast
        filterProcessor.saturation = settings.saturation
        filterProcessor.lipPlumpEnabled = settings.lipPlump
        filterProcessor.lipPlumpIntensity = settings.lipPlumpIntensity
        filterProcessor.milkySkinEnabled = settings.milkySkin
        filterProcessor.milkySkinIntensity = settings.milkySkinIntensity
        filterProcessor.backgroundBlurEnabled = settings.backgroundBlur
        filterProcessor.backgroundBlurIntensity = settings.backgroundBlurIntensity
    }

    public func capturePhoto(completion: @escaping (Result<String, Error>) -> Void) {
        // Capture the preview's current aspect ratio on the main thread; the photo will be cropped
        // to this so the saved image matches what the user sees in live preview.
        if Thread.isMainThread {
            pendingPreviewAspect = previewAspectRatio()
        } else {
            DispatchQueue.main.sync { self.pendingPreviewAspect = self.previewAspectRatio() }
        }
        capturePhotoInternal(completion: completion)
    }

    private var pendingPreviewAspect: CGFloat = 0

    private func previewAspectRatio() -> CGFloat {
        // The MTKView's frame is the *visible* preview rect — it shrinks to a centered square for 1:1
        // and to a 16:9 strip when the user picks those ratios. Read from there, not the outer view
        // bounds, otherwise the saved photo/video gets cropped to the full screen aspect instead of
        // the ratio the user actually picked.
        if let mv = metalView, mv.frame.width > 0, mv.frame.height > 0 {
            return mv.frame.width / mv.frame.height
        }
        let b = bounds
        guard b.width > 0, b.height > 0 else { return 0 }
        return b.width / b.height
    }

    /// Post-capture polish — denoise + subtle luminance sharpen for the "pop" look. Cheap relative to
    /// the encode itself, runs on photoProcessingQueue so the live preview is unaffected.
    private func applyPhotoEnhancements(_ image: CIImage) -> CIImage {
        var img = image
        if let nr = CIFilter(name: "CINoiseReduction") {
            nr.setValue(img, forKey: kCIInputImageKey)
            nr.setValue(0.02, forKey: "inputNoiseLevel")
            nr.setValue(0.40, forKey: "inputSharpness")
            if let out = nr.outputImage?.cropped(to: img.extent) { img = out }
        }
        if let sh = CIFilter(name: "CISharpenLuminance") {
            sh.setValue(img, forKey: kCIInputImageKey)
            sh.setValue(0.40, forKey: kCIInputSharpnessKey)
            if let out = sh.outputImage?.cropped(to: img.extent) { img = out }
        }
        return img
    }

    /// Synchronous Vision face detection on a one-shot CIImage. Used during photo capture to find the
    /// face in the captured photo (not in the live preview). Returns image-normalized Y-DOWN bbox to
    /// match FaceDetectionService's convention so FaceParsingService accepts it directly.
    private func detectFirstFaceBBox(in image: CIImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let face = (request.results as? [VNFaceObservation])?.first else { return nil }
        let v = face.boundingBox  // Y-up
        return CGRect(x: v.origin.x,
                      y: 1.0 - v.origin.y - v.height,
                      width: v.width, height: v.height)
    }

    /// Read the embedded color space from the captured HEIC bytes so we can render into the same gamut
    /// the camera produced. Modern iPhones tag photos as Display P3; older devices may use sRGB.
    private func sourceColorSpace(from data: Data) -> CGColorSpace? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return cg.colorSpace
    }

    /// Mirror an image horizontally — used for front-camera selfies so the saved photo matches
    /// the mirrored live preview (which is mirrored at the videoOutput connection level).
    private func mirrorHorizontally(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width - 2 * extent.origin.x, y: 0)
        return image.transformed(by: transform)
    }

    /// Crops a CIImage to match a target view aspect ratio with a centered crop —
    /// the same crop the preview's aspectFill applies during live rendering.
    private func cropToPreviewAspect(_ image: CIImage, previewAspect: CGFloat) -> CIImage {
        guard previewAspect > 0 else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let imageAspect = extent.width / extent.height
        let crop: CGRect
        if previewAspect > imageAspect {
            // Preview is wider — keep full width, crop top/bottom.
            let newHeight = extent.width / previewAspect
            let yOffset = (extent.height - newHeight) / 2
            crop = CGRect(x: extent.origin.x, y: extent.origin.y + yOffset,
                          width: extent.width, height: newHeight)
        } else {
            // Preview is narrower — keep full height, crop left/right.
            let newWidth = extent.height * previewAspect
            let xOffset = (extent.width - newWidth) / 2
            crop = CGRect(x: extent.origin.x + xOffset, y: extent.origin.y,
                          width: newWidth, height: extent.height)
        }
        // Translate the cropped image back to origin so the resulting extent has origin.zero.
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))
    }

    public func startCamera() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    public func stopCamera() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
        }
    }

    public func switchCamera(completion: @escaping () -> Void = {}) {
        sessionQueue.async { [weak self] in
            self?.switchCameraInternal()
            DispatchQueue.main.async { completion() }
        }
    }

    public func addBlurOverlay(id: String, x: Double, y: Double, width: Double, height: Double,
                               cornerRadius: Double = 0, blurStyle: String = "light") {
        addBlurOverlayInternal(id: id, x: x, y: y, width: width, height: height,
                               cornerRadius: cornerRadius, blurStyle: blurStyle)
    }

    public func updateBlurOverlay(id: String, x: Double, y: Double, width: Double, height: Double,
                                  cornerRadius: Double = 0) {
        updateBlurOverlayInternal(id: id, x: x, y: y, width: width, height: height, cornerRadius: cornerRadius)
    }

    public func removeBlurOverlay(id: String) {
        removeBlurOverlayInternal(id: id)
    }

    public func removeAllBlurOverlays() {
        removeAllBlurOverlaysInternal()
    }

    public func getLatestPhoto(completion: @escaping (String?) -> Void) {
        getLatestPhotoFromLibrary(completion: completion)
    }

    public func startRecording(completion: @escaping (Result<String, Error>) -> Void) {
        startVideoRecording(completion: completion)
    }

    public func stopRecording(completion: @escaping (Result<String, Error>) -> Void) {
        stopVideoRecording(completion: completion)
    }

    public var isRecording: Bool { isRecordingInternal }

    public func setFlash(_ mode: FlashMode) {
        sessionQueue.async { [weak self] in self?.setFlashModeInternal(mode.rawValue) }
    }

    public func setAspectRatio(_ ratio: AspectRatio) {
        setAspectRatioInternal(ratio.rawValue)
    }

    public func setZoom(_ zoomFactor: CGFloat) {
        sessionQueue.async { [weak self] in self?.setZoomInternal(zoomFactor) }
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        metalDevice = device
        commandQueue = device.makeCommandQueue()
        ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB()
        ])

        let mtkView = MTKView(frame: bounds)
        mtkView.device = device
        mtkView.framebufferOnly = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 30
        mtkView.delegate = self
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.contentMode = .scaleAspectFill
        mtkView.backgroundColor = .black

        addSubview(mtkView)
        metalView = mtkView
    }

    // MARK: - Camera Setup

    /// Returns the best camera device available for the given position, ranked by **max photo area**.
    /// On iPhone 15 Pro+, the standalone wide-angle supports 48 MP stills, while the triple-camera
    /// virtual device caps at 12 MP — so we'd lose 4× resolution if we blindly preferred multi-lens.
    /// Apple's stock Camera also uses the wide-angle directly for max-resolution stills.
    private func bestCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let candidates: [AVCaptureDevice.DeviceType]
        if position == .back {
            candidates = [.builtInWideAngleCamera, .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera]
        } else {
            candidates = [.builtInWideAngleCamera]
        }

        var best: (device: AVCaptureDevice, area: Int)?
        for type in candidates {
            guard let cam = AVCaptureDevice.default(type, for: .video, position: position) else { continue }
            let area = maxPhotoArea(for: cam)
            if let current = best {
                if area > current.area { best = (cam, area) }
            } else {
                best = (cam, area)
            }
        }
        return best?.device ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// The largest still-photo area across all of a device's supported formats. Used to compare devices.
    private func maxPhotoArea(for device: AVCaptureDevice) -> Int {
        device.formats.map { photoArea(of: $0) }.max() ?? 0
    }

    /// Picks the device's best format: highest still-photo dimensions, tie-breaking on highest video dims,
    /// requiring 30fps support so live preview stays smooth.
    private func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { fmt in
            fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        let pool = candidates.isEmpty ? device.formats : candidates
        return pool.max { a, b in
            let aPhoto = photoArea(of: a)
            let bPhoto = photoArea(of: b)
            if aPhoto != bPhoto { return aPhoto < bPhoto }
            return videoArea(of: a) < videoArea(of: b)
        }
    }

    private func photoArea(of fmt: AVCaptureDevice.Format) -> Int {
        if #available(iOS 16.0, *) {
            // The array's order isn't documented as sorted — pick by area to be robust.
            if let dim = fmt.supportedMaxPhotoDimensions.max(by: { (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height)) }) {
                return Int(dim.width) * Int(dim.height)
            }
        }
        let d = fmt.highResolutionStillImageDimensions
        return Int(d.width) * Int(d.height)
    }

    private func videoArea(of fmt: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        return Int(d.width) * Int(d.height)
    }

    private func applyBestFormat(_ device: AVCaptureDevice) {
        guard let format = bestFormat(for: device) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            // Lock to 30 fps inside the chosen format. The format was filtered to support >=30 fps in
            // bestFormat(), so this is safe and stops iOS from auto-throttling under heavy filter load.
            let target = CMTime(value: 1, timescale: 30)
            if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {}
    }

    /// Enable rotation, mirroring (front), and the strongest available stabilization on a connection.
    private func configureVideoConnection(_ connection: AVCaptureConnection, isFront: Bool) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isFront
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        // .inputPriority lets us drive activeFormat directly so we always pick the device's best format
        // (highest still + highest video) instead of being capped by a generic preset.
        session.sessionPreset = .inputPriority

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let camera = bestCamera(position: .back) else { return }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            return
        }
        applyBestFormat(camera)

        let output = AVCaptureVideoDataOutput()
        // No size keys — deliver native frames at the format's video resolution (up to 4K on supported devices).
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: renderQueue)

        if session.canAddOutput(output) { session.addOutput(output) }

        if let connection = output.connection(with: .video) {
            configureVideoConnection(connection, isFront: false)
        }

        videoOutput = output
        captureSession = session

        let photoOut = AVCapturePhotoOutput()
        if #available(iOS 16.0, *) {
            photoOut.maxPhotoQualityPrioritization = .quality
        } else {
            photoOut.isHighResolutionCaptureEnabled = true
        }
        if session.canAddOutput(photoOut) { session.addOutput(photoOut) }
        if #available(iOS 16.0, *) {
            let videoDevice = session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) }?.device
            if let dims = videoDevice?.activeFormat.supportedMaxPhotoDimensions,
               let maxDim = dims.max(by: { (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height)) }) {
                photoOut.maxPhotoDimensions = maxDim
            }
        }
        photoOutput = photoOut

        setupAudioCapture(session: session)
        // Note: don't startRunning() here — viewDidAppear's startCamera() owns lifecycle.
        // Starting twice from two paths makes the session race with itself.
    }

    private func setupAudioCapture(session: AVCaptureSession) {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) { session.addInput(audioInput) }
            let audioOut = AVCaptureAudioDataOutput()
            audioOut.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
            audioOutput = audioOut
        } catch {}
    }

    // MARK: - Blur Overlay

    private func addBlurOverlayInternal(id: String, x: Double, y: Double, width: Double, height: Double,
                                        cornerRadius: Double, blurStyle: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.blurViews[id]?.removeFromSuperview()

            let frame = CGRect(x: x, y: y, width: width, height: height)
            let boundsFrame = CGRect(x: 0, y: 0, width: width, height: height)

            let blurContainer = UIView(frame: frame)
            blurContainer.backgroundColor = .clear

            let glassView = UIView(frame: boundsFrame)
            glassView.layer.cornerRadius = cornerRadius
            glassView.clipsToBounds = true

            let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            let blurView = UIVisualEffectView(effect: blurEffect)
            blurView.frame = boundsFrame
            blurView.alpha = 0.5
            glassView.addSubview(blurView)

            let lensHighlight = CAGradientLayer()
            lensHighlight.frame = boundsFrame
            lensHighlight.type = .radial
            lensHighlight.colors = [
                UIColor.white.withAlphaComponent(0.12).cgColor,
                UIColor.white.withAlphaComponent(0.03).cgColor,
                UIColor.clear.cgColor
            ]
            lensHighlight.locations = [0.0, 0.4, 1.0]
            lensHighlight.startPoint = CGPoint(x: 0.5, y: 0.3)
            lensHighlight.endPoint = CGPoint(x: 1.0, y: 1.0)
            glassView.layer.addSublayer(lensHighlight)

            let specularEdge = CAGradientLayer()
            specularEdge.frame = CGRect(x: 0, y: 0, width: width, height: 2)
            specularEdge.colors = [
                UIColor.white.withAlphaComponent(0.0).cgColor,
                UIColor.white.withAlphaComponent(0.5).cgColor,
                UIColor.white.withAlphaComponent(0.5).cgColor,
                UIColor.white.withAlphaComponent(0.0).cgColor
            ]
            specularEdge.locations = [0.0, 0.3, 0.7, 1.0]
            specularEdge.startPoint = CGPoint(x: 0, y: 0.5)
            specularEdge.endPoint = CGPoint(x: 1, y: 0.5)
            glassView.layer.addSublayer(specularEdge)

            let innerShadow = CAGradientLayer()
            innerShadow.frame = CGRect(x: 0, y: height - 8, width: width, height: 8)
            innerShadow.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.03).cgColor]
            innerShadow.startPoint = CGPoint(x: 0.5, y: 0)
            innerShadow.endPoint = CGPoint(x: 0.5, y: 1)
            glassView.layer.addSublayer(innerShadow)

            let borderLayer = CAShapeLayer()
            let insetRect = boundsFrame.insetBy(dx: 0.5, dy: 0.5)
            borderLayer.path = UIBezierPath(roundedRect: insetRect, cornerRadius: cornerRadius - 0.5).cgPath
            borderLayer.fillColor = UIColor.clear.cgColor
            borderLayer.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
            borderLayer.lineWidth = 0.5
            glassView.layer.addSublayer(borderLayer)

            blurContainer.addSubview(glassView)
            self.addSubview(blurContainer)
            self.blurViews[id] = blurContainer
            self.lastAppliedBlurFrames[id] = frame
        }
    }

    private func updateBlurOverlayInternal(id: String, x: Double, y: Double, width: Double, height: Double,
                                           cornerRadius: Double) {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingBlurFrames[id] = frame
            self.pendingBlurCornerRadius[id] = CGFloat(cornerRadius)
            if self.blurFlushScheduled { return }
            self.blurFlushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushPendingBlurUpdates() }
        }
    }

    private func flushPendingBlurUpdates() {
        blurFlushScheduled = false
        guard !pendingBlurFrames.isEmpty else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (id, frame) in pendingBlurFrames {
            guard let container = blurViews[id] else { continue }
            if lastAppliedBlurFrames[id] == frame { continue }

            let sizeChanged = lastAppliedBlurFrames[id]?.size != frame.size
            container.frame = frame

            if sizeChanged {
                let boundsFrame = CGRect(origin: .zero, size: frame.size)
                let cornerRadius = pendingBlurCornerRadius[id] ?? 0
                container.layer.shadowPath = UIBezierPath(roundedRect: boundsFrame, cornerRadius: cornerRadius).cgPath
                if let glassView = container.subviews.first {
                    glassView.frame = boundsFrame
                    glassView.layer.cornerRadius = cornerRadius
                }
            }
            lastAppliedBlurFrames[id] = frame
        }
        pendingBlurFrames.removeAll(keepingCapacity: true)
        pendingBlurCornerRadius.removeAll(keepingCapacity: true)
    }

    private func removeBlurOverlayInternal(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.blurViews[id]?.removeFromSuperview()
            self.blurViews.removeValue(forKey: id)
            self.pendingBlurFrames.removeValue(forKey: id)
            self.pendingBlurCornerRadius.removeValue(forKey: id)
            self.lastAppliedBlurFrames.removeValue(forKey: id)
        }
    }

    private func removeAllBlurOverlaysInternal() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.blurViews.values.forEach { $0.removeFromSuperview() }
            self.blurViews.removeAll()
            self.pendingBlurFrames.removeAll()
            self.pendingBlurCornerRadius.removeAll()
            self.lastAppliedBlurFrames.removeAll()
        }
    }

    // MARK: - Camera Switch

    private func switchCameraInternal() {
        guard let session = captureSession else { return }

        let newPosition: AVCaptureDevice.Position = (currentCameraPosition == .back) ? .front : .back
        guard let newCamera = bestCamera(position: newPosition) else { return }

        session.beginConfiguration()

        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                session.removeInput(deviceInput)
                break
            }
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: newCamera)
            guard session.canAddInput(newInput) else { session.commitConfiguration(); return }
            session.addInput(newInput)
        } catch {
            session.commitConfiguration()
            return
        }
        applyBestFormat(newCamera)

        if let connection = videoOutput?.connection(with: .video) {
            configureVideoConnection(connection, isFront: newPosition == .front)
        }

        if let photoConnection = photoOutput?.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if photoConnection.isVideoRotationAngleSupported(90) { photoConnection.videoRotationAngle = 90 }
            } else {
                if photoConnection.isVideoOrientationSupported { photoConnection.videoOrientation = .portrait }
            }
            // Photo connection mirror stays off — we apply the front-camera mirror in CIImage so behavior
            // is deterministic across iOS versions.
            if photoConnection.isVideoMirroringSupported {
                photoConnection.automaticallyAdjustsVideoMirroring = false
                photoConnection.isVideoMirrored = false
            }
        }

        if #available(iOS 16.0, *) {
            if let maxDim = newCamera.activeFormat.supportedMaxPhotoDimensions
                .max(by: { (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height)) }) {
                photoOutput?.maxPhotoDimensions = maxDim
            }
        }

        session.commitConfiguration()
        currentCameraPosition = newPosition
    }

    // MARK: - Camera Settings

    private func setFlashModeInternal(_ mode: String) {
        guard let session = captureSession,
              let deviceInput = session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.hasMediaType(.video) }) else { return }
        let device = deviceInput.device
        do {
            try device.lockForConfiguration()
            switch mode {
            case "Auto":
                if device.hasTorch { device.torchMode = .off }
                currentFlashMode = .auto
            case "On":
                if device.hasTorch && device.isTorchModeSupported(.on) { device.torchMode = .on }
                currentFlashMode = .on
            default:
                if device.hasTorch { device.torchMode = .off }
                currentFlashMode = .off
            }
            device.unlockForConfiguration()
        } catch {}
    }

    private func setAspectRatioInternal(_ ratio: String) {
        currentAspectRatioString = ratio
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let metalView = self.metalView else { return }
            switch ratio {
            case "1:1":
                let size = min(self.bounds.width, self.bounds.height)
                let x = (self.bounds.width - size) / 2
                let y = (self.bounds.height - size) / 2
                metalView.frame = CGRect(x: x, y: y, width: size, height: size)
            case "16:9":
                let width = self.bounds.width
                let height = width * 16 / 9
                let y = (self.bounds.height - height) / 2
                metalView.frame = CGRect(x: 0, y: y, width: width, height: height)
            default:
                metalView.frame = self.bounds
            }
        }
    }

    private func videoSettingsForCurrentPreset() -> (Int, Int, Int) {
        // Read native dimensions from the device's active format — we use .inputPriority to drive
        // the format directly, so this returns whatever the device's best format actually is (up to 4K).
        let device = captureSession?.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.video) })
        let dim = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
            ?? CMVideoDimensions(width: 1920, height: 1080)

        let w = Int(dim.width), h = Int(dim.height)
        let pixels = w * h
        // HEVC bitrates calibrated to Apple Camera output at each native resolution.
        let bitrate: Int
        switch pixels {
        case let p where p >= 3840 * 2160:  bitrate = 60_000_000   // 4K
        case let p where p >= 1920 * 1080:  bitrate = 22_000_000   // FHD
        case let p where p >= 1280 * 720:   bitrate = 10_000_000   // HD
        default:                            bitrate = 5_000_000    // SD or smaller
        }
        return (h, w, bitrate)
    }

    private func setZoomInternal(_ zoomFactor: CGFloat) {
        guard let session = captureSession,
              let deviceInput = session.inputs
                .compactMap({ $0 as? AVCaptureDeviceInput })
                .first(where: { $0.device.hasMediaType(.video) }) else { return }
        let device = deviceInput.device
        do {
            try device.lockForConfiguration()
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
            device.videoZoomFactor = max(minZoom, min(zoomFactor, maxZoom))
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            writeAudioSample(sampleBuffer: sampleBuffer)
            return
        }

        imageLock.lock()
        guard !isCleanedUp else { imageLock.unlock(); return }
        imageLock.unlock()

        let shouldProcess: Bool
        pendingFrameLock.lock()
        if pendingFrameForDisplay && !isRecordingInternal {
            shouldProcess = false
        } else {
            shouldProcess = true
            pendingFrameForDisplay = true
        }
        pendingFrameLock.unlock()

        guard shouldProcess else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageSize = inputImage.extent.size
        lastImageSize = imageSize

        let needsFaceDetection = filterProcessor.faceOnlySmoothEnabled
            || filterProcessor.faceColorTintEnabled
            || filterProcessor.lipPlumpEnabled
            || filterProcessor.milkySkinEnabled
            || faceTrackingEnabled

        if needsFaceDetection {
            // Snapshot the input image's extent on the capture queue — needed by the parsing service
            // to map the model output back into image-extent coordinates.
            let parsingExtent = inputImage.extent
            let parsingImage = inputImage
            faceDetectionService.detectFaces(in: inputImage, imageSize: imageSize) { [weak self] faces in
                guard let self = self else { return }
                self.renderQueue.async { [weak self] in
                    self?.filterProcessor.detectedFaces = faces
                }

                // Kick off ML face parsing on the same cadence as detection. Result is set on the
                // filter processor as soon as it's ready; until then the polygon mask continues to be used.
                if self.faceParsingService.isAvailable, let firstFace = faces.first {
                    self.faceParsingService.parse(
                        image: parsingImage,
                        faceBBox: firstFace.boundingBox,
                        imageExtent: parsingExtent
                    ) { [weak self] mask in
                        self?.renderQueue.async { [weak self] in
                            self?.filterProcessor.externalSkinMask = mask
                        }
                    }
                } else {
                    // No faces (or model unavailable) — clear any stale ML mask so we don't leak it
                    // onto the next frame. The polygon mask (or no mask) takes over.
                    self.renderQueue.async { [weak self] in
                        self?.filterProcessor.externalSkinMask = nil
                    }
                }

                if self.faceTrackingEnabled {
                    let imageSize = self.lastImageSize
                    DispatchQueue.main.async {
                        let drawableSize = self.lastDrawableSize
                        guard drawableSize.width > 0, drawableSize.height > 0,
                              imageSize.width > 0, imageSize.height > 0 else { return }

                        let scale = max(drawableSize.width / imageSize.width,
                                        drawableSize.height / imageSize.height)
                        let sx = imageSize.width  * scale / drawableSize.width
                        let sy = imageSize.height * scale / drawableSize.height
                        let ox = (1.0 - sx) / 2.0
                        let oy = (1.0 - sy) / 2.0

                        // Heavy smoothing for the visible overlay box only. Mask path uses the
                        // unsmoothed-by-this-EMA bbox internally, so the mask still tracks the face.
                        let visualSmoothing: CGFloat = 0.78
                        let facesData = faces.map { face -> [String: Double] in
                            let bbox: CGRect
                            if let prev = self.displayOverlayBBox {
                                bbox = CGRect(
                                    x: prev.origin.x * visualSmoothing + face.boundingBox.origin.x * (1 - visualSmoothing),
                                    y: prev.origin.y * visualSmoothing + face.boundingBox.origin.y * (1 - visualSmoothing),
                                    width:  prev.width  * visualSmoothing + face.boundingBox.width  * (1 - visualSmoothing),
                                    height: prev.height * visualSmoothing + face.boundingBox.height * (1 - visualSmoothing)
                                )
                            } else {
                                bbox = face.boundingBox
                            }
                            self.displayOverlayBBox = bbox
                            return [
                                "x": Double(bbox.origin.x * sx + ox),
                                "y": Double(bbox.origin.y * sy + oy),
                                "width":  Double(bbox.width  * sx),
                                "height": Double(bbox.height * sy),
                            ]
                        }
                        if faces.isEmpty { self.displayOverlayBBox = nil }
                        self.delegate?.beautyCameraView(self, didDetectFaces: facesData)
                    }
                }
            }
        }

        let processedImage = filterProcessor.processImage(inputImage)

        imageLock.lock()
        lastCapturedImage = processedImage
        currentCIImage = processedImage
        imageLock.unlock()

        if isRecordingInternal { writeVideoFrame(sampleBuffer: sampleBuffer) }
    }

    // MARK: - Photo Capture

    private func capturePhotoInternal(completion: @escaping (Result<String, Error>) -> Void) {
        guard let photoOutput = photoOutput else {
            completion(.failure(BeautyCameraError.captureError("Photo output not available")))
            return
        }

        photoCaptureCompletion = completion

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }

        if #available(iOS 16.0, *) {
            let videoDevice = captureSession?.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) }?.device

            // Pick by area, not by .last — array order isn't documented as sorted.
            let areaCmp: (CMVideoDimensions, CMVideoDimensions) -> Bool = {
                (Int($0.width) * Int($0.height)) < (Int($1.width) * Int($1.height))
            }
            if let device = videoDevice,
               let deviceMaxDim = device.activeFormat.supportedMaxPhotoDimensions.max(by: areaCmp) {
                let outputMax = photoOutput.maxPhotoDimensions
                if outputMax.width > 0 && outputMax.height > 0 {
                    let safeDim = device.activeFormat.supportedMaxPhotoDimensions
                        .filter { $0.width <= outputMax.width && $0.height <= outputMax.height }
                        .max(by: areaCmp) ?? outputMax
                    settings.maxPhotoDimensions = safeDim
                } else {
                    photoOutput.maxPhotoDimensions = deviceMaxDim
                    settings.maxPhotoDimensions = deviceMaxDim
                }
            }
            // .quality enables Smart HDR / Deep Fusion / Photonic Engine. The front sensor depends on
            // these passes — without them, photos look flat and noisy.
            settings.photoQualityPrioritization = .quality
        } else {
            settings.isHighResolutionPhotoEnabled = true
        }

        sessionQueue.async { photoOutput.capturePhoto(with: settings, delegate: self) }
    }

    private func savePhotoAndReturn(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(.success(fileURL.path)) }

        let saveToLibrary = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            } completionHandler: { _, _ in }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                saveToLibrary()
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else { return }
                saveToLibrary()
            }
        }
    }

    private func saveRawDataAsHEIC(_ data: Data) -> URL? {
        guard let photosDir = makePhotosDir() else { return nil }
        let fileURL = photosDir.appendingPathComponent("photo_\(Int(Date().timeIntervalSince1970 * 1000)).heic")
        try? data.write(to: fileURL)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func saveCGImageAsHEIC(_ cgImage: CGImage) -> URL? {
        guard let photosDir = makePhotosDir() else { return nil }
        let fileURL = photosDir.appendingPathComponent("photo_\(Int(Date().timeIntervalSince1970 * 1000)).heic")
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return fileURL
    }

    private func makePhotosDir() -> URL? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = cacheDir.appendingPathComponent("captured_photos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Video Recording

    private func startVideoRecording(completion: @escaping (Result<String, Error>) -> Void) {
        recordingLock.lock()
        defer { recordingLock.unlock() }

        guard !isRecordingInternal else {
            completion(.failure(BeautyCameraError.alreadyRecording))
            return
        }

        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            completion(.failure(BeautyCameraError.storageError("Cannot access cache directory")))
            return
        }

        let videosDir = cacheDir.appendingPathComponent("recorded_videos")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        let videoURL = videosDir.appendingPathComponent("video_\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        currentVideoURL = videoURL

        do {
            assetWriter = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        } catch {
            completion(.failure(BeautyCameraError.writerError(error.localizedDescription)))
            return
        }

        let (presetWidth, presetHeight, videoBitrate) = videoSettingsForCurrentPreset()

        // Derive output dimensions from the preview aspect so the recorded video matches what the user
        // sees in the preview. Keep the preset's longer side as our longer side and compute the shorter.
        // (H.264 requires even dimensions.)
        let previewAspect: CGFloat
        if Thread.isMainThread {
            previewAspect = previewAspectRatio()
        } else {
            var fetched: CGFloat = 0
            DispatchQueue.main.sync { fetched = self.previewAspectRatio() }
            previewAspect = fetched
        }

        let aspect = previewAspect > 0 ? previewAspect : CGFloat(presetWidth) / CGFloat(presetHeight)
        let longest = max(presetWidth, presetHeight)
        var outW: Int
        var outH: Int
        if aspect >= 1 {
            outW = longest
            outH = Int((CGFloat(longest) / aspect).rounded())
        } else {
            outH = longest
            outW = Int((CGFloat(longest) * aspect).rounded())
        }
        outW &= ~1
        outH &= ~1
        let videoWidth = max(outW, 2)
        let videoHeight = max(outH, 2)

        // HEVC is the same codec the system Camera app uses on every iPhone since the 7. Hardware-accelerated
        // and produces visibly cleaner motion / less blocking than H.264 at the bitrates we're targeting.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                // ~1 keyframe / second at 30 fps so seeking stays responsive without hurting compression.
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]
        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: videoWidth,
            kCVPixelBufferHeightKey as String: videoHeight
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput!,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        if assetWriter!.canAdd(videoWriterInput!) { assetWriter!.add(videoWriterInput!) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44100,
            AVEncoderBitRateKey: 128000
        ]
        audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioWriterInput?.expectsMediaDataInRealTime = true
        if assetWriter!.canAdd(audioWriterInput!) { assetWriter!.add(audioWriterInput!) }

        videoOutputWidth = videoWidth
        videoOutputHeight = videoHeight

        assetWriter!.startWriting()
        isRecordingInternal = true
        recordingStartTime = nil

        DispatchQueue.main.async { completion(.success("Recording started")) }
    }

    private func stopVideoRecording(completion: @escaping (Result<String, Error>) -> Void) {
        recordingLock.lock()
        let wasRecording = isRecordingInternal
        isRecordingInternal = false
        recordingLock.unlock()

        guard wasRecording, let writer = assetWriter else {
            completion(.failure(BeautyCameraError.notRecording))
            return
        }

        let videoIn = videoWriterInput
        let audioIn = audioWriterInput
        let videoURL = currentVideoURL

        renderQueue.async { [weak self] in
            guard let self = self else { return }
            videoIn?.markAsFinished()
            audioIn?.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.pixelBufferAdaptor = nil
                self.recordingStartTime = nil

                if writer.status == .completed, let url = videoURL {
                    self.saveVideoToLibrary(videoURL: url, completion: completion)
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(BeautyCameraError.writeError(writer.error?.localizedDescription ?? "Unknown")))
                    }
                }
            }
        }
    }

    private func saveVideoToLibrary(videoURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let saveVideo = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(videoURL.path))
                    } else {
                        completion(.failure(BeautyCameraError.saveError(error?.localizedDescription ?? "Unknown")))
                    }
                }
            }
        }

        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.permissionDenied)) }
                    return
                }
                saveVideo()
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.permissionDenied)) }
                    return
                }
                saveVideo()
            }
        }
    }

    private func writeVideoFrame(sampleBuffer: CMSampleBuffer) {
        guard isRecordingInternal,
              let writer = assetWriter, writer.status == .writing,
              let input = videoWriterInput, input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if recordingStartTime == nil {
            recordingStartTime = timestamp
            writer.startSession(atSourceTime: timestamp)
        }

        imageLock.lock()
        guard let ciImage = currentCIImage else { imageLock.unlock(); return }
        imageLock.unlock()

        let targetW = CGFloat(videoOutputWidth)
        let targetH = CGFloat(videoOutputHeight)
        let srcExtent = ciImage.extent
        let scale = max(targetW / srcExtent.width, targetH / srcExtent.height)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let cropX = scaledImage.extent.origin.x + (scaledImage.extent.width  - targetW) / 2.0
        let cropY = scaledImage.extent.origin.y + (scaledImage.extent.height - targetH) / 2.0
        let croppedImage = scaledImage.cropped(to: CGRect(x: cropX, y: cropY, width: targetW, height: targetH))
        let alignedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, videoOutputWidth, videoOutputHeight,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        }
        guard let outputBuffer = pixelBuffer else { return }
        ciContext?.render(alignedImage, to: outputBuffer)
        adaptor.append(outputBuffer, withPresentationTime: timestamp)
    }

    private func writeAudioSample(sampleBuffer: CMSampleBuffer) {
        guard isRecordingInternal,
              let writer = assetWriter, writer.status == .writing,
              let input = audioWriterInput, input.isReadyForMoreMediaData,
              recordingStartTime != nil else { return }
        input.append(sampleBuffer)
    }

    // MARK: - Latest Photo

    private func getLatestPhotoFromLibrary(completion: @escaping (String?) -> Void) {
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }

        switch status {
        case .authorized, .limited:
            fetchLatestPhoto(completion: completion)
        case .notDetermined:
            if #available(iOS 14, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] newStatus in
                    if newStatus == .authorized || newStatus == .limited {
                        self?.fetchLatestPhoto(completion: completion)
                    } else {
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            } else {
                PHPhotoLibrary.requestAuthorization { [weak self] newStatus in
                    if newStatus == .authorized {
                        self?.fetchLatestPhoto(completion: completion)
                    } else {
                        DispatchQueue.main.async { completion(nil) }
                    }
                }
            }
        default:
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func fetchLatestPhoto(completion: @escaping (String?) -> Void) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.fetchLimit = 1
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        guard let latestAsset = fetchResult.firstObject else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        imageManager.requestImage(for: latestAsset, targetSize: CGSize(width: 200, height: 200),
                                  contentMode: .aspectFill, options: options) { [weak self] image, _ in
            guard let image = image else { DispatchQueue.main.async { completion(nil) }; return }
            if let path = self?.saveThumbnailLocally(image) {
                DispatchQueue.main.async { completion(path) }
            } else {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private func saveThumbnailLocally(_ image: UIImage) -> String? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = cacheDir.appendingPathComponent("captured_photos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("latest_thumbnail.jpg")
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        try? data.write(to: fileURL)
        return fileURL.path
    }

    // MARK: - Cleanup

    deinit { cleanup() }

    private func cleanup() {
        NotificationCenter.default.removeObserver(self)

        imageLock.lock()
        isCleanedUp = true
        imageLock.unlock()

        metalView?.isPaused = true
        metalView?.delegate = nil
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)

        // Capture refs locally so the async block doesn't touch self after it's deallocated.
        // sessionQueue.sync from deinit can deadlock if the queue is mid-stopRunning posting
        // notifications back to main — and on real devices that occasionally manifests as a
        // main-thread stack overflow (EXC_BAD_ACCESS code=2). Async tear-down avoids it.
        let sessionRef = captureSession
        sessionQueue.async {
            sessionRef?.stopRunning()
            if let s = sessionRef {
                s.inputs.forEach { s.removeInput($0) }
                s.outputs.forEach { s.removeOutput($0) }
            }
        }

        imageLock.lock()
        currentCIImage = nil
        lastCapturedImage = nil
        imageLock.unlock()

        metalView?.removeFromSuperview()
        metalView = nil
        ciContext = nil
        commandQueue = nil
        metalDevice = nil
        captureSession = nil
        videoOutput = nil
    }
}

// MARK: - MTKViewDelegate

extension BeautyCameraView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard inFlightSemaphore.wait(timeout: .now()) == .success else { return }

        imageLock.lock()
        if isCleanedUp { imageLock.unlock(); inFlightSemaphore.signal(); return }
        let ciImage = currentCIImage
        imageLock.unlock()

        guard let ciImage = ciImage,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let context = ciContext else {
            inFlightSemaphore.signal()
            return
        }

        let drawableSize = view.drawableSize
        lastDrawableSize = drawableSize
        let imageSize = ciImage.extent.size

        let scale = max(drawableSize.width / imageSize.width, drawableSize.height / imageSize.height)
        var scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let offsetX = (drawableSize.width - scaledImage.extent.width) / 2 - scaledImage.extent.origin.x
        let offsetY = (drawableSize.height - scaledImage.extent.height) / 2 - scaledImage.extent.origin.y
        scaledImage = scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        let destination = CIRenderDestination(
            width: Int(drawableSize.width),
            height: Int(drawableSize.height),
            pixelFormat: view.colorPixelFormat,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )

        try? context.startTask(toRender: scaledImage, to: destination)

        pendingFrameLock.lock()
        pendingFrameForDisplay = false
        pendingFrameLock.unlock()

        commandBuffer.addCompletedHandler { [weak self] _ in self?.inFlightSemaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension BeautyCameraView: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let completion = photoCaptureCompletion else { return }
        photoCaptureCompletion = nil

        if let error = error {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { completion(.failure(BeautyCameraError.captureError("Failed to decode captured photo"))) }
            return
        }

        let filtersActive = filterProcessor.hasActiveFilters()
        let previewAspect = pendingPreviewAspect
        pendingPreviewAspect = 0
        let isFront = (currentCameraPosition == .front)

        // Run on a dedicated queue (not sessionQueue) so the camera session stays responsive —
        // the next shot, focus tap, zoom, or torch toggle isn't queued behind a heavy decode/encode.
        photoProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            // Decode → optionally filter → enhance (denoise + sharpen) → mirror (front only) → crop → encode.
            guard let ciImage = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
                DispatchQueue.main.async { completion(.failure(BeautyCameraError.captureError("Failed to decode captured photo"))) }
                return
            }

            var output: CIImage = ciImage
            if filtersActive {
                // Re-run face detection + parsing on the CAPTURED photo so the mask matches the photo's
                // pixels (not the lagged live-preview mask). Brief race window where the live preview
                // could see this photo-specific mask is acceptable — both are at native sensor resolution.
                let savedExternalMask = self.filterProcessor.externalSkinMask
                if let bbox = self.detectFirstFaceBBox(in: ciImage),
                   let photoMask = self.faceParsingService.parseSync(
                       image: ciImage, faceBBox: bbox, imageExtent: ciImage.extent
                   ) {
                    self.filterProcessor.externalSkinMask = photoMask
                }
                self.filterProcessor.invalidateSegmentationCache()
                output = self.filterProcessor.processImage(ciImage)
                // Restore the live mask immediately so the preview isn't left with the photo's mask.
                self.filterProcessor.externalSkinMask = savedExternalMask
            }
            // Match the live preview's left-right orientation for selfie shots.
            if isFront { output = self.mirrorHorizontally(output) }
            output = self.cropToPreviewAspect(output, previewAspect: previewAspect)

            // Pull the source HEIC's actual color space so we render into the same gamut the sensor
            // produced. Falls back to displayP3 (the iPhone default) if metadata is missing.
            let renderColorSpace = self.sourceColorSpace(from: imageData)
                ?? CGColorSpace(name: CGColorSpace.displayP3)
                ?? CGColorSpaceCreateDeviceRGB()

            // Render at 16-bit float through the dedicated photo context (P3 working color space).
            // No sRGB↔P3 round-trip → highlights and saturation match the original sensor output.
            guard let cgImage = self.photoCIContext.createCGImage(
                output,
                from: output.extent,
                format: .RGBAh,
                colorSpace: renderColorSpace
            ) else {
                DispatchQueue.main.async { completion(.failure(BeautyCameraError.captureError("Failed to render captured photo"))) }
                return
            }
            guard let fileURL = self.saveCGImageAsHEIC(cgImage) else {
                DispatchQueue.main.async { completion(.failure(BeautyCameraError.saveError("Failed to encode captured photo as HEIC"))) }
                return
            }
            self.savePhotoAndReturn(fileURL: fileURL, completion: completion)
        }
    }
}
