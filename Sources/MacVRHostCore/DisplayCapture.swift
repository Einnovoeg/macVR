import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DisplayCaptureError: Error {
    case unavailable(UInt32)
    case scaleFailed
    case encoderSetupFailed
    case encoderFinalizeFailed
}

extension DisplayCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable(let displayID):
            return "Display capture failed for display \(displayID). Screen Recording permission may be missing."
        case .scaleFailed:
            return "Unable to scale the captured display image."
        case .encoderSetupFailed:
            return "Unable to initialize the JPEG encoder for the captured display image."
        case .encoderFinalizeFailed:
            return "Unable to finalize the JPEG encoding for the captured display image."
        }
    }
}

public struct CapturedDisplayFrame: Sendable {
    public let displayID: UInt32
    public let width: Int
    public let height: Int
    public let jpegData: Data

    public init(displayID: UInt32, width: Int, height: Int, jpegData: Data) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.jpegData = jpegData
    }
}

/// Shared macOS display capture helper used by both the host's `display-jpeg`
/// stream mode and the native live-capture sender. Keeping capture and JPEG
/// encoding in one place prevents drift between the direct-streaming path and
/// the bridge-input path.
public enum DisplayCapture {
    public static func clampScale(_ scale: Double) -> Double {
        min(max(scale, 0.05), 1.0)
    }

    public static func captureJPEG(
        displayID: UInt32? = nil,
        jpegQuality: Int = 70,
        scale: Double = 1.0
    ) throws -> CapturedDisplayFrame {
        let resolvedDisplayID = displayID ?? UInt32(CGMainDisplayID())
        let quality = CGFloat(HostConfiguration.clampJPEGQuality(jpegQuality)) / 100.0
        let clampedScale = clampScale(scale)

        guard let image = CGDisplayCreateImage(CGDirectDisplayID(resolvedDisplayID)) else {
            throw DisplayCaptureError.unavailable(resolvedDisplayID)
        }

        let scaledImage = try makeScaledImage(image, scale: clampedScale)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw DisplayCaptureError.encoderSetupFailed
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, scaledImage, options)
        guard CGImageDestinationFinalize(destination) else {
            throw DisplayCaptureError.encoderFinalizeFailed
        }

        return CapturedDisplayFrame(
            displayID: resolvedDisplayID,
            width: scaledImage.width,
            height: scaledImage.height,
            jpegData: encoded as Data
        )
    }

    private static func makeScaledImage(_ image: CGImage, scale: Double) throws -> CGImage {
        guard scale < 0.999 else {
            return image
        }

        let targetWidth = max(Int((Double(image.width) * scale).rounded()), 1)
        let targetHeight = max(Int((Double(image.height) * scale).rounded()), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DisplayCaptureError.scaleFailed
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let scaled = context.makeImage() else {
            throw DisplayCaptureError.scaleFailed
        }
        return scaled
    }
}
