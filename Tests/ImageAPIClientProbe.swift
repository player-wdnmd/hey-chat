import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageAPIClientProbe {
    static func main() async throws {
        let imageData = try makePNG()
        let imageBase64 = imageData.base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageMockURLProtocol.self]
        let client = ImageAPIClient(
            session: URLSession(configuration: configuration),
            requestTimeout: 5
        )

        ImageMockURLProtocol.install { request in
            guard request.url?.path == "/v1/images/generations" else {
                return .json(status: 404, object: ["message": "unexpected path"])
            }
            return .json(
                object: [
                    "model": "mock-images-model",
                    "api_key": "server-secret",
                    "data": [["b64_json": imageBase64]],
                ]
            )
        }
        let generated = try await client.perform(
            .generate(prompt: "a bright test image"),
            target: target(apiKind: .imageGenerations),
            apiKey: "test-secret"
        )
        guard generated.imageData == imageData,
              generated.mimeType == "image/png",
              generated.responseJSON?.contains("<omitted>") == true,
              generated.responseJSON?.contains(imageBase64) == false,
              generated.responseJSON?.contains("server-secret") == false,
              let imageRequest = ImageMockURLProtocol.lastRequest,
              imageRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
              let requestBody = ImageMockURLProtocol.lastRequestBody,
              let body = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
              body["response_format"] as? String == "b64_json" else {
            throw ProbeError.imageGenerationFailed
        }

        ImageMockURLProtocol.install { request in
            if request.url?.host == "media.example.test" {
                guard request.value(forHTTPHeaderField: "Authorization") == nil else {
                    return .json(status: 500, object: ["message": "download leaked authorization"])
                }
                return .binary(data: imageData, contentType: "image/png")
            }
            return .json(
                object: [
                    "data": [["url": "https://media.example.test/result.png"]],
                ]
            )
        }
        let remoteGenerated = try await client.perform(
            .generate(prompt: "remote output"),
            target: target(apiKind: .imageGenerations),
            apiKey: "test-secret"
        )
        guard remoteGenerated.imageData == imageData,
              ImageMockURLProtocol.requests.contains(where: { $0.url?.host == "media.example.test" }) else {
            throw ProbeError.remoteDownloadFailed
        }

        let input = ImageInputFile(fileName: "reference.png", mimeType: "image/png", data: imageData)
        ImageMockURLProtocol.install { request in
            guard request.url?.path == "/v1/chat/completions" else {
                return .json(status: 404, object: ["message": "unexpected path"])
            }
            return .json(
                object: [
                    "model": "mock-chat-image-model",
                    "choices": [[
                        "message": [
                            "images": [[
                                "image_url": ["url": "data:image/png;base64,\(imageBase64)"],
                            ]],
                        ],
                    ]],
                ]
            )
        }
        let processed = try await client.perform(
            .process(
                prompt: "turn this into an illustration",
                inputs: [input],
                mode: .compatible,
                mask: nil
            ),
            target: target(apiKind: .chatCompletions),
            apiKey: nil
        )
        guard processed.imageData == imageData,
              let compatibleRequest = ImageMockURLProtocol.lastRequest,
              compatibleRequest.value(forHTTPHeaderField: "Authorization") == nil,
              let compatibleBody = ImageMockURLProtocol.lastRequestBody,
              let compatibleObject = try JSONSerialization.jsonObject(with: compatibleBody) as? [String: Any],
              compatibleObject["modalities"] as? [String] == ["image", "text"] else {
            throw ProbeError.compatibleProcessingFailed
        }

        ImageMockURLProtocol.install { request in
            guard request.url?.path == "/v1/images/edits",
                  request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true,
                  let body = request.httpBody,
                  body.range(of: Data("name=\"image\"".utf8)) != nil,
                  body.range(of: Data("name=\"mask\"".utf8)) != nil else {
                return .json(status: 400, object: ["message": "invalid multipart body"])
            }
            return .json(object: ["data": [["b64_json": imageBase64]]])
        }
        let edited = try await client.perform(
            .process(
                prompt: "only change the sky",
                inputs: [input],
                mode: .edit,
                mask: input
            ),
            target: target(apiKind: .imageGenerations),
            apiKey: "test-secret"
        )
        guard edited.imageData == imageData else {
            throw ProbeError.editFailed
        }

        ImageMockURLProtocol.install { _ in
            .json(status: 429, object: ["error": ["message": "mock rate limit"]])
        }
        do {
            _ = try await client.perform(
                .generate(prompt: "should fail"),
                target: target(apiKind: .imageGenerations),
                apiKey: nil
            )
            throw ProbeError.expectedHTTPError
        } catch let error as ImageAPIError {
            guard case .httpStatus(429, let message) = error, message == "mock rate limit" else {
                throw ProbeError.unexpectedHTTPError
            }
        }

        let smallResponseClient = ImageAPIClient(
            session: URLSession(configuration: configuration),
            requestTimeout: 5,
            maximumResponseBytes: 1
        )
        ImageMockURLProtocol.install { _ in
            .json(object: ["data": [["b64_json": imageBase64]]])
        }
        do {
            _ = try await smallResponseClient.perform(
                .generate(prompt: "too large"),
                target: target(apiKind: .imageGenerations),
                apiKey: nil
            )
            throw ProbeError.expectedSizeLimitError
        } catch let error as ImageAPIError {
            guard case .responseTooLarge(1) = error else {
                throw ProbeError.unexpectedSizeLimitError
            }
        }

        print("Image API client probe passed")
    }

    private static func target(apiKind: MediaAPIKind) -> ImageModelTarget {
        ImageModelTarget(
            modelIdentifier: "mock-image-model",
            displayName: "Mock Image",
            provider: .openAICompatible,
            apiKind: apiKind,
            baseURLString: "https://api.example.test/v1",
            keychainAccount: "unused"
        )
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
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.85, alpha: 1))
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

private final class ImageMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> ImageMockResponse)?
    private(set) static var requests: [URLRequest] = []

    static var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    static var lastRequestBody: Data? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last?.httpBody
    }

    static func install(_ handler: @escaping (URLRequest) -> ImageMockResponse) {
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
        let response = Self.handler?(capturedRequest) ?? .json(status: 500, object: ["message": "missing mock handler"])
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

private struct ImageMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    static func json(status: Int = 200, object: Any) -> ImageMockResponse {
        ImageMockResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        )
    }

    static func binary(data: Data, contentType: String) -> ImageMockResponse {
        ImageMockResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            data: data
        )
    }
}

private enum ProbeError: Error {
    case fixtureCreationFailed
    case imageGenerationFailed
    case remoteDownloadFailed
    case compatibleProcessingFailed
    case editFailed
    case expectedHTTPError
    case unexpectedHTTPError
    case expectedSizeLimitError
    case unexpectedSizeLimitError
}
