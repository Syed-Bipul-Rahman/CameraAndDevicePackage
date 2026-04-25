import UIKit

// MARK: - FilterControlPanelView

/// Glassmorphism panel matching the Flutter FilterControllerWidget.
/// Holds Smooth / Contrast / Plump / Milky / Blur sliders.
public final class FilterControlPanelView: UIView {

    // Callbacks — called on every slider change
    public var onSmoothChanged:    ((Float) -> Void)?
    public var onContrastChanged:  ((Float) -> Void)?
    public var onPlumpChanged:     ((Float) -> Void)?
    public var onMilkyChanged:     ((Float) -> Void)?
    public var onBlurChanged:      ((Float) -> Void)?
    public var onClose:            (() -> Void)?
    public var onFilterSettingsChanged: ((FilterSettings) -> Void)?

    // Current values (0-100 scale matching Flutter)
    public private(set) var smooth:   Float = 0
    public private(set) var contrast: Float = 50
    public private(set) var plump:    Float = 0
    public private(set) var milky:    Float = 0
    public private(set) var blur:     Float = 0

    private let blurBackground = UIVisualEffectView(effect: UIBlurEffect(style: .regular))

    private lazy var smoothRow    = makeSliderRow(label: "Smooth",   min: 0,    max: 100, value: smooth)
    private lazy var contrastRow  = makeSliderRow(label: "Contrast", min: 0,    max: 100, value: contrast)
    private lazy var plumpRow     = makeSliderRow(label: "Plump",    min: -100, max: 100, value: plump)
    private lazy var milkyRow     = makeSliderRow(label: "Milky",    min: 0,    max: 100, value: milky)
    private lazy var blurRow      = makeSliderRow(label: "Blur",     min: 0,    max: 100, value: blur)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    public func configure(smooth: Float, contrast: Float, plump: Float, milky: Float, blur: Float) {
        self.smooth   = smooth;   smoothRow.slider.value   = smooth
        self.contrast = contrast; contrastRow.slider.value = contrast
        self.plump    = plump;    plumpRow.slider.value    = plump
        self.milky    = milky;    milkyRow.slider.value    = milky
        self.blur     = blur;     blurRow.slider.value     = blur
        updateAllLabels()
    }

    // MARK: - Setup

    private func setup() {
        layer.cornerRadius = 16
        clipsToBounds = true

        // Blurred background
        blurBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurBackground)

        // Overlay tint
        let tint = UIView()
        tint.backgroundColor = UIColor(white: 0.15, alpha: 0.35)
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        // Header
        let titleLabel = UILabel()
        titleLabel.text = "Camera"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [titleLabel, closeBtn])
        header.axis = .horizontal
        header.distribution = .equalSpacing
        header.alignment = .center

        let divider = UIView()
        divider.backgroundColor = UIColor(white: 1, alpha: 0.24)
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        // Slider rows wired up
        smoothRow.slider.addTarget(self, action: #selector(smoothChanged(_:)), for: .valueChanged)
        contrastRow.slider.addTarget(self, action: #selector(contrastChanged(_:)), for: .valueChanged)
        plumpRow.slider.addTarget(self, action: #selector(plumpChanged(_:)), for: .valueChanged)
        milkyRow.slider.addTarget(self, action: #selector(milkyChanged(_:)), for: .valueChanged)
        blurRow.slider.addTarget(self, action: #selector(blurChanged(_:)), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [
            header, divider,
            smoothRow, contrastRow, plumpRow, milkyRow, blurRow
        ])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            blurBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurBackground.topAnchor.constraint(equalTo: topAnchor),
            blurBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        updateAllLabels()
    }

    // MARK: - Slider rows

    private func makeSliderRow(label: String, min: Float, max: Float, value: Float) -> SliderRow {
        let row = SliderRow()
        row.titleText = label
        row.slider.minimumValue = min
        row.slider.maximumValue = max
        row.slider.value = value
        row.slider.minimumTrackTintColor = .white
        row.slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.3)
        row.slider.thumbTintColor = .white
        return row
    }

    private func updateAllLabels() {
        smoothRow.valueLabel.text   = "\(Int(smooth))"
        contrastRow.valueLabel.text = "\(Int(contrast))"
        plumpRow.valueLabel.text    = "\(Int(plump))"
        milkyRow.valueLabel.text    = "\(Int(milky))"
        blurRow.valueLabel.text     = "\(Int(blur))"
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }

    @objc private func smoothChanged(_ slider: UISlider) {
        smooth = slider.value
        smoothRow.valueLabel.text = "\(Int(smooth))"
        onSmoothChanged?(smooth)
        notifySettings()
    }

    @objc private func contrastChanged(_ slider: UISlider) {
        contrast = slider.value
        contrastRow.valueLabel.text = "\(Int(contrast))"
        onContrastChanged?(contrast)
        notifySettings()
    }

    @objc private func plumpChanged(_ slider: UISlider) {
        plump = slider.value
        plumpRow.valueLabel.text = "\(Int(plump))"
        onPlumpChanged?(plump)
        notifySettings()
    }

    @objc private func milkyChanged(_ slider: UISlider) {
        milky = slider.value
        milkyRow.valueLabel.text = "\(Int(milky))"
        // Milky is exclusive — reset other filters
        if milky > 0 {
            smooth = 0; smoothRow.slider.value = 0; smoothRow.valueLabel.text = "0"
            contrast = 50; contrastRow.slider.value = 50; contrastRow.valueLabel.text = "50"
            plump = 0; plumpRow.slider.value = 0; plumpRow.valueLabel.text = "0"
        }
        onMilkyChanged?(milky)
        notifySettings()
    }

    @objc private func blurChanged(_ slider: UISlider) {
        blur = slider.value
        blurRow.valueLabel.text = "\(Int(blur))"
        onBlurChanged?(blur)
        notifySettings()
    }

    private func notifySettings() {
        var settings = FilterSettings()
        settings.faceOnlySmooth = smooth > 0
        settings.faceSmoothIntensity = smooth / 100
        settings.contrast = 0.5 + contrast / 100
        settings.lipPlump = plump != 0
        settings.lipPlumpIntensity = plump / 100
        settings.milkySkin = milky > 0
        settings.milkySkinIntensity = milky / 100
        settings.backgroundBlur = blur > 0
        settings.backgroundBlurIntensity = blur / 100
        onFilterSettingsChanged?(settings)
    }

    // MARK: - Animate in/out

    public func animateIn() {
        alpha = 0; transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.5) {
            self.alpha = 1; self.transform = .identity
        }
    }

    public func animateOut(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.18) {
            self.alpha = 0; self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        } completion: { _ in completion?() }
    }
}

// MARK: - SliderRow

final class SliderRow: UIView {

    var titleText: String = "" { didSet { titleLabel.text = titleText + ":" } }
    let valueLabel = UILabel()
    let slider = UISlider()

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 13)

        valueLabel.textColor = UIColor(white: 1, alpha: 0.7)
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.textAlignment = .right

        let labelRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        labelRow.axis = .horizontal
        labelRow.distribution = .equalSpacing

        let col = UIStackView(arrangedSubviews: [labelRow, slider])
        col.axis = .vertical
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)

        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.topAnchor.constraint(equalTo: topAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
