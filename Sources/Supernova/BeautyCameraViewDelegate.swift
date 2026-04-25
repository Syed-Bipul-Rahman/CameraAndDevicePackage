import Foundation

public protocol BeautyCameraViewDelegate: AnyObject {
    func beautyCameraView(_ view: BeautyCameraView, didDetectFaces faces: [[String: Double]])
}
