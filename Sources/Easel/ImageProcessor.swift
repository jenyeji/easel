import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

enum EaselError: LocalizedError {
    case cannotOpen(String)
    case cannotRender
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "Couldn't open \(name). Is it a photo file?"
        case .cannotRender: return "Something went wrong while processing the photo."
        case .cannotWrite(let name): return "Couldn't save \(name). Check that the save folder exists and you can write to it."
        }
    }
}

/// Details written inside the saved JPGs (visible in Finder's Get Info, Lightroom, websites, etc.).
struct PhotoInfo {
    var title: String
    var artist: String
    var month: Int
    var year: Int
    var medium: String
    var size: String
    var recordID: String
}

struct ExportOptions {
    var fullQuality: Double
    var webLongEdge: Int
    var webQuality: Double
    var webSharpen: Bool
}

/// A photo loaded and ready to edit.
struct LoadedPhoto {
    let full: CIImage       // full resolution, used for saving
    let preview: CIImage    // smaller copy, used on screen
    let previewCG: CGImage
    let pixelSize: CGSize   // full-resolution size
}

enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq",
        "k25", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2",
        "rwl", "sr2", "srf", "srw", "x3f"
    ]
    static let otherExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "png"]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext) || otherExtensions.contains(ext)
    }

    static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: Loading

    static func load(_ url: URL, previewLongEdge: CGFloat = 3000) throws -> LoadedPhoto {
        var image: CIImage?
        if isRaw(url) {
            image = CIRAWFilter(imageURL: url)?.outputImage
        }
        if image == nil {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard var full = image else { throw EaselError.cannotOpen(url.lastPathComponent) }

        // Make sure the image starts at (0, 0) to keep the math simple.
        full = full.transformed(by: CGAffineTransform(translationX: -full.extent.minX, y: -full.extent.minY))

        let size = full.extent.size
        let longEdge = max(size.width, size.height)
        var preview = full
        if longEdge > previewLongEdge {
            preview = scaled(full, by: previewLongEdge / longEdge)
        }
        guard let cg = context.createCGImage(preview, from: preview.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw EaselError.cannotRender
        }
        return LoadedPhoto(full: full, preview: preview, previewCG: cg, pixelSize: size)
    }

    // MARK: Finding the painting automatically

    /// Looks for the biggest rectangle-like shape in the photo. Returns nil if none is found.
    static func detectPainting(in cgImage: CGImage) -> Quad? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumSize = 0.25
        request.minimumConfidence = 0.4
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 25

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let found = request.results?.first else { return nil }

        // Vision measures from the bottom-left; Easel measures from the top-left.
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return Quad(
            topLeft: flip(found.topLeft),
            topRight: flip(found.topRight),
            bottomRight: flip(found.bottomRight),
            bottomLeft: flip(found.bottomLeft)
        )
    }

    // MARK: Straightening

    /// Straightens the painting and stretches it to exactly the canvas proportions.
    static func straighten(_ image: CIImage, quad: Quad, aspectWidth: Double, aspectHeight: Double) throws -> CIImage {
        let extent = image.extent
        // Core Image measures from the bottom-left, so flip the vertical position.
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width,
                    y: extent.minY + (1 - p.y) * extent.height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomRight = point(quad.bottomRight)
        filter.bottomLeft = point(quad.bottomLeft)
        guard var output = filter.outputImage else { throw EaselError.cannotRender }
        output = output.transformed(by: CGAffineTransform(translationX: -output.extent.minX, y: -output.extent.minY))

        let w = output.extent.width
        let h = output.extent.height
        guard w > 1, h > 1, aspectWidth > 0, aspectHeight > 0 else { throw EaselError.cannotRender }

        // Keep about the same number of pixels, but use the exact canvas proportions.
        let ratio = CGFloat(aspectWidth / aspectHeight)
        let targetW = ((w * h * ratio).squareRoot()).rounded()
        let targetH = (targetW / ratio).rounded()

        let scaleY = targetH / h
        let scaleX = targetW / w
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = output.clampedToExtent()
        lanczos.scale = Float(scaleY)
        lanczos.aspectRatio = Float(scaleX / scaleY)
        guard let resized = lanczos.outputImage else { throw EaselError.cannotRender }

        return resized.cropped(to: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    }

    // MARK: Saving

    static func webVersion(of image: CIImage, longEdge: Int, sharpen: Bool) -> CIImage {
        let currentLong = max(image.extent.width, image.extent.height)
        let target = CGFloat(longEdge)
        guard target > 0, currentLong > target else { return image }
        var small = scaled(image, by: target / currentLong)
        let w = (image.extent.width * target / currentLong).rounded()
        let h = (image.extent.height * target / currentLong).rounded()
        if sharpen {
            let sharpenFilter = CIFilter.sharpenLuminance()
            sharpenFilter.inputImage = small.clampedToExtent()
            sharpenFilter.sharpness = 0.35
            if let out = sharpenFilter.outputImage { small = out }
        }
        return small.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    static func writeJPEG(_ image: CIImage, to url: URL, quality: Double, dpi: Int, info: PhotoInfo) throws {
        let rect = image.extent.integral
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB) else {
            throw EaselError.cannotRender
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EaselError.cannotWrite(url.lastPathComponent)
        }

        let year = String(info.year)
        let readableDate = PhotoEdit.readableDate(month: info.month, year: info.year)

        // e.g. "Sunset over Pescadero by Jane Doe, Oil, 11x14 in (September 2026). Record ID: JS-014"
        // Anything left empty (no artist, no medium…) is simply left out.
        let titleAndArtist: String = {
            switch (info.title.isEmpty, info.artist.isEmpty) {
            case (false, false): return "\(info.title) by \(info.artist)"
            case (false, true): return info.title
            case (true, false): return "By \(info.artist)"
            case (true, true): return ""
            }
        }()
        var description = [titleAndArtist, info.medium, info.size.isEmpty ? "" : "\(info.size) in"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        description += description.isEmpty ? readableDate : " (\(readableDate))"
        if !info.recordID.isEmpty { description += ". Record ID: \(info.recordID)" }

        var tiff: [String: Any] = [:]
        var iptc: [String: Any] = [:]
        if info.month > 0 {
            // This field needs a full day, so the 1st of the month is used.
            iptc[kCGImagePropertyIPTCDateCreated as String] = String(format: "%04d%02d01", info.year, info.month)
        }
        if !info.artist.isEmpty {
            tiff[kCGImagePropertyTIFFArtist as String] = info.artist
            iptc[kCGImagePropertyIPTCByline as String] = [info.artist]
            let copyright = "© \(year) \(info.artist)"
            tiff[kCGImagePropertyTIFFCopyright as String] = copyright
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
        }
        if !info.recordID.isEmpty {
            // Shows as "Job Identifier" in Lightroom and Bridge.
            iptc[kCGImagePropertyIPTCOriginalTransmissionReference as String] = info.recordID
        }
        if !info.title.isEmpty {
            iptc[kCGImagePropertyIPTCObjectName as String] = info.title
        }
        if !description.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription as String] = description
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = description
        }

        var properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: quality,
            kCGImagePropertyDPIWidth as String: dpi,
            kCGImagePropertyDPIHeight as String: dpi,
            kCGImagePropertyOrientation as String: 1
        ]
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary as String] = iptc }

        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EaselError.cannotWrite(url.lastPathComponent)
        }
    }

    /// Straightens the full-resolution photo and saves both JPGs.
    /// Returns the pixel size of the full-size image.
    static func export(photo: LoadedPhoto, quad: Quad, aspectWidth: Double, aspectHeight: Double,
                       options: ExportOptions, info: PhotoInfo,
                       fullURL: URL, webURL: URL) throws -> CGSize {
        let straight = try straighten(photo.full, quad: quad, aspectWidth: aspectWidth, aspectHeight: aspectHeight)
        try writeJPEG(straight, to: fullURL, quality: options.fullQuality, dpi: 300, info: info)

        let web = webVersion(of: straight, longEdge: options.webLongEdge, sharpen: options.webSharpen)
        try writeJPEG(web, to: webURL, quality: options.webQuality, dpi: 72, info: info)
        return straight.extent.size
    }

    /// A quick, screen-sized version of the result for the Before / After view.
    static func previewResult(photo: LoadedPhoto, quad: Quad, aspectWidth: Double, aspectHeight: Double) throws -> CGImage {
        let straight = try straighten(photo.preview, quad: quad, aspectWidth: aspectWidth, aspectHeight: aspectHeight)
        guard let cg = context.createCGImage(straight, from: straight.extent.integral, format: .RGBA8, colorSpace: sRGB) else {
            throw EaselError.cannotRender
        }
        return cg
    }

    /// Final pixel size the full image will have, without doing the heavy work.
    static func expectedSize(photo: LoadedPhoto, quad: Quad, aspectWidth: Double, aspectHeight: Double) -> CGSize {
        let s = photo.pixelSize
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = (a.x - b.x) * s.width, dy = (a.y - b.y) * s.height
            return (dx * dx + dy * dy).squareRoot()
        }
        let w = max(dist(quad.topLeft, quad.topRight), dist(quad.bottomLeft, quad.bottomRight))
        let h = max(dist(quad.topLeft, quad.bottomLeft), dist(quad.topRight, quad.bottomRight))
        let ratio = CGFloat(aspectWidth / aspectHeight)
        let targetW = (w * h * ratio).squareRoot().rounded()
        return CGSize(width: targetW, height: (targetW / ratio).rounded())
    }

    // MARK: Helpers

    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let out = filter.outputImage else { return image }
        let w = (image.extent.width * scale).rounded()
        let h = (image.extent.height * scale).rounded()
        return out.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
