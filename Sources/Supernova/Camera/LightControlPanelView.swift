import UIKit

// MARK: - LightControlPanelView

/// Glassmorphism panel matching the Flutter LightControllerWidget.
/// Holds Temperature + Brightness sliders that send BLE commands on release.
public final class LightControlPanelView: UIView {

    public var bleService: BLEService?
    public var onClose: (() -> Void)?
    public var onTemperatureChanged: ((Double) -> Void)?
    public var onBrightnessChanged: ((Double) -> Void)?

    public private(set) var temperature: Double = 50
    public private(set) var brightness: Double = 50

    private let blurBackground = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let tempSlider = UISlider()
    private let brightSlider = UISlider()
    private let tempValueLabel = UILabel()
    private let brightValueLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    public func configure(temperature: Double, brightness: Double) {
        self.temperature = temperature
        self.brightness = brightness
        tempSlider.value = Float(temperature)
        brightSlider.value = Float(brightness)
        updateLabels()
    }

    // MARK: - Setup

    private func setup() {
        layer.cornerRadius = 16
        clipsToBounds = true
        widthAnchor.constraint(equalToConstant: 280).isActive = true

        blurBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurBackground)

        let tint = UIView()
        tint.backgroundColor = UIColor(white: 0.15, alpha: 0.35)
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        // Header
        let titleLabel = UILabel()
        titleLabel.text = "Light"
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

        // Temperature row
        let tempTitle = UILabel(); tempTitle.text = "Temperature:"; tempTitle.textColor = .white; tempTitle.font = .systemFont(ofSize: 13)
        tempValueLabel.textColor = UIColor(white: 1, alpha: 0.7); tempValueLabel.font = .systemFont(ofSize: 13); tempValueLabel.textAlignment = .right
        let tempLabelRow = UIStackView(arrangedSubviews: [tempTitle, tempValueLabel])
        tempLabelRow.axis = .horizontal; tempLabelRow.distribution = .equalSpacing

        styleSlider(tempSlider)
        tempSlider.minimumValue = 0; tempSlider.maximumValue = 100; tempSlider.value = Float(temperature)
        tempSlider.addTarget(self, action: #selector(tempChanged(_:)), for: .valueChanged)
        tempSlider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])

        let tempRow = UIStackView(arrangedSubviews: [tempLabelRow, tempSlider])
        tempRow.axis = .vertical; tempRow.spacing = 2

        // Brightness row
        let brightTitle = UILabel(); brightTitle.text = "Brightness:"; brightTitle.textColor = .white; brightTitle.font = .systemFont(ofSize: 13)
        brightValueLabel.textColor = UIColor(white: 1, alpha: 0.7); brightValueLabel.font = .systemFont(ofSize: 13); brightValueLabel.textAlignment = .right
        let brightLabelRow = UIStackView(arrangedSubviews: [brightTitle, brightValueLabel])
        brightLabelRow.axis = .horizontal; brightLabelRow.distribution = .equalSpacing

        styleSlider(brightSlider)
        brightSlider.minimumValue = 0; brightSlider.maximumValue = 100; brightSlider.value = Float(brightness)
        brightSlider.addTarget(self, action: #selector(brightChanged(_:)), for: .valueChanged)
        brightSlider.addTarget(self, action: #selector(sliderReleased), for: [.touchUpInside, .touchUpOutside])

        let brightRow = UIStackView(arrangedSubviews: [brightLabelRow, brightSlider])
        brightRow.axis = .vertical; brightRow.spacing = 2

        let stack = UIStackView(arrangedSubviews: [header, divider, tempRow, brightRow])
        stack.axis = .vertical; stack.spacing = 6
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

        updateLabels()
    }

    private func styleSlider(_ slider: UISlider) {
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.3)
        slider.thumbTintColor = .white
    }

    private func updateLabels() {
        tempValueLabel.text = "\(kelvin(from: temperature))K"
        brightValueLabel.text = "\(Int(brightness))"
    }

    // 0–100 → 2700K–6500K
    private func kelvin(from value: Double) -> Int {
        return Int((2700 + (value / 100) * (6500 - 2700)).rounded())
    }

    // MARK: - Actions

    @objc private func closeTapped() { onClose?() }

    @objc private func tempChanged(_ slider: UISlider) {
        temperature = Double(slider.value)
        tempValueLabel.text = "\(kelvin(from: temperature))K"
        onTemperatureChanged?(temperature)
    }

    @objc private func brightChanged(_ slider: UISlider) {
        brightness = Double(slider.value)
        brightValueLabel.text = "\(Int(brightness))"
        onBrightnessChanged?(brightness)
    }

    @objc private func sliderReleased() {
        sendLightCommand()
    }

    private func sendLightCommand() {
        let kelvinVal = kelvin(from: temperature)
        let intensityVal = Int(brightness)
        bleService?.sendWhiteMode(daylightKelvin: kelvinVal, intensity: intensityVal)
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
