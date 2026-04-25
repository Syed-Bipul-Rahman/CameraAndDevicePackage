import UIKit

/// Full-screen light control screen with White and Effect mode tabs.
/// Mirrors the Flutter ControlScreen / control_screen.dart.
public final class LightControlViewController: UIViewController {

    public var bleService: BLEService?

    // MARK: - White mode state

    private var whiteDaylight: Double = 4600
    private var whiteIntensity: Double = 50

    // MARK: - Effect mode state

    private var selectedEffect: LightMode = .candle
    private var effectDaylight: Double = 4600
    private var effectIntensity: Double = 50
    private var effectFrequency: Double = 5

    // MARK: - UI

    private var tabBar: UISegmentedControl!
    private var whiteScrollView: UIScrollView!
    private var effectScrollView: UIScrollView!

    // White tab controls
    private let whiteDaylightLabel = UILabel()
    private let whiteIntensityLabel = UILabel()
    private let whiteDaylightSlider = UISlider()
    private let whiteIntensitySlider = UISlider()

    // Effect tab controls
    private let effectDaylightLabel = UILabel()
    private let effectIntensityLabel = UILabel()
    private let effectFrequencyLabel = UILabel()
    private let effectDaylightSlider = UISlider()
    private let effectIntensitySlider = UISlider()
    private let effectFrequencySlider = UISlider()
    private var effectChipStack: UIStackView!
    private var effectDaylightCard: UIView!

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        title = "Light Control"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "bluetooth.slash"), style: .plain, target: self, action: #selector(disconnectTapped)),
            UIBarButtonItem(image: UIImage(systemName: "power"), style: .plain, target: self, action: #selector(powerOffTapped)),
        ]
        setupUI()
        sendInitialMode()
    }

    // MARK: - Layout

    private func setupUI() {
        // Tab bar
        tabBar = UISegmentedControl(items: ["White", "Effect"])
        tabBar.selectedSegmentIndex = 0
        tabBar.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        whiteScrollView = makeScrollView()
        effectScrollView = makeScrollView()
        effectScrollView.isHidden = true
        view.addSubview(whiteScrollView)
        view.addSubview(effectScrollView)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            whiteScrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            whiteScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            whiteScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            whiteScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            effectScrollView.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            effectScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effectScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effectScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildWhiteTab()
        buildEffectTab()
    }

    private func makeScrollView() -> UIScrollView {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        return sv
    }

    // MARK: - White tab

    private func buildWhiteTab() {
        let daylightCard = buildDaylightCard(
            slider: whiteDaylightSlider, label: whiteDaylightLabel,
            min: 2700, max: 6500, value: whiteDaylight,
            presets: [("Warm", 2700, UIColor.orange), ("Neutral", 4600, UIColor.systemOrange), ("Cool", 5500, UIColor(red: 0.68, green: 0.85, blue: 1, alpha: 1)), ("Daylight", 6500, UIColor.systemBlue)],
            onChange: { [weak self] v in self?.whiteDaylight = v; self?.updateDaylightLabel(v, label: self?.whiteDaylightLabel) },
            onRelease: { [weak self] in self?.sendWhiteMode() }
        )

        let intensityCard = buildIntensityCard(
            slider: whiteIntensitySlider, label: whiteIntensityLabel, value: whiteIntensity,
            presets: [25, 50, 75, 100],
            onChange: { [weak self] v in self?.whiteIntensity = v; self?.whiteIntensityLabel.text = "\(Int(v))%" },
            onRelease: { [weak self] in self?.sendWhiteMode() }
        )

        let stack = UIStackView(arrangedSubviews: [daylightCard, intensityCard])
        stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = UIView(); content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        whiteScrollView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: whiteScrollView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: whiteScrollView.trailingAnchor),
            content.topAnchor.constraint(equalTo: whiteScrollView.topAnchor),
            content.bottomAnchor.constraint(equalTo: whiteScrollView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: whiteScrollView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Effect tab

    private func buildEffectTab() {
        // Effect chip grid
        let chipCard = makeCard()
        let chipHeader = makeCardHeader(icon: "sparkles", iconColor: .systemPurple, title: "Effect Mode")
        effectChipStack = UIStackView(); effectChipStack.axis = .horizontal; effectChipStack.flexibleHeight()
        let wrapGrid = WrapStackView(spacing: 8)
        wrapGrid.translatesAutoresizingMaskIntoConstraints = false
        for mode in LightMode.effectModes {
            let chip = makeChip(mode: mode)
            wrapGrid.addArrangedSubview(chip)
        }
        let chipStack = UIStackView(arrangedSubviews: [chipHeader, wrapGrid])
        chipStack.axis = .vertical; chipStack.spacing = 16
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipCard.addSubview(chipStack)
        NSLayoutConstraint.activate([chipStack.leadingAnchor.constraint(equalTo: chipCard.leadingAnchor, constant: 16), chipStack.trailingAnchor.constraint(equalTo: chipCard.trailingAnchor, constant: -16), chipStack.topAnchor.constraint(equalTo: chipCard.topAnchor, constant: 16), chipStack.bottomAnchor.constraint(equalTo: chipCard.bottomAnchor, constant: -16)])

        effectDaylightCard = buildDaylightCard(
            slider: effectDaylightSlider, label: effectDaylightLabel,
            min: 2700, max: 6500, value: effectDaylight, presets: [],
            onChange: { [weak self] v in self?.effectDaylight = v; self?.updateDaylightLabel(v, label: self?.effectDaylightLabel) },
            onRelease: { [weak self] in self?.sendEffectMode() }
        )

        let intensityCard = buildIntensityCard(
            slider: effectIntensitySlider, label: effectIntensityLabel, value: effectIntensity,
            presets: [25, 50, 75, 100],
            onChange: { [weak self] v in self?.effectIntensity = v; self?.effectIntensityLabel.text = "\(Int(v))%" },
            onRelease: { [weak self] in self?.sendEffectMode() }
        )

        let frequencyCard = buildFrequencyCard()

        let stack = UIStackView(arrangedSubviews: [chipCard, effectDaylightCard, intensityCard, frequencyCard])
        stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = UIView(); content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        effectScrollView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effectScrollView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effectScrollView.trailingAnchor),
            content.topAnchor.constraint(equalTo: effectScrollView.topAnchor),
            content.bottomAnchor.constraint(equalTo: effectScrollView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: effectScrollView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        updateEffectDaylightVisibility()
    }

    // MARK: - Card builders

    private func buildDaylightCard(slider: UISlider, label: UILabel, min: Double, max: Double, value: Double,
                                   presets: [(String, Double, UIColor)],
                                   onChange: @escaping (Double) -> Void,
                                   onRelease: @escaping () -> Void) -> UIView {
        let card = makeCard()
        let header = makeCardHeader(icon: "sun.haze", iconColor: .systemOrange, title: "Daylight")

        label.text = "\(Int(value))K"
        label.font = .boldSystemFont(ofSize: 13); label.textColor = .white
        label.backgroundColor = .systemOrange; label.layer.cornerRadius = 10; label.clipsToBounds = true
        label.textAlignment = .center
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let headerRow = UIStackView(arrangedSubviews: [header, UIView(), label])
        headerRow.axis = .horizontal; headerRow.alignment = .center

        let warmLbl = UILabel(); warmLbl.text = "2700K"; warmLbl.font = .systemFont(ofSize: 12); warmLbl.textColor = .systemOrange
        let coolLbl = UILabel(); coolLbl.text = "6500K"; coolLbl.font = .systemFont(ofSize: 12); coolLbl.textColor = .systemBlue

        slider.minimumValue = Float(min); slider.maximumValue = Float(max); slider.value = Float(value)
        slider.minimumTrackTintColor = .systemOrange; slider.thumbTintColor = .white
        slider.addAction(UIAction { _ in onChange(Double(slider.value)) }, for: .valueChanged)
        slider.addAction(UIAction { _ in onRelease() }, for: [.touchUpInside, .touchUpOutside])

        let sliderRow = UIStackView(arrangedSubviews: [warmLbl, slider, coolLbl])
        sliderRow.axis = .horizontal; sliderRow.spacing = 8; sliderRow.alignment = .center

        var rows: [UIView] = [headerRow, sliderRow]
        if !presets.isEmpty {
            let presetRow = UIStackView()
            presetRow.axis = .horizontal; presetRow.distribution = .fillEqually; presetRow.spacing = 8
            for (title, kelvin, color) in presets {
                let btn = UIButton(type: .system)
                btn.setTitle(title, for: .normal)
                btn.setTitleColor(.white, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 13)
                btn.backgroundColor = color; btn.layer.cornerRadius = 8
                btn.addAction(UIAction { [weak self] _ in
                    slider.value = Float(kelvin)
                    onChange(kelvin); onRelease()
                    self?.updateDaylightLabel(kelvin, label: label)
                }, for: .touchUpInside)
                presetRow.addArrangedSubview(btn)
                btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
            }
            rows.append(presetRow)
        }

        let col = UIStackView(arrangedSubviews: rows)
        col.axis = .vertical; col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col)
        NSLayoutConstraint.activate([col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), col.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)])
        return card
    }

    private func buildIntensityCard(slider: UISlider, label: UILabel, value: Double,
                                    presets: [Int],
                                    onChange: @escaping (Double) -> Void,
                                    onRelease: @escaping () -> Void) -> UIView {
        let card = makeCard()
        let header = makeCardHeader(icon: "sun.max.fill", iconColor: .systemYellow, title: "Intensity")

        label.text = "\(Int(value))%"
        label.font = .boldSystemFont(ofSize: 13); label.textColor = .black
        label.backgroundColor = .systemYellow; label.layer.cornerRadius = 10; label.clipsToBounds = true
        label.textAlignment = .center
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let headerRow = UIStackView(arrangedSubviews: [header, UIView(), label])
        headerRow.axis = .horizontal; headerRow.alignment = .center

        let lowIcon = UIImageView(image: UIImage(systemName: "sun.min")); lowIcon.tintColor = .label
        let highIcon = UIImageView(image: UIImage(systemName: "sun.max")); highIcon.tintColor = .label
        [lowIcon, highIcon].forEach { $0.contentMode = .scaleAspectFit; $0.widthAnchor.constraint(equalToConstant: 20).isActive = true }

        slider.minimumValue = 0; slider.maximumValue = 100; slider.value = Float(value)
        slider.minimumTrackTintColor = .systemYellow; slider.thumbTintColor = .white
        slider.addAction(UIAction { _ in onChange(Double(slider.value)) }, for: .valueChanged)
        slider.addAction(UIAction { _ in onRelease() }, for: [.touchUpInside, .touchUpOutside])

        let sliderRow = UIStackView(arrangedSubviews: [lowIcon, slider, highIcon])
        sliderRow.axis = .horizontal; sliderRow.spacing = 8; sliderRow.alignment = .center

        let presetRow = UIStackView(); presetRow.axis = .horizontal; presetRow.distribution = .fillEqually; presetRow.spacing = 8
        for pct in presets {
            let btn = UIButton(type: .system)
            btn.setTitle("\(pct)%", for: .normal)
            btn.setTitleColor(.black, for: .normal)
            btn.backgroundColor = .systemYellow; btn.layer.cornerRadius = 8
            btn.titleLabel?.font = .systemFont(ofSize: 13)
            btn.addAction(UIAction { [weak self] _ in
                slider.value = Float(pct); onChange(Double(pct)); onRelease()
                label.text = "\(pct)%"
            }, for: .touchUpInside)
            presetRow.addArrangedSubview(btn)
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }

        let col = UIStackView(arrangedSubviews: [headerRow, sliderRow, presetRow])
        col.axis = .vertical; col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col)
        NSLayoutConstraint.activate([col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), col.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)])
        return card
    }

    private func buildFrequencyCard() -> UIView {
        let card = makeCard()
        let header = makeCardHeader(icon: "gauge.medium", iconColor: .systemGreen, title: "Frequency")

        effectFrequencyLabel.text = "\(Int(effectFrequency))"
        effectFrequencyLabel.font = .boldSystemFont(ofSize: 13); effectFrequencyLabel.textColor = .white
        effectFrequencyLabel.backgroundColor = .systemGreen; effectFrequencyLabel.layer.cornerRadius = 10; effectFrequencyLabel.clipsToBounds = true
        effectFrequencyLabel.textAlignment = .center
        effectFrequencyLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let headerRow = UIStackView(arrangedSubviews: [header, UIView(), effectFrequencyLabel])
        headerRow.axis = .horizontal; headerRow.alignment = .center

        let minLbl = UILabel(); minLbl.text = "1"; minLbl.font = .boldSystemFont(ofSize: 14)
        let maxLbl = UILabel(); maxLbl.text = "10"; maxLbl.font = .boldSystemFont(ofSize: 14)
        effectFrequencySlider.minimumValue = 1; effectFrequencySlider.maximumValue = 10; effectFrequencySlider.value = Float(effectFrequency)
        effectFrequencySlider.minimumTrackTintColor = .systemGreen; effectFrequencySlider.thumbTintColor = .white
        effectFrequencySlider.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.effectFrequency = Double(self.effectFrequencySlider.value)
            self.effectFrequencyLabel.text = "\(Int(self.effectFrequency))"
        }, for: .valueChanged)
        effectFrequencySlider.addAction(UIAction { [weak self] _ in self?.sendEffectMode() }, for: [.touchUpInside, .touchUpOutside])

        let sliderRow = UIStackView(arrangedSubviews: [minLbl, effectFrequencySlider, maxLbl])
        sliderRow.axis = .horizontal; sliderRow.spacing = 8; sliderRow.alignment = .center

        let presetRow = UIStackView(); presetRow.axis = .horizontal; presetRow.distribution = .fillEqually; presetRow.spacing = 8
        for freq in [1, 3, 5, 7, 10] {
            let btn = UIButton(type: .system)
            btn.setTitle("\(freq)", for: .normal)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = .systemGreen; btn.layer.cornerRadius = 8
            btn.titleLabel?.font = .systemFont(ofSize: 13)
            btn.addAction(UIAction { [weak self] _ in
                guard let self = self else { return }
                self.effectFrequency = Double(freq)
                self.effectFrequencySlider.value = Float(freq)
                self.effectFrequencyLabel.text = "\(freq)"
                self.sendEffectMode()
            }, for: .touchUpInside)
            presetRow.addArrangedSubview(btn)
            btn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }

        let col = UIStackView(arrangedSubviews: [headerRow, sliderRow, presetRow])
        col.axis = .vertical; col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col)
        NSLayoutConstraint.activate([col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), col.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)])
        return card
    }

    // MARK: - Effect chip

    private func makeChip(mode: LightMode) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(mode.displayName, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 14)
        btn.layer.cornerRadius = 16; btn.layer.borderWidth = 1
        btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        updateChipStyle(btn, selected: mode == selectedEffect)
        btn.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.selectedEffect = mode
            self.updateAllChips()
            self.updateEffectDaylightVisibility()
            self.sendEffectMode()
        }, for: .touchUpInside)
        return btn
    }

    private func updateChipStyle(_ btn: UIButton, selected: Bool) {
        btn.backgroundColor = selected ? UIColor.systemPurple.withAlphaComponent(0.3) : .systemFill
        btn.setTitleColor(selected ? .systemPurple : .label, for: .normal)
        btn.layer.borderColor = selected ? UIColor.systemPurple.cgColor : UIColor.systemFill.cgColor
    }

    private func updateAllChips() {
        guard let wrapGrid = effectScrollView.subviews.first?.subviews.first?.subviews.first?.subviews.last as? WrapStackView else { return }
        for view in wrapGrid.arrangedSubviews {
            guard let btn = view as? UIButton,
                  let title = btn.title(for: .normal),
                  let mode = LightMode.effectModes.first(where: { $0.displayName == title }) else { continue }
            updateChipStyle(btn, selected: mode == selectedEffect)
        }
    }

    private func updateEffectDaylightVisibility() {
        effectDaylightCard?.isHidden = !selectedEffect.hasDaylight
    }

    // MARK: - Helpers

    private func makeCard() -> UIView {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 12
        return v
    }

    private func makeCardHeader(icon: String, iconColor: UIColor, title: String) -> UIView {
        let img = UIImageView(image: UIImage(systemName: icon)); img.tintColor = iconColor
        img.widthAnchor.constraint(equalToConstant: 22).isActive = true
        img.heightAnchor.constraint(equalToConstant: 22).isActive = true
        img.contentMode = .scaleAspectFit
        let lbl = UILabel(); lbl.text = title; lbl.font = .boldSystemFont(ofSize: 18)
        let row = UIStackView(arrangedSubviews: [img, lbl]); row.axis = .horizontal; row.spacing = 8; row.alignment = .center
        return row
    }

    private func updateDaylightLabel(_ kelvin: Double, label: UILabel?) {
        label?.text = "\(Int(kelvin))K"
    }

    // MARK: - BLE commands

    private func sendInitialMode() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendWhiteMode()
        }
    }

    private func sendWhiteMode() {
        bleService?.sendWhiteMode(daylightKelvin: Int(whiteDaylight), intensity: Int(whiteIntensity))
    }

    private func sendEffectMode() {
        bleService?.sendEffectMode(mode: selectedEffect, intensity: Int(effectIntensity),
                                   daylightKelvin: Int(effectDaylight), frequency: Int(effectFrequency))
    }

    // MARK: - Actions

    @objc private func tabChanged() {
        let isEffect = tabBar.selectedSegmentIndex == 1
        whiteScrollView.isHidden = isEffect
        effectScrollView.isHidden = !isEffect
        if isEffect { sendEffectMode() } else { sendWhiteMode() }
    }

    @objc private func powerOffTapped() {
        bleService?.sendWhiteModeOff()
    }

    @objc private func disconnectTapped() {
        bleService?.disconnect()
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - WrapStackView — horizontal wrapping layout

private final class WrapStackView: UIView {
    private(set) var arrangedSubviews: [UIView] = []
    private let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func addArrangedSubview(_ view: UIView) {
        arrangedSubviews.append(view)
        addSubview(view)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for view in arrangedSubviews {
            let size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x + size.width > bounds.width, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        let totalH = y + rowH
        if totalH != bounds.height {
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: CGSize {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        let w = superview?.bounds.width ?? UIScreen.main.bounds.width - 32
        for view in arrangedSubviews {
            let size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if x + size.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing; rowH = max(rowH, size.height)
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: y + rowH)
    }
}

private extension UIView {
    func flexibleHeight() { setContentHuggingPriority(.defaultLow, for: .vertical) }
}
