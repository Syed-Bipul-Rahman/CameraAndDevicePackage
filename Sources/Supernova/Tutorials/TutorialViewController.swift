import UIKit

/// Mirrors the Flutter TutorialScreen: a scrollable list of titled tutorial cards
/// with a navigation bar that includes camera and light shortcut icons.
public final class TutorialViewController: UIViewController {

    public var onBack: (() -> Void)?
    public var onCameraTap: (() -> Void)?
    public var onLightTap: (() -> Void)?

    private struct Item {
        let title: String
        let imageName: String
    }

    private let items: [Item] = [
        .init(title: "1. How to change light?", imageName: "tut2"),
        .init(title: "2. How to setup for Studio Photography?", imageName: "tut1"),
        .init(title: "3. How to setup proper camera angle?", imageName: "tut3"),
        .init(title: "4. How to setup proper camera angle?", imageName: "tut1"),
    ]

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavBar()
        setupScrollView()
        populate()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Other screens (Camera, Home) hide the nav bar on the shared navigation controller; restore it here.
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private func setupNavBar() {
        title = "Tutorials"
        navigationController?.navigationBar.tintColor = .label
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.backward"),
            style: .plain, target: self, action: #selector(backTapped))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "lightbulb"),
                            style: .plain, target: self, action: #selector(lightTapped)),
            UIBarButtonItem(image: UIImage(systemName: "camera"),
                            style: .plain, target: self, action: #selector(cameraTapped)),
        ]
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: safe.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    private func populate() {
        for item in items {
            contentStack.addArrangedSubview(makeTitleLabel(item.title))
            contentStack.addArrangedSubview(makeImageCard(named: item.imageName))
        }
    }

    private func makeTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }

    private func makeImageCard(named name: String) -> UIView {
        let container = UIView()
        container.layer.cornerRadius = 12
        container.clipsToBounds = true
        container.backgroundColor = .secondarySystemBackground

        let imageView = UIImageView(image: loadImage(named: name))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(equalToConstant: 200),
        ])
        return container
    }

    private func loadImage(named name: String) -> UIImage? {
        // Look in Bundle.module first (where Swift Package resources live), then fall back to main bundle.
        if let url = Bundle.module.url(forResource: name, withExtension: "jpg"),
           let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        return UIImage(named: name)
    }

    @objc private func backTapped() {
        if let onBack { onBack() } else { navigationController?.popViewController(animated: true) }
    }

    @objc private func cameraTapped() { onCameraTap?() }
    @objc private func lightTapped() { onLightTap?() }
}
