import UIKit
import Photos

/// Read-only photo gallery — shows camera roll photos sorted newest first.
/// Tapping a photo presents a full-screen viewer.
public final class PhotoGalleryViewController: UIViewController {

    private var assets: PHFetchResult<PHAsset> = PHFetchResult()
    private let collectionView: UICollectionView

    private static let cellID = "PhotoCell"
    private let columns: CGFloat = 3

    public init() {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 1
        layout.minimumLineSpacing = 1
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        title = "Gallery"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"), style: .plain,
            target: self, action: #selector(closeTapped))
        navigationItem.leftBarButtonItem?.tintColor = .white
        setupCollectionView()
        loadAssets()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let side = (view.bounds.width - (columns - 1)) / columns
        if let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.itemSize = CGSize(width: side, height: side)
        }
    }

    // MARK: - Setup

    private func setupCollectionView() {
        collectionView.backgroundColor = .black
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoThumbnailCell.self, forCellWithReuseIdentifier: Self.cellID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Load photos

    private func loadAssets() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            fetchAssets()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
                DispatchQueue.main.async { self?.fetchAssets() }
            }
        default:
            showPermissionDenied()
        }
    }

    private func fetchAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d",
                                        PHAssetMediaType.image.rawValue,
                                        PHAssetMediaType.video.rawValue)
        assets = PHAsset.fetchAssets(with: options)
        collectionView.reloadData()
    }

    private func showPermissionDenied() {
        let label = UILabel()
        label.text = "Photo access required.\nGo to Settings > Privacy > Photos."
        label.textColor = .white; label.textAlignment = .center; label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    @objc private func closeTapped() { dismiss(animated: true) }
}

// MARK: - UICollectionViewDataSource / Delegate

extension PhotoGalleryViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: Self.cellID, for: indexPath) as! PhotoThumbnailCell
        let asset = assets[indexPath.item]
        cell.configure(with: asset)
        return cell
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let asset = assets[indexPath.item]
        let viewer = PhotoViewerViewController(asset: asset)
        viewer.modalPresentationStyle = .fullScreen
        present(viewer, animated: true)
    }
}

// MARK: - PhotoThumbnailCell

private final class PhotoThumbnailCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let videoIcon = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private var requestID: PHImageRequestID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        videoIcon.tintColor = .white
        videoIcon.contentMode = .scaleAspectFit
        videoIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(videoIcon)
        NSLayoutConstraint.activate([
            videoIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            videoIcon.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            videoIcon.widthAnchor.constraint(equalToConstant: 24),
            videoIcon.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with asset: PHAsset) {
        if let rid = requestID { PHImageManager.default().cancelImageRequest(rid) }
        videoIcon.isHidden = asset.mediaType != .video
        let size = CGSize(width: bounds.width * UIScreen.main.scale, height: bounds.height * UIScreen.main.scale)
        let opts = PHImageRequestOptions(); opts.isNetworkAccessAllowed = true; opts.deliveryMode = .opportunistic
        requestID = PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { [weak self] image, _ in
            self?.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}

// MARK: - PhotoViewerViewController

private final class PhotoViewerViewController: UIViewController {
    private let asset: PHAsset
    private let imageView = UIImageView()
    private let closeBtn = UIButton(type: .system)

    init(asset: PHAsset) {
        self.asset = asset
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            closeBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeBtn.widthAnchor.constraint(equalToConstant: 36),
            closeBtn.heightAnchor.constraint(equalToConstant: 36),
        ])

        let opts = PHImageRequestOptions(); opts.isNetworkAccessAllowed = true; opts.deliveryMode = .highQualityFormat
        PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                              contentMode: .aspectFit, options: opts) { [weak self] image, _ in
            self?.imageView.image = image
        }
    }

    @objc private func close() { dismiss(animated: true) }
}
