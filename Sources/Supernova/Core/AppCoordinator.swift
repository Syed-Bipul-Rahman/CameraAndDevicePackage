import UIKit

/// Root coordinator — owns the window, the BLEService singleton, and all navigation.
/// Create one instance in your AppDelegate / SceneDelegate and call `start()`.
///
/// Flow:
///   Splash (3s) → Welcome (video + auto-advance 6s) → GetStarted (video + button)
///   → Find Device → Connecting → Home
///   Home: Camera | Light Control | Tutorial
///
/// Returning users skip the welcome / get-started screens but must still pair a device.
public final class AppCoordinator {

    private let window: UIWindow
    private let bleService = BLEService()
    private var navigationController: UINavigationController!

    private static let onboardingDoneKey = "supernova.onboardingDone"

    public init(window: UIWindow) {
        self.window = window
    }

    public func start() {
        navigationController = UINavigationController()
        navigationController.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()

        if UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) {
            // Returning user: skip the video onboarding but still require a fresh BLE connection.
            showFindDevice()
        } else {
            showSplash()
        }
    }

    // MARK: - Onboarding flow

    private func showSplash() {
        let vc = SplashViewController()
        vc.onFinished = { [weak self] in self?.showWelcome() }
        navigationController.setViewControllers([vc], animated: false)
    }

    private func showWelcome() {
        let vc = OnboardingVideoViewController()
        vc.config = .init(videoName: "light1", buttonTitle: "Let's Get Started", buttonStyle: .outlined, autoAdvanceAfter: 6)
        vc.onAction = { [weak self] in self?.showGetStarted() }
        navigationController.setViewControllers([vc], animated: true)
    }

    private func showGetStarted() {
        let vc = OnboardingVideoViewController()
        vc.config = .init(videoName: "light2", buttonTitle: "Let's Get Started", buttonStyle: .filled)
        vc.onAction = { [weak self] in self?.showFindDevice() }
        navigationController.pushViewController(vc, animated: true)
    }

    private func showFindDevice() {
        navigationController.setNavigationBarHidden(false, animated: false)
        let vc = FindDeviceViewController()
        vc.bleService = bleService
        vc.onDeviceSelected = { [weak self] device in self?.showConnecting(device: device) }
        vc.onBack = { [weak self] in self?.navigationController.popViewController(animated: true) }
        navigationController.pushViewController(vc, animated: true)
    }

    private func showConnecting(device: DiscoveredDevice) {
        let vc = ConnectingViewController()
        vc.bleService = bleService
        vc.device = device
        vc.onConnected = { [weak self] in
            // First-time pairing animates into the home screen; returning users replace the stack silently.
            if UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) {
                self?.showHome()
            } else {
                self?.showHomeAfterPairing()
            }
        }
        vc.onRetry = { [weak self] in
            self?.navigationController.popViewController(animated: true)
        }
        navigationController.pushViewController(vc, animated: true)
    }

    private func showHomeAfterPairing() {
        navigationController.setNavigationBarHidden(true, animated: false)
        let homeButtons = buildHomeButtons()
        let vc = OnboardingVideoViewController()
        vc.config = .init(videoName: "light2", buttonTitle: "", buttonStyle: .filled)
        vc.centreContentView = homeButtons
        vc.onAction = { }
        navigationController.setViewControllers([vc], animated: true)
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
    }

    // MARK: - Home

    private func showHome() {
        navigationController.setNavigationBarHidden(true, animated: false)
        let vc = OnboardingVideoViewController()
        vc.config = .init(videoName: "light2", buttonTitle: "", buttonStyle: .filled)
        vc.centreContentView = buildHomeButtons()
        vc.onAction = { }
        navigationController.setViewControllers([vc], animated: false)
    }

    private func buildHomeButtons() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical; stack.spacing = 16; stack.alignment = .center

        let cameraBtn = makeGlassButton(icon: "camera", label: "Camera") { [weak self] in
            self?.showCamera()
        }
        let lightBtn = makeGlassButton(icon: "lightbulb", label: "Super Nova") { [weak self] in
            self?.showLightControl()
        }
        let tutorialBtn = makeGlassButton(icon: "book.closed", label: "Tutorial") { [weak self] in
            self?.showTutorial()
        }

        [cameraBtn, lightBtn, tutorialBtn].forEach { stack.addArrangedSubview($0) }
        return stack
    }

    private func makeGlassButton(icon: String, label: String, action: @escaping () -> Void) -> UIView {
        let container = UIButton(type: .system)
        container.addAction(UIAction { _ in action() }, for: .touchUpInside)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 12; blur.clipsToBounds = true
        blur.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor; blur.layer.borderWidth = 1

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .white; iconView.contentMode = .scaleAspectFit
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let lbl = UILabel(); lbl.text = label; lbl.textColor = .white
        lbl.font = .systemFont(ofSize: 16, weight: .regular); lbl.textAlignment = .center

        let col = UIStackView(arrangedSubviews: [iconView, lbl])
        col.axis = .vertical; col.spacing = 8; col.alignment = .center
        col.isUserInteractionEnabled = false
        col.translatesAutoresizingMaskIntoConstraints = false

        blur.contentView.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])

        blur.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.widthAnchor.constraint(equalToConstant: 150).isActive = true
        container.heightAnchor.constraint(equalToConstant: 108).isActive = true
        return container
    }

    // MARK: - Destinations

    private func showCamera() {
        navigationController.setNavigationBarHidden(true, animated: false)
        let vc = CameraScreenViewController()
        vc.bleService = bleService
        navigationController.pushViewController(vc, animated: true)
    }

    private func showLightControl() {
        navigationController.setNavigationBarHidden(false, animated: false)
        let vc = LightControlViewController()
        vc.bleService = bleService
        navigationController.pushViewController(vc, animated: true)
    }

    private func showTutorial() {
        navigationController.setNavigationBarHidden(false, animated: false)
        let vc = TutorialViewController()
        vc.onBack = { [weak self] in self?.navigationController.popViewController(animated: true) }
        vc.onCameraTap = { [weak self] in self?.showCamera() }
        vc.onLightTap = { [weak self] in self?.showLightControl() }
        navigationController.pushViewController(vc, animated: true)
    }
}
