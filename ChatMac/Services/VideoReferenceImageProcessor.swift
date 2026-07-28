import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoReferenceImageProcessor {
    static func jpegData(
        for image: ImageInputFile,
        resolution: VideoResolution,
        aspectRatio: VideoAspectRatio
    ) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithData(image.data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw VideoAPIError.invalidReferenceImage
        }

        let frameSize = frameSize(resolution: resolution, aspectRatio: aspectRatio)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(frameSize.width, frameSize.height),
        ]
        guard let sourceImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw VideoAPIError.invalidReferenceImage
        }

        guard let context = CGContext(
            data: nil,
            width: frameSize.width,
            height: frameSize.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw VideoAPIError.referenceImageProcessingFailed
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))
        context.interpolationQuality = .high

        let scale = max(
            CGFloat(frameSize.width) / CGFloat(sourceImage.width),
            CGFloat(frameSize.height) / CGFloat(sourceImage.height)
        )
        let scaledWidth = CGFloat(sourceImage.width) * scale
        let scaledHeight = CGFloat(sourceImage.height) * scale
        let destinationRect = CGRect(
            x: (CGFloat(frameSize.width) - scaledWidth) / 2,
            y: (CGFloat(frameSize.height) - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
        context.draw(sourceImage, in: destinationRect)

        guard let outputImage = context.makeImage() else {
            throw VideoAPIError.referenceImageProcessingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoAPIError.referenceImageProcessingFailed
        }
        let outputProperties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(destination, outputImage, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoAPIError.referenceImageProcessingFailed
        }
        return output as Data
    }

    static func frameSize(
        resolution: VideoResolution,
        aspectRatio: VideoAspectRatio
    ) -> (width: Int, height: Int) {
        switch (resolution, aspectRatio) {
        case (.p480, .landscape16x9): (854, 480)
        case (.p720, .landscape16x9): (1280, 720)
        case (.p1080, .landscape16x9): (1920, 1080)
        case (.p480, .portrait9x16): (480, 854)
        case (.p720, .portrait9x16): (720, 1280)
        case (.p1080, .portrait9x16): (1080, 1920)
        case (.p480, .square): (480, 480)
        case (.p720, .square): (720, 720)
        case (.p1080, .square): (1080, 1080)
        case (.p480, .landscape4x3): (640, 480)
        case (.p720, .landscape4x3): (960, 720)
        case (.p1080, .landscape4x3): (1440, 1080)
        case (.p480, .portrait3x4): (480, 640)
        case (.p720, .portrait3x4): (720, 960)
        case (.p1080, .portrait3x4): (1080, 1440)
        case (.p480, .landscape3x2): (720, 480)
        case (.p720, .landscape3x2): (1080, 720)
        case (.p1080, .landscape3x2): (1620, 1080)
        case (.p480, .portrait2x3): (480, 720)
        case (.p720, .portrait2x3): (720, 1080)
        case (.p1080, .portrait2x3): (1080, 1620)
        }
    }
}
