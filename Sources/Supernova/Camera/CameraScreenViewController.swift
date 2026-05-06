import UIKit
import AVFoundation

/// Full-screen camera screen equivalent to the Flutter CameraScreen.
/// Compose via AppCoordinator or push directly onto a navigation controller.
open class CameraScreenViewController: UIViewController {

    // MARK: - Public API

    /// Inject a connected BLEService before presenting this screen.
    public var bleService: BLEService?

    // MARK: - State

    private var filterSettings = FilterSettings()
    private var isCapturing = false
    private var isVideoMode = false
    private var isRecording = false
    private var isSwitchingCamera = false
    private var isShowLightControl = false
    private var isShowFilterControl = false
    private var filterEnabled = false
    private var timerSeconds = 0
    private var isTimerCountdown = false
    private var timerCountdownValue = 0
    private var recordingStartDate: Date?
    private var recordingTimer: Timer?
    private var lastCapturedImagePath: String?

    // Draggable panel positions (centre of screen on first show)
    private var lightPanelPosition: CGPoint?
    private var filterPanelPosition: CGPoint?

    // Light slider values
    private var lightTemperature: Double = 50
    private var lightBrightness: Double  = 50

    // Filter slider values
    private var filterSmooth:   Float = 0
    private var filterPlump:    Float = 0
    private var filterMilky:    Float = 0
    private var filterBlur:     Float = 0

    // MARK: - Subviews

    private let cameraView = BeautyCameraView()
    private let faceOverlay = FaceTrackingOverlayView()
    private var appBar: CameraAppBarView!
    private var statusBarBackground: UIView!
    private var bottomControls: BottomControlsView!
    private var lightPanel: LightControlPanelView?
    private var filterPanel: FilterControlPanelView?
    private var switchOverlay: UIView!
    private var timerOverlay: TimerCountdownView?
    private var recordingBadge: RecordingBadgeView?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlays()
        setupAppBar()
        setupBottomControls()
        checkCameraPermission()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        cameraView.startCamera()
        loadLatestPhoto()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraView.stopCamera()
        stopRecordingTimer()
    }

    // MARK: - Setup

    private func setupCamera() {
        cameraView.delegate = self
        cameraView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cameraView)
        NSLayoutConstraint.activate([
            cameraView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cameraView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cameraView.topAnchor.constraint(equalTo: view.topAnchor),
            cameraView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOverlays() {
        // Face tracking overlay (non-interactive, above camera)
        faceOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(faceOverlay)
        NSLayoutConstraint.activate([
            faceOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            faceOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            faceOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            faceOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Camera switch black overlay
        switchOverlay = UIView()
        switchOverlay.backgroundColor = .black
        switchOverlay.alpha = 0
        switchOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchOverlay)
        NSLayoutConstraint.activate([
            switchOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            switchOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            switchOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            switchOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupAppBar() {
        let safeTop = view.window?.safeAreaInsets.top ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first?.safeAreaInsets.top ?? 44

        // Status bar colour
        statusBarBackground = UIView()
        statusBarBackground.backgroundColor = UIColor(red: 0.353, green: 0.353, blue: 0.353, alpha: 1)
        statusBarBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusBarBackground)

        appBar = CameraAppBarView()
        appBar.delegate = self
        appBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(appBar)

        NSLayoutConstraint.activate([
            statusBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarBackground.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarBackground.heightAnchor.constraint(equalToConstant: safeTop),
            appBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            appBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            appBar.topAnchor.constraint(equalTo: statusBarBackground.bottomAnchor),
        ])
    }

    private func setupBottomControls() {
        bottomControls = BottomControlsView()
        bottomControls.delegate = self
        bottomControls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomControls)
        NSLayoutConstraint.activate([
            bottomControls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomControls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomControls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Permission

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.cameraView.startCamera() }
            }
        default:
            showPermissionDenied()
        }
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "Camera access is required.\nGo to Settings > Privacy > Camera to enable it."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        let btn = UIButton(type: .system)
        btn.setTitle("Open Settings", for: .normal)
        btn.tintColor = .white
        btn.backgroundColor = UIColor(white: 1, alpha: 0.2)
        btn.layer.cornerRadius = 10
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.widthAnchor.constraint(equalToConstant: 160),
            btn.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Capture

    private func onCapture() {
        guard !isCapturing, !isTimerCountdown else { return }
        if isVideoMode {
            toggleRecording()
        } else if timerSeconds > 0 {
            startTimerCapture()
        } else {
            capturePhoto()
        }
    }

    private func startTimerCapture() {
        isTimerCountdown = true
        timerCountdownValue = timerSeconds
        showTimerOverlay(value: timerCountdownValue)

        func tick(_ remaining: Int) {
            guard remaining > 0 else {
                hideTimerOverlay()
                isTimerCountdown = false
                capturePhoto()
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            timerCountdownValue = remaining
            showTimerOverlay(value: remaining)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(remaining - 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(self.timerSeconds - 1) }
    }

    private func capturePhoto() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioServicesPlaySystemSound(1108)
        isCapturing = true
        bottomControls.setCaptureLoading(true)

        cameraView.capturePhoto { [weak self] result in
            guard let self = self else { return }
            self.isCapturing = false
            self.bottomControls.setCaptureLoading(false)
            if case .success(let path) = result {
                self.lastCapturedImagePath = path
                self.bottomControls.setThumbnail(path: path)
            }
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        cameraView.startRecording { [weak self] result in
            guard let self = self else { return }
            if case .success = result {
                self.isRecording = true
                self.recordingStartDate = Date()
                self.startRecordingTimer()
                self.showRecordingBadge()
                self.bottomControls.setRecording(true)
            }
        }
    }

    private func stopRecording() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isCapturing = true
        cameraView.stopRecording { [weak self] result in
            guard let self = self else { return }
            self.isRecording = false
            self.isCapturing = false
            self.recordingStartDate = nil
            self.stopRecordingTimer()
            self.hideRecordingBadge()
            self.bottomControls.setRecording(false)
        }
    }

    // MARK: - Camera switch

    private func switchCamera() {
        guard !isSwitchingCamera else { return }
        isSwitchingCamera = true
        faceOverlay.faces = []
        UIView.animate(withDuration: 0.2) { self.switchOverlay.alpha = 1 }

        cameraView.switchCamera()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            UIView.animate(withDuration: 0.2) { self.switchOverlay.alpha = 0 }
            self.isSwitchingCamera = false
        }
    }

    // MARK: - Light / Filter panels

    private func toggleLightPanel() {
        if isShowLightControl {
            hideLightPanel()
        } else {
            hideFilterPanel(animated: false)
            showLightPanel()
        }
    }

    private func toggleFilterPanel() {
        if isShowFilterControl {
            hideFilterPanel()
        } else {
            hideLightPanel(animated: false)
            showFilterPanel()
        }
    }

    private func showLightPanel() {
        isShowLightControl = true
        let panel = LightControlPanelView()
        panel.bleService = bleService
        panel.configure(temperature: lightTemperature, brightness: lightBrightness)
        panel.onClose = { [weak self] in self?.hideLightPanel() }
        panel.onTemperatureChanged = { [weak self] v in self?.lightTemperature = v }
        panel.onBrightnessChanged  = { [weak self] v in self?.lightBrightness = v }
        makeDraggable(panel, stored: &lightPanelPosition)
        view.addSubview(panel)
        positionPanel(panel, stored: lightPanelPosition)
        panel.animateIn()
        lightPanel = panel
    }

    private func hideLightPanel(animated: Bool = true) {
        isShowLightControl = false
        guard let panel = lightPanel else { return }
        lightPanel = nil
        if animated {
            panel.animateOut { panel.removeFromSuperview() }
        } else {
            panel.removeFromSuperview()
        }
    }

    private func showFilterPanel() {
        isShowFilterControl = true
        let panel = FilterControlPanelView()
        panel.configure(smooth: filterSmooth, plump: filterPlump, milky: filterMilky, blur: filterBlur)
        panel.onClose = { [weak self] in self?.hideFilterPanel() }
        panel.onSmoothChanged    = { [weak self] v in self?.filterSmooth = v }
        panel.onPlumpChanged     = { [weak self] v in self?.filterPlump = v }
        panel.onMilkyChanged     = { [weak self] v in self?.filterMilky = v; if v > 0 { self?.filterSmooth = 0; self?.filterPlump = 0 } }
        panel.onBlurChanged      = { [weak self] v in self?.filterBlur = v }
        panel.onFilterSettingsChanged = { [weak self] settings in
            self?.filterSettings = settings
            self?.cameraView.setFilter(settings)
        }
        makeDraggable(panel, stored: &filterPanelPosition)
        view.addSubview(panel)
        positionPanel(panel, stored: filterPanelPosition)
        panel.animateIn()
        filterPanel = panel
    }

    private func hideFilterPanel(animated: Bool = true) {
        isShowFilterControl = false
        guard let panel = filterPanel else { return }
        filterPanel = nil
        if animated {
            panel.animateOut { panel.removeFromSuperview() }
        } else {
            panel.removeFromSuperview()
        }
    }

    private func positionPanel(_ panel: UIView, stored: CGPoint?) {
        let panelWidth: CGFloat = 280
        let fitHeight = panel.systemLayoutSizeFitting(
            CGSize(width: panelWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let panelSize = CGSize(width: panelWidth, height: fitHeight > 20 ? fitHeight : 200)
        let w = view.bounds.width, h = view.bounds.height
        let origin = stored ?? CGPoint(x: (w - panelWidth) / 2, y: h * 0.3)
        panel.frame = CGRect(origin: origin, size: panelSize)
    }

    private func makeDraggable(_ panel: UIView, stored: inout CGPoint?) {
        panel.translatesAutoresizingMaskIntoConstraints = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panel.addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let panel = recognizer.view else { return }
        let translation = recognizer.translation(in: view)
        let newOrigin = CGPoint(
            x: (panel.frame.origin.x + translation.x).clamped(0, view.bounds.width - panel.frame.width),
            y: (panel.frame.origin.y + translation.y).clamped(0, view.bounds.height - panel.frame.height)
        )
        panel.frame.origin = newOrigin
        recognizer.setTranslation(.zero, in: view)

        if recognizer.state == .ended {
            if panel === lightPanel  { lightPanelPosition  = newOrigin }
            if panel === filterPanel { filterPanelPosition = newOrigin }
        }
    }

    // MARK: - Timer/recording overlays

    private func showTimerOverlay(value: Int) {
        timerOverlay?.removeFromSuperview()
        let overlay = TimerCountdownView(value: value)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -16),
        ])
        timerOverlay = overlay
    }

    private func hideTimerOverlay() {
        timerOverlay?.removeFromSuperview()
        timerOverlay = nil
    }

    private func showRecordingBadge() {
        recordingBadge?.removeFromSuperview()
        let badge = RecordingBadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            badge.bottomAnchor.constraint(equalTo: bottomControls.topAnchor, constant: -16),
        ])
        recordingBadge = badge
    }

    private func hideRecordingBadge() {
        recordingBadge?.removeFromSuperview()
        recordingBadge = nil
    }

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.recordingStartDate else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            self.recordingBadge?.update(seconds: elapsed)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Gallery

    private func loadLatestPhoto() {
        cameraView.getLatestPhoto { [weak self] path in
            guard let self = self, let path = path else { return }
            self.lastCapturedImagePath = path
            self.bottomControls.setThumbnail(path: path)
        }
    }

    private func openGallery() {
        let gallery = PhotoGalleryViewController()
        let nav = UINavigationController(rootViewController: gallery)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
}

// MARK: - BeautyCameraViewDelegate

extension CameraScreenViewController: BeautyCameraViewDelegate {
    open func beautyCameraView(_ view: BeautyCameraView, didDetectFaces faces: [[String: Double]]) {
        let rects = faces.compactMap { dict -> CGRect? in
            guard let x = dict["x"], let y = dict["y"], let w = dict["width"], let h = dict["height"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        DispatchQueue.main.async { self.faceOverlay.faces = rects }
    }
}

// MARK: - CameraAppBarViewDelegate

extension CameraScreenViewController: CameraAppBarViewDelegate {
    public func cameraAppBar(_ bar: CameraAppBarView, didChangeFlash value: String) {
        let mode: FlashMode = value == "Auto" ? .auto : value == "On" ? .on : .off
        cameraView.setFlash(mode)
    }

    public func cameraAppBar(_ bar: CameraAppBarView, didChangeRatio value: String) {
        let ratio: AspectRatio = value == "1:1" ? .square : value == "16:9" ? .widescreen : .standard
        cameraView.setAspectRatio(ratio)
    }

    public func cameraAppBar(_ bar: CameraAppBarView, didChangeQuality value: String) {
        let quality: VideoQuality
        switch value {
        case "SD": quality = .sd
        case "FHD": quality = .fullHD
        case "4K": quality = .uhd4K
        default: quality = .hd
        }
        cameraView.setQuality(quality)
    }

    public func cameraAppBar(_ bar: CameraAppBarView, didChangeZoom value: String) {
        let factor: CGFloat = CGFloat(Double(value.replacingOccurrences(of: "x", with: "")) ?? 1.0)
        cameraView.setZoom(factor)
    }

    public func cameraAppBar(_ bar: CameraAppBarView, didChangeTimer value: String) {
        switch value {
        case "3s": timerSeconds = 3
        case "5s": timerSeconds = 5
        case "10s": timerSeconds = 10
        default: timerSeconds = 0
        }
    }

    public func cameraAppBar(_ bar: CameraAppBarView, didToggleFilter enabled: Bool) {
        filterEnabled = enabled
    }

    public func cameraAppBarDidTapBack(_ bar: CameraAppBarView) {
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }
}

// MARK: - BottomControlsDelegate

extension CameraScreenViewController: BottomControlsViewDelegate {
    func bottomControlsDidTapCapture(_ controls: BottomControlsView) { onCapture() }
    func bottomControlsDidTapSwitchCamera(_ controls: BottomControlsView) { switchCamera() }
    func bottomControlsDidTapGallery(_ controls: BottomControlsView) { openGallery() }
    func bottomControlsDidTapLight(_ controls: BottomControlsView) { toggleLightPanel() }
    func bottomControlsDidTapFilter(_ controls: BottomControlsView) { toggleFilterPanel() }
    func bottomControlsDidChangeMode(_ controls: BottomControlsView, isVideo: Bool) {
        guard !isRecording else { return }
        isVideoMode = isVideo
        bottomControls.setVideoMode(isVideo)
    }
}

// MARK: - BottomControlsView

protocol BottomControlsViewDelegate: AnyObject {
    func bottomControlsDidTapCapture(_ controls: BottomControlsView)
    func bottomControlsDidTapSwitchCamera(_ controls: BottomControlsView)
    func bottomControlsDidTapGallery(_ controls: BottomControlsView)
    func bottomControlsDidTapLight(_ controls: BottomControlsView)
    func bottomControlsDidTapFilter(_ controls: BottomControlsView)
    func bottomControlsDidChangeMode(_ controls: BottomControlsView, isVideo: Bool)
}

final class BottomControlsView: UIView {

    weak var delegate: BottomControlsViewDelegate?

    private var isVideoMode = false
    private var isRecording = false

    private let captureButton = UIButton()
    private let switchButton  = UIButton()
    private let galleryButton = UIButton()
    private let lightButton   = UIButton()
    private let filterButton  = UIButton()
    private let photoTab      = UIButton()
    private let videoTab      = UIButton()
    private var galleryImageView: UIImageView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.7).cgColor]
        gradient.locations = [0, 1]
        layer.insertSublayer(gradient, at: 0)

        // Mode tabs
        photoTab.setTitle("Photo", for: .normal)
        photoTab.titleLabel?.font = .systemFont(ofSize: 15)
        photoTab.backgroundColor = .white
        photoTab.setTitleColor(.black, for: .normal)
        photoTab.layer.cornerRadius = 18
        photoTab.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        photoTab.addTarget(self, action: #selector(photoTapped), for: .touchUpInside)

        videoTab.setTitle("Video", for: .normal)
        videoTab.titleLabel?.font = .systemFont(ofSize: 15)
        videoTab.backgroundColor = UIColor(white: 0.5, alpha: 0.2)
        videoTab.setTitleColor(.white, for: .normal)
        videoTab.layer.cornerRadius = 18
        videoTab.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        videoTab.addTarget(self, action: #selector(videoTapped), for: .touchUpInside)

        let tabRow = UIStackView(arrangedSubviews: [photoTab, videoTab])
        tabRow.axis = .horizontal; tabRow.spacing = 16; tabRow.alignment = .center

        // Side buttons
        filterButton.setImage(UIImage(systemName: "camera"), for: .normal)
        filterButton.tintColor = .white
        filterButton.addTarget(self, action: #selector(filterTapped), for: .touchUpInside)

        lightButton.setImage(UIImage(systemName: "lightbulb"), for: .normal)
        lightButton.tintColor = .white
        lightButton.addTarget(self, action: #selector(lightTapped), for: .touchUpInside)

        let modeRow = UIStackView(arrangedSubviews: [filterButton, tabRow, lightButton])
        modeRow.axis = .horizontal; modeRow.distribution = .equalSpacing; modeRow.alignment = .center

        // Gallery / Capture / Switch row
        let galleryBtn = UIButton()
        galleryBtn.layer.cornerRadius = 36
        galleryBtn.layer.borderWidth = 2; galleryBtn.layer.borderColor = UIColor.white.cgColor
        galleryBtn.clipsToBounds = true
        galleryBtn.backgroundColor = UIColor(white: 0.3, alpha: 1)
        galleryBtn.setImage(UIImage(systemName: "photo"), for: .normal)
        galleryBtn.tintColor = .white
        galleryBtn.widthAnchor.constraint(equalToConstant: 72).isActive = true
        galleryBtn.heightAnchor.constraint(equalToConstant: 72).isActive = true
        galleryBtn.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
        let imgView = UIImageView()
        imgView.contentMode = .scaleAspectFill
        imgView.clipsToBounds = true
        imgView.isUserInteractionEnabled = false
        imgView.translatesAutoresizingMaskIntoConstraints = false
        galleryBtn.addSubview(imgView)
        NSLayoutConstraint.activate([imgView.leadingAnchor.constraint(equalTo: galleryBtn.leadingAnchor), imgView.trailingAnchor.constraint(equalTo: galleryBtn.trailingAnchor), imgView.topAnchor.constraint(equalTo: galleryBtn.topAnchor), imgView.bottomAnchor.constraint(equalTo: galleryBtn.bottomAnchor)])
        galleryImageView = imgView

        captureButton.layer.cornerRadius = 36
        captureButton.layer.borderWidth = 4; captureButton.layer.borderColor = UIColor.white.cgColor
        captureButton.backgroundColor = .white
        captureButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        captureButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)

        switchButton.layer.cornerRadius = 36
        switchButton.layer.borderWidth = 2; switchButton.layer.borderColor = UIColor.white.cgColor
        switchButton.backgroundColor = UIColor(white: 0.5, alpha: 0.8)
        switchButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchButton.tintColor = .white
        switchButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        switchButton.heightAnchor.constraint(equalToConstant: 72).isActive = true
        switchButton.addTarget(self, action: #selector(switchTapped), for: .touchUpInside)

        let captureRow = UIStackView(arrangedSubviews: [galleryBtn, captureButton, switchButton])
        captureRow.axis = .horizontal; captureRow.distribution = .equalSpacing; captureRow.alignment = .center

        let mainStack = UIStackView(arrangedSubviews: [modeRow, captureRow])
        mainStack.axis = .vertical; mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.first?.frame = bounds
    }

    func setCaptureLoading(_ loading: Bool) {
        captureButton.isEnabled = !loading
        captureButton.alpha = loading ? 0.6 : 1
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        let inner = captureButton.subviews.first(where: { $0 is UIView && !($0 is UIImageView) })
        inner?.removeFromSuperview()
        if recording {
            let square = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            square.backgroundColor = .red
            square.layer.cornerRadius = 4
            square.center = CGPoint(x: 64/2, y: 64/2)
            captureButton.backgroundColor = .clear
            captureButton.addSubview(square)
            captureButton.layer.borderColor = UIColor.red.cgColor
        } else {
            captureButton.backgroundColor = .white
            captureButton.layer.borderColor = UIColor.white.cgColor
        }
    }

    func setVideoMode(_ video: Bool) {
        isVideoMode = video
        photoTab.backgroundColor = video ? UIColor(white: 0.5, alpha: 0.2) : .white
        photoTab.setTitleColor(video ? .white : .black, for: .normal)
        videoTab.backgroundColor = video ? .white : UIColor(white: 0.5, alpha: 0.2)
        videoTab.setTitleColor(video ? .black : .white, for: .normal)
        captureButton.layer.borderColor = video ? UIColor.red.cgColor : UIColor.white.cgColor
    }

    func setThumbnail(path: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = UIImage(contentsOfFile: path) else { return }
            DispatchQueue.main.async { self.galleryImageView?.image = img }
        }
    }

    @objc private func captureTapped() { delegate?.bottomControlsDidTapCapture(self) }
    @objc private func switchTapped()  { delegate?.bottomControlsDidTapSwitchCamera(self) }
    @objc private func galleryTapped() { delegate?.bottomControlsDidTapGallery(self) }
    @objc private func lightTapped()   { delegate?.bottomControlsDidTapLight(self) }
    @objc private func filterTapped()  { delegate?.bottomControlsDidTapFilter(self) }
    @objc private func photoTapped()   { delegate?.bottomControlsDidChangeMode(self, isVideo: false) }
    @objc private func videoTapped()   { delegate?.bottomControlsDidChangeMode(self, isVideo: true) }
}

// MARK: - TimerCountdownView

private final class TimerCountdownView: UIView {
    private let label = UILabel()

    init(value: Int) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0, alpha: 0.54)
        layer.cornerRadius = 40
        widthAnchor.constraint(equalToConstant: 80).isActive = true
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        layer.borderWidth = 3; layer.borderColor = UIColor.white.cgColor
        label.text = "\(value)"
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 40)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(value: Int) { label.text = "\(value)" }
}

// MARK: - RecordingBadgeView

private final class RecordingBadgeView: UIView {
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .red
        layer.cornerRadius = 14
        let dot = UIView(); dot.backgroundColor = .white; dot.layer.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        timeLabel.text = "00:00"; timeLabel.textColor = .white; timeLabel.font = .boldSystemFont(ofSize: 16)
        let row = UIStackView(arrangedSubviews: [dot, timeLabel])
        row.axis = .horizontal; row.spacing = 8; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), row.topAnchor.constraint(equalTo: topAnchor, constant: 8), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(seconds: Int) {
        let m = seconds / 60, s = seconds % 60
        timeLabel.text = String(format: "%02d:%02d", m, s)
    }
}

// MARK: - CGFloat clamp helper

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.max(lo, Swift.min(self, hi)) }
}

