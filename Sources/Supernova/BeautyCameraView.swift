import UIKit
import AVFoundation
import Metal
import MetalKit
import Photos
import ImageIO

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
    private var lastImageSize: CGSize = .zero

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
        capturePhotoInternal(completion: completion)
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

    public func setQuality(_ quality: VideoQuality) {
        sessionQueue.async { [weak self] in self?.setQualityInternal(quality.rawValue) }
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

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        // All input/output additions must live between begin/commit so the session never
        // observes a partially configured state. Without this, real devices intermittently wedge.
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return
        }

        do {
            // Add the input first; configure device properties after, since some properties
            // (active frame durations) only validate against an attached, running format.
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }

            try camera.lockForConfiguration()
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        } catch {
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: renderQueue)

        if session.canAddOutput(output) { session.addOutput(output) }

        if let connection = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            } else {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
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
            if let maxDim = videoDevice?.activeFormat.supportedMaxPhotoDimensions.last {
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
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else { return }

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

            try newCamera.lockForConfiguration()
            if newCamera.isExposureModeSupported(.continuousAutoExposure) { newCamera.exposureMode = .continuousAutoExposure }
            if newCamera.isFocusModeSupported(.continuousAutoFocus) { newCamera.focusMode = .continuousAutoFocus }
            newCamera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            newCamera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            newCamera.unlockForConfiguration()
        } catch {
            session.commitConfiguration()
            return
        }

        if let connection = videoOutput?.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            }
            connection.isVideoMirrored = (newPosition == .front)
        }

        if let photoConnection = photoOutput?.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if photoConnection.isVideoRotationAngleSupported(90) { photoConnection.videoRotationAngle = 90 }
            } else {
                if photoConnection.isVideoOrientationSupported { photoConnection.videoOrientation = .portrait }
            }
            if photoConnection.isVideoMirroringSupported { photoConnection.isVideoMirrored = (newPosition == .front) }
        }

        if #available(iOS 16.0, *) {
            if let maxDim = newCamera.activeFormat.supportedMaxPhotoDimensions.last {
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

    private func setQualityInternal(_ quality: String) {
        guard let session = captureSession else { return }
        session.beginConfiguration()
        switch quality {
        case "SD":
            if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        case "HD":
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        case "FHD":
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        case "4K":
            if session.canSetSessionPreset(.hd4K3840x2160) { session.sessionPreset = .hd4K3840x2160 }
        default:
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        }
        session.commitConfiguration()
    }

    private func videoSettingsForCurrentPreset() -> (Int, Int, Int) {
        guard let preset = captureSession?.sessionPreset else { return (1280, 720, 6_000_000) }
        switch preset {
        case .vga640x480: return (480, 640, 2_000_000)
        case .hd1280x720: return (720, 1280, 6_000_000)
        case .hd1920x1080: return (1080, 1920, 12_000_000)
        case .hd4K3840x2160: return (2160, 3840, 40_000_000)
        default: return (1080, 1920, 12_000_000)
        }
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
            faceDetectionService.detectFaces(in: inputImage, imageSize: imageSize) { [weak self] faces in
                guard let self = self else { return }
                self.renderQueue.async { [weak self] in
                    self?.filterProcessor.detectedFaces = faces
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

                        let facesData = faces.map { face -> [String: Double] in [
                            "x": Double(face.boundingBox.origin.x * sx + ox),
                            "y": Double(face.boundingBox.origin.y * sy + oy),
                            "width":  Double(face.boundingBox.width * sx),
                            "height": Double(face.boundingBox.height * sy),
                        ]}
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

            if let device = videoDevice,
               let deviceMaxDim = device.activeFormat.supportedMaxPhotoDimensions.last {
                let outputMax = photoOutput.maxPhotoDimensions
                if outputMax.width > 0 && outputMax.height > 0 {
                    let safeDim = device.activeFormat.supportedMaxPhotoDimensions
                        .filter { $0.width <= outputMax.width && $0.height <= outputMax.height }
                        .last ?? outputMax
                    settings.maxPhotoDimensions = safeDim
                } else {
                    photoOutput.maxPhotoDimensions = deviceMaxDim
                    settings.maxPhotoDimensions = deviceMaxDim
                }
            }
            settings.photoQualityPrioritization = .speed
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
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
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

        let (videoWidth, videoHeight, videoBitrate) = videoSettingsForCurrentPreset()

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
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

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if filtersActive {
                guard let ciImage = CIImage(data: imageData, options: [.applyOrientationProperty: true]) else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.captureError("Failed to decode image for filtering"))) }
                    return
                }
                self.filterProcessor.invalidateSegmentationCache()
                let filteredImage = self.filterProcessor.processImage(ciImage)
                let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
                guard let cgImage = self.ciContext?.createCGImage(filteredImage, from: filteredImage.extent, format: .RGBA8, colorSpace: p3) else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.captureError("Failed to render filtered photo"))) }
                    return
                }
                guard let fileURL = self.saveCGImageAsHEIC(cgImage) else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.saveError("Failed to encode filtered photo as HEIC"))) }
                    return
                }
                self.savePhotoAndReturn(fileURL: fileURL, completion: completion)
            } else {
                guard let fileURL = self.saveRawDataAsHEIC(imageData) else {
                    DispatchQueue.main.async { completion(.failure(BeautyCameraError.saveError("Failed to write HEIC photo"))) }
                    return
                }
                self.savePhotoAndReturn(fileURL: fileURL, completion: completion)
            }
        }
    }
}
