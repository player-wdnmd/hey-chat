import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct VideoAPIClientProbe {
    static func main() async throws {
        let videoData = makeMP4Fixture()
        let imageData = try makePNGFixture()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VideoMockURLProtocol.self]
        let client = VideoAPIClient(
            session: URLSession(configuration: configuration),
            requestTimeout: 5,
            pollingInterval: 0.01,
            pollingTimeout: 2,
            maximumMetadataResponseBytes: 4 * 1024,
            maximumVideoResponseBytes: 1024
        )

        try await verifyPollingAndRemoteDownload(
            client: client,
            videoData: videoData,
            imageData: imageData
        )
        try await verifyImmediateBase64(client: client, videoData: videoData)
        try await verifyContentEndpointFallback(client: client, videoData: videoData)
        try await verifyFailure(client: client)
        try await verifyCancellation(configuration: configuration)
        try await verifySizeLimit(configuration: configuration, videoData: videoData)

        print("Video API client probe passed")
    }

    private static func verifyPollingAndRemoteDownload(
        client: VideoAPIClient,
        videoData: Data,
        imageData: Data
    ) async throws {
        var pollCount = 0
        VideoMockURLProtocol.install { request in
            switch (request.httpMethod, request.url?.host, request.url?.path) {
            case ("POST", "api.example.test", "/v1/videos"):
                return .json(object: [
                    "id": "job-1",
                    "status": "queued",
                    "polling_url": "https://api.example.test/v1/videos/job-1/status",
                    "api_key": "server-secret",
                ])
            case ("GET", "api.example.test", "/v1/videos/job-1/status"):
                pollCount += 1
                if pollCount == 1 {
                    return .json(object: ["id": "job-1", "status": "processing"])
                }
                return .json(object: [
                    "id": "job-1",
                    "status": "completed",
                    "model": "mock-video-result",
                    "output": [
                        "result": [
                            "unsigned_urls": ["https://media.example.test/result.mp4"],
                        ],
                    ],
                ])
            case ("GET", "media.example.test", "/result.mp4"):
                guard request.value(forHTTPHeaderField: "Authorization") == nil else {
                    return .json(status: 500, object: ["message": "download leaked authorization"])
                }
                return .binary(data: videoData, contentType: "video/mp4")
            default:
                return .json(status: 404, object: ["message": "unexpected request"])
            }
        }

        let reference = ImageInputFile(
            fileName: "reference.png",
            mimeType: "image/png",
            data: imageData
        )
        let result = try await client.perform(
            VideoToolRequest(
                prompt: "A camera move through a bright landscape",
                duration: .seconds12,
                resolution: .p1080,
                aspectRatio: .portrait9x16,
                referenceImages: [reference]
            ),
            target: target(modelIdentifier: "openai/sora-2-pro"),
            apiKey: "test-secret"
        )
        let resultData = try materializedData(from: result.content)

        let requests = VideoMockURLProtocol.capturedRequests
        guard resultData == videoData,
              result.mimeType == "video/mp4",
              result.taskID == "job-1",
              result.resultSummary == "mock-video-result",
              result.responseJSON?.contains("<omitted>") == true,
              result.responseJSON?.contains("media.example.test") == false,
              requests.count == 4,
              requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
              requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
              requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
              requests[3].value(forHTTPHeaderField: "Authorization") == nil,
              let requestBody = requests[0].httpBody,
              let body = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              body["model"] as? String == "openai/sora-2-pro",
              body["duration"] as? Int == 12,
              body["resolution"] as? String == "1080p",
              body["aspect_ratio"] as? String == "9:16",
              let references = body["input_references"] as? [[String: Any]],
              let imageURL = references.first?["image_url"] as? [String: Any],
              let referenceDataURL = imageURL["url"] as? String,
              referenceDataURL.hasPrefix("data:image/jpeg;base64,"),
              let encodedReference = referenceDataURL.split(separator: ",", maxSplits: 1).last,
              let processedReference = Data(base64Encoded: String(encodedReference)),
              let dimensions = imageDimensions(processedReference),
              dimensions.0 == 1080,
              dimensions.1 == 1920 else {
            throw ProbeError.pollingOrDownloadFailed
        }
    }

    private static func verifyImmediateBase64(
        client: VideoAPIClient,
        videoData: Data
    ) async throws {
        VideoMockURLProtocol.install { request in
            guard request.url?.path == "/v1/videos" else {
                return .json(status: 404, object: ["message": "unexpected request"])
            }
            return .json(object: [
                "id": "job-base64",
                "status": "completed",
                "data": [[
                    "b64_json": videoData.base64EncodedString(),
                    "mime_type": "video/mp4",
                ]],
            ])
        }

        let result = try await client.perform(
            VideoToolRequest(prompt: "Immediate base64 video"),
            target: target(),
            apiKey: nil
        )
        let resultData = try materializedData(from: result.content)
        guard resultData == videoData,
              result.taskID == "job-base64",
              result.responseJSON?.contains(videoData.base64EncodedString()) == false else {
            throw ProbeError.base64ResolutionFailed
        }
    }

    private static func verifyContentEndpointFallback(
        client: VideoAPIClient,
        videoData: Data
    ) async throws {
        VideoMockURLProtocol.install { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/videos"):
                return .json(object: ["id": "job-content", "status": "completed"])
            case ("GET", "/v1/videos/job-content/content"):
                return .binary(data: videoData, contentType: "application/octet-stream")
            default:
                return .json(status: 404, object: ["message": "unexpected request"])
            }
        }

        let result = try await client.perform(
            VideoToolRequest(prompt: "Content endpoint fallback"),
            target: target(),
            apiKey: "test-secret"
        )
        let resultData = try materializedData(from: result.content)
        guard resultData == videoData,
              VideoMockURLProtocol.capturedRequests.last?.url?.path == "/v1/videos/job-content/content",
              VideoMockURLProtocol.capturedRequests.last?
                .value(forHTTPHeaderField: "Authorization") == "Bearer test-secret" else {
            throw ProbeError.contentEndpointFailed
        }
    }

    private static func verifyFailure(client: VideoAPIClient) async throws {
        VideoMockURLProtocol.install { _ in
            .json(object: [
                "id": "job-failed",
                "status": "failed",
                "error": ["message": "mock moderation failure"],
            ])
        }
        do {
            _ = try await client.perform(
                VideoToolRequest(prompt: "Expected failure"),
                target: target(),
                apiKey: nil
            )
            throw ProbeError.expectedFailure
        } catch let error as VideoAPIError {
            guard case .generationFailed("mock moderation failure") = error else {
                throw ProbeError.unexpectedFailure
            }
        }
    }

    private static func verifyCancellation(
        configuration: URLSessionConfiguration
    ) async throws {
        let client = VideoAPIClient(
            session: URLSession(configuration: configuration),
            requestTimeout: 5,
            pollingInterval: 5,
            pollingTimeout: 10,
            maximumVideoResponseBytes: 1024
        )
        VideoMockURLProtocol.install { _ in
            .json(object: ["id": "job-cancel", "status": "queued"])
        }

        let task = Task {
            try await client.perform(
                VideoToolRequest(prompt: "Cancel this task"),
                target: target(),
                apiKey: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            throw ProbeError.expectedCancellation
        } catch is CancellationError {
            // Expected.
        }
    }

    private static func verifySizeLimit(
        configuration: URLSessionConfiguration,
        videoData: Data
    ) async throws {
        let client = VideoAPIClient(
            session: URLSession(configuration: configuration),
            requestTimeout: 5,
            pollingInterval: 0.01,
            pollingTimeout: 1,
            maximumMetadataResponseBytes: 1024,
            maximumVideoResponseBytes: 8
        )
        VideoMockURLProtocol.install { request in
            if request.url?.host == "media.example.test" {
                return .binary(data: videoData, contentType: "video/mp4")
            }
            return .json(object: [
                "status": "completed",
                "url": "https://media.example.test/oversize.mp4",
            ])
        }
        do {
            _ = try await client.perform(
                VideoToolRequest(prompt: "Oversized video"),
                target: target(),
                apiKey: nil
            )
            throw ProbeError.expectedSizeLimit
        } catch let error as VideoAPIError {
            guard case .responseTooLarge(8) = error else {
                throw ProbeError.unexpectedSizeLimit
            }
        }
    }

    private static func target(
        modelIdentifier: String = "mock-video-model"
    ) -> VideoModelTarget {
        VideoModelTarget(
            modelIdentifier: modelIdentifier,
            displayName: "Mock Video",
            provider: .openAICompatible,
            baseURLString: "https://api.example.test/v1",
            keychainAccount: "unused"
        )
    }

    private static func makeMP4Fixture() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data("isom".utf8))
        data.append(Data([0x00, 0x00, 0x00, 0x00]))
        data.append(Data("isom".utf8))
        data.append(Data("mp42".utf8))
        return data
    }

    private static func materializedData(from content: VideoResultContent) throws -> Data {
        switch content {
        case .data(let data):
            return data
        case .temporaryFile(let url, _):
            defer {
                try? FileManager.default.removeItem(at: url)
            }
            return try Data(contentsOf: url)
        }
    }

    private static func imageDimensions(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return (width.intValue, height.intValue)
    }

    private static func makePNGFixture() throws -> Data {
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
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else {
            throw ProbeError.fixtureCreationFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
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
        return output as Data
    }
}

private final class VideoMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> VideoMockResponse)?
    private static var requests: [URLRequest] = []

    static var capturedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func install(_ handler: @escaping (URLRequest) -> VideoMockResponse) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("example.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var capturedRequest = request
        if capturedRequest.httpBody == nil, let bodyStream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.readBody(from: bodyStream)
        }

        Self.lock.lock()
        Self.requests.append(capturedRequest)
        let response = Self.handler?(capturedRequest)
            ?? .json(status: 500, object: ["message": "missing mock handler"])
        Self.lock.unlock()

        let urlResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private struct VideoMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    static func json(status: Int = 200, object: Any) -> VideoMockResponse {
        VideoMockResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        )
    }

    static func binary(data: Data, contentType: String) -> VideoMockResponse {
        VideoMockResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            data: data
        )
    }
}

private enum ProbeError: Error {
    case fixtureCreationFailed
    case pollingOrDownloadFailed
    case base64ResolutionFailed
    case contentEndpointFailed
    case expectedFailure
    case unexpectedFailure
    case expectedCancellation
    case expectedSizeLimit
    case unexpectedSizeLimit
}
