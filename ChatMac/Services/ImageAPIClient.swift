import Foundation

struct ImageModelTarget: Sendable {
    let modelIdentifier: String
    let displayName: String
    let provider: AIProviderKind
    let apiKind: MediaAPIKind
    let baseURLString: String
    let keychainAccount: String

    init(model: AIModelConfiguration) {
        self.init(
            modelIdentifier: model.modelIdentifier,
            displayName: model.displayName,
            provider: model.provider,
            apiKind: model.mediaAPIKind,
            baseURLString: model.baseURLString,
            keychainAccount: model.keychainAccount
        )
    }

    init(
        modelIdentifier: String,
        displayName: String,
        provider: AIProviderKind,
        apiKind: MediaAPIKind,
        baseURLString: String,
        keychainAccount: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName
        self.provider = provider
        self.apiKind = apiKind
        self.baseURLString = baseURLString
        self.keychainAccount = keychainAccount
    }
}

enum ImageProcessingMode: String, CaseIterable, Sendable {
    case compatible
    case edit

    var displayName: String {
        switch self {
        case .compatible: "参考图处理"
        case .edit: "Images API 编辑"
        }
    }

    var mediaOperation: MediaOperation {
        switch self {
        case .compatible: .compatible
        case .edit: .edit
        }
    }
}

enum ImageToolRequest: Sendable {
    case generate(prompt: String)
    case process(
        prompt: String,
        inputs: [ImageInputFile],
        mode: ImageProcessingMode,
        mask: ImageInputFile?
    )

    var prompt: String {
        switch self {
        case .generate(let prompt): prompt
        case .process(let prompt, _, _, _): prompt
        }
    }

    var operation: MediaOperation {
        switch self {
        case .generate: .generate
        case .process(_, _, let mode, _): mode.mediaOperation
        }
    }
}

struct PersistedImageResult: Sendable {
    let localRelativePath: String
    let resultSummary: String
    let responseJSON: String?
}

struct ImageService {
    private let keychain: KeychainService
    private let client: ImageAPIClient
    private let fileStore: ImageFileStore

    init(
        keychain: KeychainService = KeychainService(),
        client: ImageAPIClient = ImageAPIClient(),
        fileStore: ImageFileStore = ImageFileStore()
    ) {
        self.keychain = keychain
        self.client = client
        self.fileStore = fileStore
    }

    func perform(
        _ request: ImageToolRequest,
        target: ImageModelTarget,
        recordID: UUID
    ) async throws -> PersistedImageResult {
        guard target.provider == .openAICompatible else {
            throw ImageAPIError.unsupportedProvider
        }

        let storedKey = try keychain.read(account: target.keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = storedKey.flatMap { $0.isEmpty ? nil : $0 }
        let response = try await client.perform(request, target: target, apiKey: apiKey)

        do {
            let storedFile = try fileStore.store(
                imageData: response.imageData,
                preferredMimeType: response.mimeType,
                recordID: recordID
            )
            let sizeText = ByteCountFormatter.string(
                fromByteCount: Int64(storedFile.byteCount),
                countStyle: .file
            )
            return PersistedImageResult(
                localRelativePath: storedFile.relativePath,
                resultSummary: "\(response.resultSummary) · \(sizeText)",
                responseJSON: response.responseJSON
            )
        } catch {
            throw error
        }
    }
}

struct ImageAPIClient {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let maximumResponseBytes: Int

    init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 300,
        maximumResponseBytes: Int = 32 * 1024 * 1024
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }

    func perform(
        _ request: ImageToolRequest,
        target: ImageModelTarget,
        apiKey: String?
    ) async throws -> ImageAPIResult {
        try validate(request)

        switch request {
        case .generate(let prompt):
            return try await generate(prompt: prompt, target: target, apiKey: apiKey)
        case .process(let prompt, let inputs, let mode, let mask):
            return try await process(
                prompt: prompt,
                inputs: inputs,
                mode: mode,
                mask: mask,
                target: target,
                apiKey: apiKey
            )
        }
    }

    private func generate(
        prompt: String,
        target: ImageModelTarget,
        apiKey: String?
    ) async throws -> ImageAPIResult {
        switch target.apiKind {
        case .imageGenerations:
            let endpoint = try endpointURL(from: target.baseURLString, appending: "images/generations")
            let body: [String: Any] = [
                "model": target.modelIdentifier,
                "prompt": prompt,
                "response_format": "b64_json",
            ]
            let response = try await sendJSON(
                body,
                to: endpoint,
                apiKey: apiKey
            )
            return try await decodeImageResponse(response, target: target)

        case .chatCompletions:
            let endpoint = try endpointURL(from: target.baseURLString, appending: "chat/completions")
            let body: [String: Any] = [
                "model": target.modelIdentifier,
                "messages": [["role": "user", "content": prompt]],
                "modalities": ["image", "text"],
                "stream": false,
            ]
            let response = try await sendJSON(
                body,
                to: endpoint,
                apiKey: apiKey
            )
            return try await decodeImageResponse(response, target: target)

        case .videoGenerations:
            throw ImageAPIError.unsupportedAPIKind
        }
    }

    private func process(
        prompt: String,
        inputs: [ImageInputFile],
        mode: ImageProcessingMode,
        mask: ImageInputFile?,
        target: ImageModelTarget,
        apiKey: String?
    ) async throws -> ImageAPIResult {
        switch mode {
        case .compatible:
            guard target.apiKind == .chatCompletions else {
                throw ImageAPIError.processingRequiresChatCompletions
            }
            let endpoint = try endpointURL(from: target.baseURLString, appending: "chat/completions")
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            content.append(contentsOf: inputs.map { input in
                [
                    "type": "image_url",
                    "image_url": ["url": dataURL(for: input)],
                ]
            })
            var body: [String: Any] = [
                "model": target.modelIdentifier,
                "messages": [["role": "user", "content": content]],
                "stream": false,
            ]
            body["modalities"] = ["image", "text"]
            let response = try await sendJSON(
                body,
                to: endpoint,
                apiKey: apiKey
            )
            return try await decodeImageResponse(response, target: target)

        case .edit:
            guard target.apiKind == .imageGenerations else {
                throw ImageAPIError.editRequiresImagesAPI
            }
            guard inputs.count == 1, let input = inputs.first else {
                throw ImageAPIError.editRequiresOneImage
            }
            let endpoint = try endpointURL(from: target.baseURLString, appending: "images/edits")
            let response = try await sendMultipartEdit(
                prompt: prompt,
                image: input,
                mask: mask,
                target: target,
                endpoint: endpoint,
                apiKey: apiKey
            )
            return try await decodeImageResponse(response, target: target)
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        to endpoint: URL,
        apiKey: String?
    ) async throws -> HTTPDataResponse {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ImageAPIError.invalidRequest
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, image/*", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try await send(request)
    }

    private func sendMultipartEdit(
        prompt: String,
        image: ImageInputFile,
        mask: ImageInputFile?,
        target: ImageModelTarget,
        endpoint: URL,
        apiKey: String?
    ) async throws -> HTTPDataResponse {
        let boundary = "ChatMac-\(UUID().uuidString)"
        var body = Data()
        appendFormField("model", value: target.modelIdentifier, boundary: boundary, to: &body)
        appendFormField("prompt", value: prompt, boundary: boundary, to: &body)
        appendFormField("response_format", value: "b64_json", boundary: boundary, to: &body)
        appendFileField("image", file: image, boundary: boundary, to: &body)
        if let mask {
            appendFileField("mask", file: mask, boundary: boundary, to: &body)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, image/*", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, to: &request)
        request.httpBody = body
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> HTTPDataResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ImageAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageAPIError.invalidResponse
        }
        if httpResponse.expectedContentLength > Int64(maximumResponseBytes) {
            throw ImageAPIError.responseTooLarge(maximumResponseBytes)
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(httpResponse.expectedContentLength), maximumResponseBytes))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw ImageAPIError.responseTooLarge(maximumResponseBytes)
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ImageAPIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ImageAPIError.network(error.localizedDescription)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ImageAPIError.httpStatus(
                httpResponse.statusCode,
                errorMessage(from: data, fallbackStatusCode: httpResponse.statusCode)
            )
        }
        return HTTPDataResponse(data: data, response: httpResponse)
    }

    private func decodeImageResponse(
        _ response: HTTPDataResponse,
        target: ImageModelTarget
    ) async throws -> ImageAPIResult {
        if let contentType = mimeType(from: response.response), contentType.hasPrefix("image/") {
            _ = try ImageInputLoader.detectedMimeType(for: response.data)
            return ImageAPIResult(
                imageData: response.data,
                mimeType: contentType,
                resultSummary: target.displayName,
                responseJSON: nil
            )
        }

        let object = try jsonObject(from: response.data)
        guard let candidate = imageCandidate(in: object) else {
            throw ImageAPIError.missingImage
        }
        let resolved = try await resolveImage(candidate)
        let responseModel = (object as? [String: Any])?["model"] as? String
        return ImageAPIResult(
            imageData: resolved.data,
            mimeType: resolved.mimeType,
            resultSummary: responseModel?.isEmpty == false ? responseModel! : target.displayName,
            responseJSON: sanitizedJSONString(from: object)
        )
    }

    private func resolveImage(_ candidate: ImageCandidate) async throws -> ResolvedImage {
        switch candidate {
        case .base64(let value):
            guard let data = Data(base64Encoded: value), !data.isEmpty else {
                throw ImageAPIError.invalidImageData
            }
            let mimeType = try ImageInputLoader.detectedMimeType(for: data)
            return ResolvedImage(data: data, mimeType: mimeType)

        case .dataURL(let value):
            guard let data = dataFromDataURL(value), !data.isEmpty else {
                throw ImageAPIError.invalidImageData
            }
            let mimeType = try ImageInputLoader.detectedMimeType(for: data)
            return ResolvedImage(data: data, mimeType: mimeType)

        case .remoteURL(let url):
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = requestTimeout
            request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
            let response = try await send(request)
            let detectedMimeType = try ImageInputLoader.detectedMimeType(for: response.data)
            return ResolvedImage(
                data: response.data,
                mimeType: mimeType(from: response.response) ?? detectedMimeType
            )
        }
    }

    private func imageCandidate(in object: Any) -> ImageCandidate? {
        guard let response = object as? [String: Any] else { return nil }

        if let data = response["data"] as? [[String: Any]],
           let first = data.first {
            if let base64 = normalizedString(first["b64_json"]) {
                return .base64(base64)
            }
            if let candidate = candidate(from: first["url"]) {
                return candidate
            }
        }

        if let candidate = candidate(from: response["media_data_url"])
            ?? candidate(from: response["image_url"])
            ?? candidate(from: response["url"]) {
            return candidate
        }

        guard let choices = response["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }

        if let images = message["images"] as? [[String: Any]],
           let image = images.first,
           let candidate = candidate(from: image["url"])
                ?? candidate(from: image["image_url"]) {
            return candidate
        }

        if let contentParts = message["content"] as? [[String: Any]] {
            for part in contentParts {
                if let candidate = candidate(from: part["image_url"])
                    ?? candidate(from: part["url"]) {
                    return candidate
                }
            }
        }

        if let content = normalizedString(message["content"]) {
            return markdownOrDirectCandidate(from: content)
        }
        return nil
    }

    private func candidate(from value: Any?) -> ImageCandidate? {
        if let imageObject = value as? [String: Any],
           let url = normalizedString(imageObject["url"]) {
            return candidate(fromString: url)
        }
        if let string = normalizedString(value) {
            return candidate(fromString: string)
        }
        return nil
    }

    private func markdownOrDirectCandidate(from value: String) -> ImageCandidate? {
        if let direct = candidate(fromString: value) {
            return direct
        }
        let pattern = "!\\[[^\\]]*\\]\\(((?:data:image/|https?://)[^)]+)\\)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1,
              let urlRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return candidate(fromString: String(value[urlRange]))
    }

    private func candidate(fromString rawValue: String) -> ImageCandidate? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("data:image/") {
            return .dataURL(value)
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return .remoteURL(url)
    }

    private func dataURL(for file: ImageInputFile) -> String {
        "data:\(file.mimeType);base64,\(file.data.base64EncodedString())"
    }

    private func dataFromDataURL(_ value: String) -> Data? {
        guard let separator = value.range(of: ";base64,"),
              value.lowercased().hasPrefix("data:image/") else {
            return nil
        }
        return Data(base64Encoded: String(value[separator.upperBound...]))
    }

    private func endpointURL(from rawValue: String, appending endpointPath: String) throws -> URL {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: normalized),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            throw ImageAPIError.invalidBaseURL(rawValue)
        }

        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix(endpointPath) {
            return baseURL
        }
        return baseURL.appending(path: endpointPath)
    }

    private func validate(_ request: ImageToolRequest) throws {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw ImageAPIError.emptyPrompt
        }
        guard prompt.count <= 4_000 else {
            throw ImageAPIError.promptTooLong
        }

        if case .process(_, let inputs, let mode, let mask) = request {
            guard !inputs.isEmpty else {
                throw ImageAPIError.missingReferenceImage
            }
            guard inputs.count <= ImageInputLoader.maximumFileCount else {
                throw ImageAPIError.tooManyReferenceImages
            }
            if mode == .edit && inputs.count != 1 {
                throw ImageAPIError.editRequiresOneImage
            }
            if let mask, mask.data.isEmpty {
                throw ImageAPIError.invalidImageData
            }
        }
    }

    private func applyAuthorization(_ apiKey: String?, to request: inout URLRequest) {
        guard let apiKey,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func appendFormField(
        _ name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private func appendFileField(
        _ name: String,
        file: ImageInputFile,
        boundary: String,
        to body: inout Data
    ) {
        let fileName = file.fileName
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n".utf8))
    }

    private func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ImageAPIError.invalidPayload(error.localizedDescription)
        }
    }

    private func errorMessage(from data: Data, fallbackStatusCode: Int) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return plainTextError(from: data, fallbackStatusCode: fallbackStatusCode)
        }
        if let error = dictionary["error"] as? [String: Any],
           let message = normalizedString(error["message"]) {
            return message
        }
        if let message = normalizedString(dictionary["message"]) {
            return message
        }
        return plainTextError(from: data, fallbackStatusCode: fallbackStatusCode)
    }

    private func plainTextError(from data: Data, fallbackStatusCode: Int) -> String {
        if let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty,
           !value.hasPrefix("<") {
            return String(value.prefix(500))
        }
        return "图片请求失败，状态码 \(fallbackStatusCode)。"
    }

    private func mimeType(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    private func normalizedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func sanitizedJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let sanitized = sanitizeJSONValue(object, key: nil)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizeJSONValue(_ value: Any, key: String?) -> Any {
        let normalizedKey = key?.lowercased() ?? ""
        if normalizedKey == "b64_json"
            || normalizedKey == "media_data_url"
            || normalizedKey == "image_url"
            || normalizedKey.contains("url")
            || normalizedKey.contains("key")
            || normalizedKey.contains("token")
            || normalizedKey.contains("authorization")
            || normalizedKey.contains("secret")
            || normalizedKey.contains("password") {
            return "<omitted>"
        }
        if let string = value as? String,
           string.hasPrefix("data:") {
            return "<omitted>"
        }
        if let dictionary = value as? [String: Any] {
            var sanitized: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                sanitized[childKey] = sanitizeJSONValue(childValue, key: childKey)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0, key: key) }
        }
        return value
    }
}

struct ImageAPIResult: Sendable {
    let imageData: Data
    let mimeType: String?
    let resultSummary: String
    let responseJSON: String?
}

private struct HTTPDataResponse {
    let data: Data
    let response: HTTPURLResponse
}

private struct ResolvedImage {
    let data: Data
    let mimeType: String
}

private enum ImageCandidate {
    case base64(String)
    case dataURL(String)
    case remoteURL(URL)
}

enum ImageAPIError: LocalizedError {
    case unsupportedProvider
    case unsupportedAPIKind
    case editRequiresImagesAPI
    case editRequiresOneImage
    case emptyPrompt
    case promptTooLong
    case missingReferenceImage
    case tooManyReferenceImages
    case processingRequiresChatCompletions
    case invalidRequest
    case invalidBaseURL(String)
    case invalidResponse
    case invalidPayload(String)
    case missingImage
    case invalidImageData
    case responseTooLarge(Int)
    case network(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "图片工具仅支持 OpenAI 兼容模型。"
        case .unsupportedAPIKind:
            "当前模型接口不支持图片请求。"
        case .editRequiresImagesAPI:
            "局部编辑需要选择 Images API 图片模型。"
        case .editRequiresOneImage:
            "局部编辑只能使用一张原图。"
        case .emptyPrompt:
            "请先输入图片提示词。"
        case .promptTooLong:
            "图片提示词最多 4000 个字符。"
        case .missingReferenceImage:
            "请至少选择一张参考图。"
        case .tooManyReferenceImages:
            "一次最多使用 5 张参考图。"
        case .processingRequiresChatCompletions:
            "参考图处理需要选择 Chat Completions 图像模型。"
        case .invalidRequest:
            "无法构建图片请求。"
        case .invalidBaseURL(let value):
            "Base URL 无效：\(value)"
        case .invalidResponse:
            "图片服务返回了无效响应。"
        case .invalidPayload(let detail):
            "无法解析图片响应：\(detail)"
        case .missingImage:
            "图片服务没有返回可用的图片。"
        case .invalidImageData:
            "图片服务返回了无效的图片数据。"
        case .responseTooLarge(let maximumResponseBytes):
            "图片服务返回的数据超过 \(maximumResponseBytes / 1024 / 1024) MB 限制。"
        case .network(let detail):
            "无法连接图片服务：\(detail)"
        case .httpStatus(_, let message):
            message
        }
    }
}
