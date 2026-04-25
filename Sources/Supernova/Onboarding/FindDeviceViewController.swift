import UIKit
import CoreBluetooth
import Combine

/// BLE device scan screen — shows ENSY devices and lets the user tap Connect.
public final class FindDeviceViewController: UIViewController {

    public var bleService: BLEService?
    public var onDeviceSelected: ((DiscoveredDevice) -> Void)?
    public var onBack: (() -> Void)?

    private var devices: [DiscoveredDevice] = []
    private var cancellables = Set<AnyCancellable>()
    private var isScanning = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let statusLabel = UILabel()
    private let radarView = RadarView()
    private let scanButton = UIButton(type: .system)

    private let darkGrey = UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 1)

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindBLEService()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bleService?.startScan()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        bleService?.stopScan()
    }

    // MARK: - UI

    private func setupUI() {
        // Gradient background
        let gradient = CAGradientLayer()
        gradient.colors = [darkGrey.cgColor, UIColor(red: 0.937, green: 0.937, blue: 0.937, alpha: 1).cgColor]
        gradient.locations = [0, 0.9]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        view.layer.insertSublayer(gradient, at: 0)

        // Nav bar appearance
        title = "Connect Device"
        navigationController?.navigationBar.tintColor = .white
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        navigationController?.navigationBar.isTranslucent = true
        navigationController?.navigationBar.backgroundColor = darkGrey
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"), style: .plain,
            target: self, action: #selector(backTapped))

        // Radar
        radarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(radarView)

        // Status label
        statusLabel.text = "Searching for nearby devices..."
        statusLabel.font = .systemFont(ofSize: 18, weight: .medium)
        statusLabel.textColor = darkGrey
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // Table
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(DeviceCell.self, forCellReuseIdentifier: "DeviceCell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        // Scan button (shown when idle with no results)
        scanButton.setTitle("Tap to Scan", for: .normal)
        scanButton.setTitleColor(darkGrey, for: .normal)
        scanButton.titleLabel?.font = .systemFont(ofSize: 16)
        scanButton.addTarget(self, action: #selector(scanTapped), for: .touchUpInside)
        scanButton.isHidden = true
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanButton)

        NSLayoutConstraint.activate([
            radarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            radarView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            radarView.widthAnchor.constraint(equalToConstant: 150),
            radarView.heightAnchor.constraint(equalToConstant: 150),

            statusLabel.topAnchor.constraint(equalTo: radarView.bottomAnchor, constant: 0),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scanButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scanButton.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
        ])
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.first(where: { $0 is CAGradientLayer })?.frame = view.bounds
    }

    // MARK: - BLE binding

    private func bindBLEService() {
        guard let ble = bleService else { return }

        ble.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                self?.devices = devices.sorted { $0.rssi > $1.rssi }
                self?.tableView.reloadData()
                self?.updateStatus()
            }.store(in: &cancellables)

        ble.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isScanning = state == .scanning
                self?.updateStatus()
            }.store(in: &cancellables)
    }

    private func updateStatus() {
        if isScanning {
            statusLabel.text = "Searching for nearby devices..."
            radarView.startAnimating()
            scanButton.isHidden = true
        } else if devices.isEmpty {
            statusLabel.text = "No devices found. Tap to scan again."
            radarView.stopAnimating()
            scanButton.isHidden = false
        } else {
            statusLabel.text = "Found \(devices.count) device(s)"
            radarView.stopAnimating()
            scanButton.isHidden = true
        }
    }

    @objc private func backTapped() {
        if let onBack { onBack() } else { navigationController?.popViewController(animated: true) }
    }
    @objc private func scanTapped() { bleService?.startScan() }
}

// MARK: - UITableViewDataSource / Delegate

extension FindDeviceViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { devices.count }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath) as! DeviceCell
        cell.configure(with: devices[indexPath.row]) { [weak self] device in
            self?.onDeviceSelected?(device)
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 80 }
}

// MARK: - DeviceCell

private final class DeviceCell: UITableViewCell {
    private let card = UIView()
    private let iconCircle = UIView()
    private let nameLabel = UILabel()
    private let rssiLabel = UILabel()
    private let connectBtn = UIButton(type: .system)
    private var onConnect: ((DiscoveredDevice) -> Void)?
    private var device: DiscoveredDevice?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none
        card.backgroundColor = UIColor(white: 1, alpha: 0.7)
        card.layer.cornerRadius = 20
        card.layer.borderColor = UIColor(red: 0.937, green: 0.937, blue: 0.937, alpha: 1).cgColor
        card.layer.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        iconCircle.backgroundColor = UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 1)
        iconCircle.layer.cornerRadius = 20
        iconCircle.translatesAutoresizingMaskIntoConstraints = false
        let icon = UIImageView(image: UIImage(systemName: "lightbulb"))
        icon.tintColor = .white; icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconCircle.addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
        card.addSubview(iconCircle)

        nameLabel.font = .boldSystemFont(ofSize: 15); nameLabel.textColor = .black
        rssiLabel.font = .systemFont(ofSize: 13); rssiLabel.textColor = .darkGray
        let textStack = UIStackView(arrangedSubviews: [nameLabel, rssiLabel]); textStack.axis = .vertical; textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(textStack)

        connectBtn.setTitle("Connect", for: .normal)
        connectBtn.setTitleColor(.white, for: .normal)
        connectBtn.backgroundColor = UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 1)
        connectBtn.layer.cornerRadius = 8
        connectBtn.titleLabel?.font = .systemFont(ofSize: 14)
        connectBtn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        connectBtn.translatesAutoresizingMaskIntoConstraints = false
        connectBtn.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)
        card.addSubview(connectBtn)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 7),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
            iconCircle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            iconCircle.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconCircle.widthAnchor.constraint(equalToConstant: 40),
            iconCircle.heightAnchor.constraint(equalToConstant: 40),
            textStack.leadingAnchor.constraint(equalTo: iconCircle.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            connectBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            connectBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: connectBtn.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with device: DiscoveredDevice, onConnect: @escaping (DiscoveredDevice) -> Void) {
        self.device = device; self.onConnect = onConnect
        nameLabel.text = device.name
        rssiLabel.text = "Signal: \(device.rssi) dBm"
    }

    @objc private func connectTapped() { if let d = device { onConnect?(d) } }
}

// MARK: - RadarView

private final class RadarView: UIView {
    private let iconView = UIImageView(image: UIImage(systemName: "bluetooth"))
    private var pulseLayer: CAShapeLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.937, green: 0.937, blue: 0.937, alpha: 1)
        layer.cornerRadius = 75
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.1; layer.shadowRadius = 20; layer.shadowOffset = .zero
        iconView.tintColor = UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 1)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([iconView.centerXAnchor.constraint(equalTo: centerXAnchor), iconView.centerYAnchor.constraint(equalTo: centerYAnchor), iconView.widthAnchor.constraint(equalToConstant: 50), iconView.heightAnchor.constraint(equalToConstant: 50)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        iconView.image = UIImage(systemName: "bluetooth.searching")
        let pulse = CAShapeLayer()
        pulse.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 10, dy: 10)).cgPath
        pulse.fillColor = UIColor(red: 0.294, green: 0.294, blue: 0.310, alpha: 0.15).cgColor
        layer.insertSublayer(pulse, at: 0)
        pulseLayer = pulse
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.8; anim.toValue = 1.1; anim.duration = 1; anim.repeatCount = .infinity; anim.autoreverses = true
        pulse.add(anim, forKey: "pulse")
    }

    func stopAnimating() {
        iconView.image = UIImage(systemName: "bluetooth")
        pulseLayer?.removeFromSuperlayer(); pulseLayer = nil
    }
}
