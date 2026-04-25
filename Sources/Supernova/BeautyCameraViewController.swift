import UIKit

/// Demo view controller — shows the beauty camera full-screen.
/// Integrate this into your app's navigation or embed it as a child VC.
open class BeautyCameraViewController: UIViewController {

    public private(set) var cameraView: BeautyCameraView!

    // Expose public API for convenience
    public var filterSettings: FilterSettings = FilterSettings() {
        didSet { cameraView?.setFilter(filterSettings) }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCameraView()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        cameraView.startCamera()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraView.stopCamera()
    }

    private func setupCameraView() {
        cameraView = BeautyCameraView(frame: view.bounds)
        cameraView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cameraView.delegate = self
        view.addSubview(cameraView)
    }

    // MARK: - Convenience wrappers

    public func capturePhoto(completion: @escaping (Result<String, Error>) -> Void) {
        cameraView.capturePhoto(completion: completion)
    }

    public func switchCamera() {
        cameraView.switchCamera()
    }

    public func setFlash(_ mode: FlashMode) {
        cameraView.setFlash(mode)
    }

    public func setAspectRatio(_ ratio: AspectRatio) {
        cameraView.setAspectRatio(ratio)
    }

    public func setQuality(_ quality: VideoQuality) {
        cameraView.setQuality(quality)
    }

    public func setZoom(_ factor: CGFloat) {
        cameraView.setZoom(factor)
    }

    public func startRecording(completion: @escaping (Result<String, Error>) -> Void) {
        cameraView.startRecording(completion: completion)
    }

    public func stopRecording(completion: @escaping (Result<String, Error>) -> Void) {
        cameraView.stopRecording(completion: completion)
    }

    public func addBlurOverlay(id: String, x: Double, y: Double, width: Double, height: Double,
                               cornerRadius: Double = 0, blurStyle: String = "light") {
        cameraView.addBlurOverlay(id: id, x: x, y: y, width: width, height: height,
                                  cornerRadius: cornerRadius, blurStyle: blurStyle)
    }

    public func removeBlurOverlay(id: String) {
        cameraView.removeBlurOverlay(id: id)
    }

    public func removeAllBlurOverlays() {
        cameraView.removeAllBlurOverlays()
    }
}

extension BeautyCameraViewController: BeautyCameraViewDelegate {
    open func beautyCameraView(_ view: BeautyCameraView, didDetectFaces faces: [[String: Double]]) {
        // Override in subclass to handle face detection events.
    }
}
