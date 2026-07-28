import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

@main
struct ImageDataProbe {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatMac-ImageDataProbe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let imageData = try makePNG()
        let sourceURL = root.appendingPathComponent("input.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try imageData.write(to: sourceURL)

        let input = try ImageInputLoader.load(url: sourceURL)
        guard input.mimeType == "image/png", input.data == imageData else {
            throw ProbeError.inputLoadingFailed
        }

        let store = ImageFileStore(rootDirectory: root.appendingPathComponent("Media", isDirectory: true))
        let recordID = UUID()
        let stored = try store.store(
            imageData: imageData,
            preferredMimeType: "image/png",
            recordID: recordID
        )
        guard stored.relativePath == "Images/\(recordID.uuidString).png",
              store.fileExists(relativePath: stored.relativePath),
              (try Data(contentsOf: store.url(for: stored.relativePath))) == imageData else {
            throw ProbeError.outputStorageFailed
        }

        let exportURL = root.appendingPathComponent("export.png")
        try Data("old export".utf8).write(to: exportURL)
        try store.export(relativePath: stored.relativePath, to: exportURL)
        guard try Data(contentsOf: exportURL) == imageData else {
            throw ProbeError.exportFailed
        }
        do {
            try store.export(relativePath: stored.relativePath, to: store.url(for: stored.relativePath))
            throw ProbeError.sameExportAccepted
        } catch ImageFileStoreError.sameExportDestination {
            // Expected.
        }

        do {
            _ = try store.url(for: "../outside.png")
            throw ProbeError.pathTraversalAccepted
        } catch is ImageFileStoreError {
            // Expected.
        }

        let staged = try store.stageForDeletion(relativePath: stored.relativePath)
        guard !store.fileExists(relativePath: stored.relativePath),
              FileManager.default.fileExists(atPath: staged.stagingURL.path) else {
            throw ProbeError.stagingFailed
        }
        try store.reconcileStaging(liveRelativePaths: [stored.relativePath])
        guard store.fileExists(relativePath: stored.relativePath) else {
            throw ProbeError.restoreFailed
        }
        let stagedAgain = try store.stageForDeletion(relativePath: stored.relativePath)
        try store.reconcileStaging(liveRelativePaths: [])
        guard !store.fileExists(relativePath: stored.relativePath),
              !FileManager.default.fileExists(atPath: stagedAgain.stagingURL.path) else {
            throw ProbeError.discardFailed
        }

        do {
            _ = try ImageInputLoader.detectedMimeType(for: Data("not an image".utf8))
            throw ProbeError.invalidImageAccepted
        } catch is ImageFileStoreError {
            // Expected.
        }

        let schema = Schema([MediaRecord.self])
        let configuration = SwiftData.ModelConfiguration(
            "ImageDataProbe",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let record = MediaRecord(
            mediaKind: .image,
            operation: .generate,
            prompt: "Probe image",
            modelIdentifier: "probe-model",
            modelDisplayName: "Probe Model",
            localRelativePath: "Images/probe.png",
            resultSummary: "probe"
        )
        context.insert(record)
        try context.save()
        context.delete(record)
        try context.save()
        let records = try context.fetch(FetchDescriptor<MediaRecord>())
        guard records.isEmpty else {
            throw ProbeError.swiftDataLifecycleFailed
        }

        print("Image data probe passed")
    }

    private static func makePNG() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ProbeError.fixtureCreationFailed
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else {
            throw ProbeError.fixtureCreationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ProbeError.fixtureCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProbeError.fixtureCreationFailed
        }
        return data as Data
    }
}

private enum ProbeError: Error {
    case fixtureCreationFailed
    case inputLoadingFailed
    case outputStorageFailed
    case exportFailed
    case sameExportAccepted
    case pathTraversalAccepted
    case stagingFailed
    case restoreFailed
    case discardFailed
    case invalidImageAccepted
    case swiftDataLifecycleFailed
}
