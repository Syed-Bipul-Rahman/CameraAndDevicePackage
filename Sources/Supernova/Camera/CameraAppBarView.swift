import UIKit

// MARK: - Delegate

public protocol CameraAppBarViewDelegate: AnyObject {
    func cameraAppBar(_ bar: CameraAppBarView, didChangeFlash value: String)
    func cameraAppBar(_ bar: CameraAppBarView, didChangeRatio value: String)
    func cameraAppBar(_ bar: CameraAppBarView, didChangeZoom value: String)
    func cameraAppBar(_ bar: CameraAppBarView, didChangeTimer value: String)
    func cameraAppBar(_ bar: CameraAppBarView, didToggleFilter enabled: Bool)
    func cameraAppBarDidTapBack(_ bar: CameraAppBarView)
}

// MARK: - CameraAppBarView

public final class CameraAppBarView: UIView {

    public weak var delegate: CameraAppBarViewDelegate?

    private let barColor = UIColor(red: 0.353, green: 0.353, blue: 0.353, alpha: 1)

    // Current selection state
    private(set) var selectedFlash   = "Off"
    private(set) var selectedRatio   = "4:3"
    private(set) var selectedZoom    = "1x"
    private(set) var selectedTimer   = "Off"
    private(set) var filterEnabled   = false

    private var expandedButton: ExpandableOptionButton?

    private let backButton     = UIButton(type: .system)
    private let filterButton   = CircleToggleButton()
    private var optionButtons: [ExpandableOptionButton] = []

    private let flashOptions   = ["Auto", "On", "Off"]
    private let ratioOptions   = ["4:3", "1:1", "16:9"]
    private let zoomOptions    = ["0.6", "1x", "2x", "3x"]
    private let timerOptions   = ["Off", "3s", "5s", "10s"]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = barColor

        // Back button
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        // Expandable options. Tag 2 (quality) intentionally skipped — the camera always picks the
        // highest format the device supports, so there's nothing for the user to choose.
        let flashBtn = makeOption(tag: 0, label: "Off", icon: UIImage(systemName: "bolt"),  options: flashOptions)
        let ratioBtn = makeOption(tag: 1, label: "4:3", icon: nil,                          options: ratioOptions)
        let zoomBtn  = makeOption(tag: 3, label: "1x",  icon: nil,                          options: zoomOptions)
        let timerBtn = makeOption(tag: 4, label: "Off", icon: UIImage(systemName: "timer"), options: timerOptions)
        optionButtons = [flashBtn, ratioBtn, zoomBtn, timerBtn]

        // Filter circle toggle
        filterButton.isOn = false
        filterButton.onTintColor = .white
        filterButton.offTintColor = UIColor(white: 0.44, alpha: 1)
        filterButton.iconImage = UIImage(systemName: "wand.and.stars")
        filterButton.addTarget(self, action: #selector(filterToggled), for: .touchUpInside)

        // Stack layout
        let stack = UIStackView(arrangedSubviews: [backButton, flashBtn, ratioBtn, zoomBtn, timerBtn, filterButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            backButton.heightAnchor.constraint(equalToConstant: 32),
            filterButton.widthAnchor.constraint(equalToConstant: 32),
            filterButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(collapseAll))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    private func makeOption(tag: Int, label: String, icon: UIImage?, options: [String]) -> ExpandableOptionButton {
        let btn = ExpandableOptionButton()
        btn.tag = tag
        btn.configure(label: label, icon: icon, options: options)
        btn.onOptionSelected = { [weak self] value in
            self?.handleOptionSelected(tag: tag, value: value)
        }
        btn.onTap = { [weak self] in
            self?.toggleExpanded(btn)
        }
        return btn
    }

    private func toggleExpanded(_ btn: ExpandableOptionButton) {
        if expandedButton === btn {
            btn.collapse()
            expandedButton = nil
        } else {
            expandedButton?.collapse()
            btn.expand()
            expandedButton = btn
        }
    }

    @objc private func collapseAll() {
        expandedButton?.collapse()
        expandedButton = nil
    }

    @objc private func backTapped() {
        delegate?.cameraAppBarDidTapBack(self)
    }

    @objc private func filterToggled() {
        filterEnabled = !filterEnabled
        filterButton.isOn = filterEnabled
        delegate?.cameraAppBar(self, didToggleFilter: filterEnabled)
    }

    private func handleOptionSelected(tag: Int, value: String) {
        // Tags match the original layout (0 flash, 1 ratio, 3 zoom, 4 timer); 2 (quality) was removed.
        // optionButtons array is now densely packed: [flash, ratio, zoom, timer] -> indices 0..3.
        switch tag {
        case 0: selectedFlash = value; optionButtons[0].setSelected(value); delegate?.cameraAppBar(self, didChangeFlash: value)
        case 1: selectedRatio = value; optionButtons[1].setSelected(value); delegate?.cameraAppBar(self, didChangeRatio: value)
        case 3: selectedZoom  = value; optionButtons[2].setSelected(value); delegate?.cameraAppBar(self, didChangeZoom: value)
        case 4: selectedTimer = value; optionButtons[3].setSelected(value); delegate?.cameraAppBar(self, didChangeTimer: value)
        default: break
        }
        collapseAll()
    }
}

// MARK: - ExpandableOptionButton

final class ExpandableOptionButton: UIView {

    var onOptionSelected: ((String) -> Void)?
    var onTap: (() -> Void)?

    private var options: [String] = []
    private var selectedValue: String = ""
    private var iconImage: UIImage?

    private let selectedCircle = UIView()
    private let selectedLabel  = UILabel()
    private let selectedIcon   = UIImageView()
    private let optionsStack   = UIStackView()
    private var widthConstraint: NSLayoutConstraint!

    private let collapsedWidth: CGFloat = 32
    private var expandedWidth: CGFloat = 120

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        layer.cornerRadius = 16
        clipsToBounds = true
        backgroundColor = UIColor(white: 0.44, alpha: 1)

        widthConstraint = widthAnchor.constraint(equalToConstant: collapsedWidth)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        translatesAutoresizingMaskIntoConstraints = false

        // Selected circle
        selectedCircle.layer.cornerRadius = 16
        selectedCircle.clipsToBounds = true
        selectedCircle.translatesAutoresizingMaskIntoConstraints = false

        selectedLabel.textColor = .black
        selectedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectedLabel.textAlignment = .center

        selectedIcon.contentMode = .scaleAspectFit
        selectedIcon.tintColor = .white

        let circleContent = UIStackView(arrangedSubviews: [selectedLabel, selectedIcon])
        circleContent.translatesAutoresizingMaskIntoConstraints = false
        selectedCircle.addSubview(circleContent)
        NSLayoutConstraint.activate([
            circleContent.centerXAnchor.constraint(equalTo: selectedCircle.centerXAnchor),
            circleContent.centerYAnchor.constraint(equalTo: selectedCircle.centerYAnchor),
        ])

        // Options stack — hidden (not just alpha=0) so UIStackView excludes it from layout while collapsed.
        optionsStack.axis = .horizontal
        optionsStack.alignment = .center
        optionsStack.spacing = 10
        optionsStack.alpha = 0
        optionsStack.isHidden = true
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [selectedCircle, optionsStack, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectedCircle.widthAnchor.constraint(equalToConstant: 32),
            selectedCircle.heightAnchor.constraint(equalToConstant: 32),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    func configure(label: String, icon: UIImage?, options: [String]) {
        selectedValue = label
        iconImage = icon
        self.options = options
        expandedWidth = CGFloat(32 + options.count * 36 + 12)

        if let icon = icon {
            selectedLabel.isHidden = true
            selectedIcon.isHidden = false
            selectedIcon.image = icon
        } else {
            selectedLabel.isHidden = false
            selectedIcon.isHidden = true
            selectedLabel.text = label
        }
        selectedCircle.backgroundColor = .clear
        // Labels are NOT added here — they're built lazily on expand() and torn down on collapse(),
        // so the collapsed state has zero arranged subviews and no UISV-spacing constraints to conflict
        // with the 32 pt width.
    }

    func setSelected(_ value: String) {
        selectedValue = value
        if iconImage == nil {
            selectedLabel.text = value
        }
        // Only rebuild if currently visible — otherwise leave the stack empty.
        if !optionsStack.isHidden {
            buildOptionLabels()
        }
    }

    private func buildOptionLabels() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for opt in options where opt != selectedValue {
            let lbl = UILabel()
            lbl.text = opt
            lbl.textColor = UIColor(white: 0.62, alpha: 1)
            lbl.font = .systemFont(ofSize: 12, weight: .medium)
            lbl.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(optionTapped(_:)))
            lbl.addGestureRecognizer(tap)
            lbl.accessibilityLabel = opt
            optionsStack.addArrangedSubview(lbl)
        }
    }

    private func clearOptionLabels() {
        optionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func expand() {
        selectedCircle.backgroundColor = iconImage != nil ? UIColor(white: 0.55, alpha: 1) : .white
        if iconImage == nil { selectedLabel.textColor = UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1) }

        // Phase 1: widen with no labels in the stack, so the 32 pt width never conflicts with label spacing.
        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut, animations: {
            self.widthConstraint.constant = self.expandedWidth
            self.layoutIfNeeded()
        }, completion: { _ in
            // Phase 2: build labels and fade them in inside the now-wide button.
            self.buildOptionLabels()
            self.optionsStack.alpha = 0
            self.optionsStack.isHidden = false
            UIView.animate(withDuration: 0.15) { self.optionsStack.alpha = 1 }
        })
    }

    func collapse() {
        selectedCircle.backgroundColor = .clear
        selectedLabel.textColor = .black

        // Phase 1: fade labels out while the button is still wide (no conflict).
        UIView.animate(withDuration: 0.15, animations: {
            self.optionsStack.alpha = 0
        }, completion: { _ in
            // Phase 2: remove labels first so the 32 pt width has no inner constraints to fight.
            self.optionsStack.isHidden = true
            self.clearOptionLabels()
            UIView.animate(withDuration: 0.15) {
                self.widthConstraint.constant = self.collapsedWidth
                self.layoutIfNeeded()
            }
        })
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func optionTapped(_ recognizer: UITapGestureRecognizer) {
        guard let label = recognizer.view as? UILabel, let text = label.accessibilityLabel else { return }
        onOptionSelected?(text)
    }
}

// MARK: - CircleToggleButton

final class CircleToggleButton: UIControl {

    var isOn: Bool = false { didSet { updateAppearance() } }
    var onTintColor: UIColor = .white
    var offTintColor: UIColor = UIColor(white: 0.44, alpha: 1)
    var iconImage: UIImage? { didSet { iconView.image = iconImage } }

    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        layer.cornerRadius = 16
        clipsToBounds = true
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = isOn ? onTintColor : offTintColor
        iconView.tintColor = isOn ? UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1) : .white
    }

    @objc private func tapped() {
        sendActions(for: .touchUpInside)
    }
}
