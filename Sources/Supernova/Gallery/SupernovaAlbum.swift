import Photos

/// Owns the dedicated Photos album that holds *only* captures made by this app.
///
/// We can't reliably filter the system library "by filename" — Photos doesn't allow a fetch
/// predicate on filename, renames imports, and reading `originalFilename` is a slow per-asset
/// resource lookup. A dedicated album is the simple, robust, fast equivalent: every capture is
/// tagged into it on save, and the gallery fetches only this album.
enum SupernovaAlbum {

    static let title = "D&V SuperNova"

    /// The album collection, if it already exists.
    static func existingCollection() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: options
        )
        return result.firstObject
    }

    /// Creates the asset from `fileURL` and adds it to the album (creating the album if needed),
    /// all in a single Photos change transaction.
    static func addAsset(from fileURL: URL, isVideo: Bool,
                         completion: @escaping (Bool, Error?) -> Void) {
        let existing = existingCollection()

        PHPhotoLibrary.shared().performChanges {
            let creation: PHAssetChangeRequest? = isVideo
                ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            guard let placeholder = creation?.placeholderForCreatedAsset else { return }

            if let album = existing {
                PHAssetCollectionChangeRequest(for: album)?
                    .addAssets([placeholder] as NSArray)
            } else {
                PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title)
                    .addAssets([placeholder] as NSArray)
            }
        } completionHandler: { success, error in
            completion(success, error)
        }
    }
}
