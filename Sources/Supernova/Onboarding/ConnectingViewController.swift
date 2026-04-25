import UIKit
import Combine

/// Connecting screen — shown after a device is selected in FindDeviceViewController.
/// Drives the BLE connection and shows success / failure UI.
public final class ConnectingViewController: UIViewController {

    public var bleService: BLEService?
    public var device: DiscoveredDevice?
    public var onConnected: (() -> Void)?
    public var onRetry: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Views

    private let gradientLayer = CAGradientLayer()
    private let dotLoader = DotsLoaderView()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    private enum ViewState { case connecting, connected, failed(String) }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startConnection()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    public override var prefersStatusBarHidden: Bool { true }

    // MARK: - Setup

    private func setupUI() {
        // Gradient: dark top → light bottom
        gradientLayer.colors = [
            UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 1).cgColor,
            UIColor(red: 0.937, green: 0.937, blue: 0.937, alpha: 1).cgColor,
        ]
        gradientLayer.locations = [0, 0.9]
        view.layer.insertSublayer(gradientLayer, at: 0)

        // Checkmark (hidden until connected)
        checkmark.tintColor = .white
        checkmark.contentMode = .scaleAspectFit
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false

        dotLoader.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = "CONNECTING..."
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textAlignment = .center

        subtitleLabel.text = "Pairing with D&V SUPERNOVA"
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 16)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let labelStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labelStack.axis = .vertical; labelStack.spacing = 8; labelStack.alignment = .center

        actionButton.setTitleColor(.white, for: .normal)
        actionButton.backgroundColor = .black
        actionButton.layer.cornerRadius = 4
        actionButton.titleLabel?.font = .systemFont(ofSize: 16)
        actionButton.isHidden = true
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        let centreStack = UIStackView(arrangedSubviews: [checkmark, dotLoader, UIView(), labelStack])
        centreStack.axis = .vertical; centreStack.spacing = 50; centreStack.alignment = .center
        centreStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(centreStack)
        view.addSubview(actionButton)

        NSLayoutConstraint.activate([
            centreStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centreStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            centreStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            centreStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            checkmark.widthAnchor.constraint(equalToConstant: 80),
            checkmark.heightAnchor.constraint(equalToConstant: 80),
            dotLoader.heightAnchor.constraint(equalToConstant: 24),
            actionButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionButton.topAnchor.constraint(equalTo: centreStack.bottomAnchor, constant: 54),
            actionButton.widthAnchor.constraint(equalToConstant: 280),
            actionButton.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    // MARK: - Connection logic

    private func startConnection() {
        guard let ble = bleService, let device = device else {
            // Demo mode: simulate connection after 4 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.apply(state: .connected)
            }
            return
        }

        ble.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .connected:
                    self?.apply(state: .connected)
                case .error(let msg):
                    self?.apply(state: .failed(msg))
                case .disconnected(let reason):
                    self?.apply(state: .failed(reason ?? "Disconnected"))
                default: break
                }
            }.store(in: &cancellables)

        ble.connect(to: device)
    }

    private func apply(state: ViewState) {
        switch state {
        case .connecting:
            dotLoader.isHidden = false; dotLoader.startAnimating()
            checkmark.isHidden = true
            titleLabel.text = "CONNECTING..."
            titleLabel.textColor = .white
            subtitleLabel.text = "Pairing with D&V SUPERNOVA"
            actionButton.isHidden = true

        case .connected:
            dotLoader.stopAnimating(); dotLoader.isHidden = true
            checkmark.isHidden = false
            titleLabel.text = "D&V SUPERNOVA CONNECTED"
            titleLabel.textColor = .black
            subtitleLabel.text = "You are ready to go."
            subtitleLabel.textColor = .black
            actionButton.setTitle("CONTINUE", for: .normal)
            actionButton.isHidden = false
            actionButton.tag = 0

        case .failed(let msg):
            dotLoader.stopAnimating(); dotLoader.isHidden = true
            checkmark.isHidden = true
            titleLabel.text = "CONNECTION FAILED"
            titleLabel.textColor = .red
            subtitleLabel.text = msg
            subtitleLabel.textColor = .black
            actionButton.setTitle("TRY AGAIN", for: .normal)
            actionButton.isHidden = false
            actionButton.tag = 1
        }
    }

    @objc private func actionTapped() {
        if actionButton.tag == 0 {
            onConnected?()
        } else {
            onRetry?()
        }
    }
}

// MARK: - DotsLoaderView

private final class DotsLoaderView: UIView {
    private var dots: [UIView] = []
    private var animTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for i in 0..<3 {
            let dot = UIView()
            dot.backgroundColor = .white
            dot.layer.cornerRadius = 6
            dot.frame = CGRect(x: CGFloat(i) * 20, y: 0, width: 12, height: 12)
            addSubview(dot)
            dots.append(dot)
        }
        widthAnchor.constraint(equalToConstant: 52).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        var tick = 0
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for (i, dot) in self.dots.enumerated() {
                UIView.animate(withDuration: 0.2) {
                    dot.alpha = i == tick % 3 ? 1.0 : 0.3
                    dot.transform = i == tick % 3 ? CGAffineTransform(scaleX: 1.3, y: 1.3) : .identity
                }
            }
            tick += 1
        }
    }

    func stopAnimating() {
        animTimer?.invalidate(); animTimer = nil
        dots.forEach { $0.alpha = 1; $0.transform = .identity }
    }
}
