import UIKit

/// Splash screen — shows app logo for 3 seconds then pushes to onboarding.
public final class SplashViewController: UIViewController {

    public var onFinished: (() -> Void)?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel()
        label.text = "SUPERNOVA"
        label.textColor = .white
        label.font = .systemFont(ofSize: 36, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.onFinished?()
        }
    }

    public override var prefersStatusBarHidden: Bool { true }
}
