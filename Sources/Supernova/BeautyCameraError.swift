import Foundation

public enum BeautyCameraError: LocalizedError {
    case captureError(String)
    case notRecording
    case alreadyRecording
    case storageError(String)
    case writerError(String)
    case writeError(String)
    case saveError(String)
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .captureError(let msg): return "Capture error: \(msg)"
        case .notRecording: return "Not currently recording"
        case .alreadyRecording: return "Already recording"
        case .storageError(let msg): return "Storage error: \(msg)"
        case .writerError(let msg): return "Writer error: \(msg)"
        case .writeError(let msg): return "Write error: \(msg)"
        case .saveError(let msg): return "Save error: \(msg)"
        case .permissionDenied: return "Photo library access denied"
        }
    }
}
