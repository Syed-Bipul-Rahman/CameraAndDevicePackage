import UIKit
import AVFoundation

/// Reusable onboarding screen that plays a looping video full-screen
/// and shows a single CTA button at the bottom.
/// Used for onboarding screens 1, 2, and 4.
public final class OnboardingVideoViewController: UIViewController {

    // MARK: - Configuration

    public struct Config {
        public let videoName: String
        public let videoExtension: String
        public let buttonTitle: String
        public let buttonStyle: ButtonStyle
        public let autoAdvanceAfter: TimeInterval?

        public enum ButtonStyle {
            case outlined   // Screen 1: white border, white text
            case filled     // Screen 2+: dark background, white text
        }

        public init(videoName: String, videoExtension: String = "mp4",
                    buttonTitle: String, buttonStyle: ButtonStyle,
                    autoAdvanceAfter: TimeInterval? = nil) {
            self.videoName = videoName
            self.videoExtension = videoExtension
            self.buttonTitle = buttonTitle
            self.buttonStyle = buttonStyle
            self.autoAdvanceAfter = autoAdvanceAfter
        }
    }

    public var config: Config?
    public var onAction: (() -> Void)?
    /// Optional extra content overlaid in the centre (used by screen 4 for glass buttons)
    public var centreContentView: UIView?

    // MARK: - AV

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupButton()
        if let centre = centreContentView { setupCentreContent(centre) }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Resume playback when returning to this screen (e.g. popping back from Camera/Light/Tutorial).
        player?.play()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        player?.pause()
    }

    deinit {
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
    }

    public override var prefersStatusBarHidden: Bool { true }

    // MARK: - Setup

    private func setupVideo() {
        guard let cfg = config,
              let url = Bundle.main.url(forResource: cfg.videoName, withExtension: cfg.videoExtension)
                ?? Bundle.module.url(forResource: cfg.videoName, withExtension: cfg.videoExtension) else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        playerLayer = layer

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        player.play()
    }

    private func setupButton() {
        guard let cfg = config else { return }
        // Home / post-pairing screens pass an empty title — don't render a CTA in that case.
        guard !cfg.buttonTitle.isEmpty else { return }

        let btn = UIButton(type: .system)
        var titleText = cfg.buttonTitle + "  "
        btn.setTitle(titleText, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16)

        let arrow = UIImageView(image: UIImage(systemName: "arrow.right"))
        arrow.tintColor = .white
        arrow.translatesAutoresizingMaskIntoConstraints = false

        switch cfg.buttonStyle {
        case .outlined:
            btn.setTitleColor(.white, for: .normal)
            btn.layer.borderColor = UIColor.white.cgColor
            btn.layer.borderWidth = 1
            btn.layer.cornerRadius = 4
        case .filled:
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = UIColor(red: 0.082, green: 0.094, blue: 0.098, alpha: 1)
            btn.layer.cornerRadius = 4
        }

        btn.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false

        // Auto-advance is opt-in (screen 1 only). Guard against firing if the user has already navigated away.
        if let delay = cfg.autoAdvanceAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self,
                      self.isViewLoaded,
                      self.view.window != nil,
                      self.navigationController?.topViewController === self else { return }
                self.onAction?()
            }
        }

        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            btn.widthAnchor.constraint(equalToConstant: 280),
            btn.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    private func setupCentreContent(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func actionTapped() { onAction?() }
}
