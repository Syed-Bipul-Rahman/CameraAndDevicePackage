import Foundation

public struct FilterSettings {
    public var smoothSkin: Bool = false
    public var warmTone: Bool = false
    public var smoothIntensity: Float = 0.5
    public var warmthIntensity: Float = 0.5
    public var faceOnlySmooth: Bool = false
    public var faceSmoothIntensity: Float = 0.5
    public var faceColorTintEnabled: Bool = false
    public var faceColorTintRed: Float = 0.0
    public var faceColorTintGreen: Float = 0.0
    public var faceColorTintBlue: Float = 0.0
    public var faceColorTintIntensity: Float = 0.3
    public var brightness: Float = 0.0
    public var contrast: Float = 1.5
    public var saturation: Float = 1.0
    public var lipPlump: Bool = false
    public var lipPlumpIntensity: Float = 0.0
    public var milkySkin: Bool = false
    public var milkySkinIntensity: Float = 0.0
    public var backgroundBlur: Bool = false
    public var backgroundBlurIntensity: Float = 0.0

    public init() {}
}

public enum FlashMode: String {
    case auto = "Auto"
    case on = "On"
    case off = "Off"
}

public enum AspectRatio: String {
    case square = "1:1"
    case widescreen = "16:9"
    case standard = "4:3"
}

public enum VideoQuality: String {
    case sd = "SD"
    case hd = "HD"
    case fullHD = "FHD"
    case uhd4K = "4K"
}
