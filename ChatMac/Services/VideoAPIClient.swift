import Foundation

enum VideoResolution: String, CaseIterable, Identifiable, Sendable {
    case p480 = "480p"
    case p720 = "720p"
    case p1080 = "1080p"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

enum VideoAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case landscape16x9 = "16:9"
    case portrait9x16 = "9:16"
    case square = "1:1"
    case landscape4x3 = "4:3"
    case portrait3x4 = "3:4"
    case landscape3x2 = "3:2"
    case portrait2x3 = "2:3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .landscape16x9: "16:9 横屏"
        case .portrait9x16: "9:16 竖屏"
        case .square: "1:1 方形"
        case .landscape4x3: "4:3 横屏"
        case .portrait3x4: "3:4 竖屏"
        case .landscape3x2: "3:2 横屏"
        case .portrait2x3: "2:3 竖屏"
        }
    }
}

enum VideoDuration: Int, CaseIterable, Identifiable, Sendable {
    case seconds1 = 1
    case seconds2 = 2
    case seconds3 = 3
    case seconds4 = 4
    case seconds5 = 5
    case seconds6 = 6
    case seconds7 = 7
    case seconds8 = 8
    case seconds9 = 9
    case seconds10 = 10
    case seconds11 = 11
    case seconds12 = 12
    case seconds13 = 13
    case seconds14 = 14
    case seconds15 = 15
    case seconds16 = 16
    case seconds17 = 17
    case seconds18 = 18
    case seconds19 = 19
    case seconds20 = 20

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) 秒" }
}

struct VideoModelCapabilities: Sendable {
    let resolutions: [VideoResolution]
    let aspectRatios: [VideoAspectRatio]
    let durations: [VideoDuration]

    static func resolve(for modelIdentifier: String) -> VideoModelCapabilities {
        switch modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai/sora-2-pro", "sora-2-pro":
            VideoModelCapabilities(
                resolutions: [.p720, .p1080],
                aspectRatios: [.landscape16x9, .portrait9x16],
                durations: [.seconds4, .seconds8, .seconds12, .seconds16, .seconds20]
            )
        case "x-ai/grok-imagine-video", "grok-imagine-video":
            VideoModelCapabilities(
                resolutions: [.p720, .p480],
                aspectRatios: VideoAspectRatio.allCases,
                durations: Array(VideoDuration.allCases.prefix(15))
            )
        default:
            VideoModelCapabilities(
                resolutions: [.p720],
                aspectRatios: [.landscape16x9, .portrait9x16],
                durations: [.seconds4, .seconds8]
            )
        }
    }
}

struct VideoModelTarget: Sendable {
    let modelIdentifier: String
    let displayName: String
    let provider: AIProviderKind
    let baseURLString: String
    let keychainAccount: String

    init(
        modelIdentifier: String,
        displayName: String,
        provider: AIProviderKind,
        baseURLString: String,
        keychainAccount: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName
        self.provider = provider
        self.baseURLString = baseURLString
        self.keychainAccount = keychainAccount
    }
}

struct VideoToolRequest: Sendable {
    let prompt: String
    let duration: VideoDuration
    let resolution: VideoResolution
    let aspectRatio: VideoAspectRatio
    let referenceImages: [ImageInputFile]

    init(
        prompt: String,
        duration: VideoDuration = .seconds4,
        resolution: VideoResolution = .p720,
        aspectRatio: VideoAspectRatio = .landscape16x9,
        referenceImages: [ImageInputFile] = []
    ) {
        self.prompt = prompt
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.referenceImages = referenceImages
    }
}

struct VideoAPIResult: Sendable {
    let content: VideoResultContent
    let mimeType: String
    let resultSummary: String
    let responseJSON: String?
    let taskID: String?
}

enum VideoResultContent: Sendable {
    case data(Data)
    case temporaryFile(URL, byteCount: Int)

    var byteCount: Int {
        switch self {
        case .data(let data): data.count
        case .temporaryFile(_, let byteCount): byteCount
        }
    }
}

struct VideoAPIClient {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let pollingInterval: TimeInterval
    private let pollingTimeout: TimeInterval
    private let maximumMetadataResponseBytes: Int
    private let maximumVideoResponseBytes: Int

    init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 120,
        pollingInterval: TimeInterval = 5,
        pollingTimeout: TimeInterval = 15 * 60,
        maximumMetadataResponseBytes: Int = 2 * 1024 * 1024,
        maximumVideoResponseBytes: Int = VideoFileStore.defaultMaximumFileSize
    ) {
        self.session = session
        self.requestTimeout = max(1, requestTimeout)
        self.pollingInterval = max(0.01, pollingInterval)
        self.pollingTimeout = max(0.01, pollingTimeout)
        self.maximumMetadataResponseBytes = max(1, maximumMetadataResponseBytes)
        self.maximumVideoResponseBytes = max(1, maximumVideoResponseBytes)
    }

    func perform(
        _ request: VideoToolRequest,
        target: VideoModelTarget,
        apiKey: String?
    ) async throws -> VideoAPIResult {
        guard target.provider == .openAICompatible else {
            throw VideoAPIError.unsupportedProvider
        }
        try validate(request, target: target)

        let endpoint = try endpointURL(from: target.baseURLString, appending: "videos")
        let submittedResponse = try await sendJSON(
            requestBody(for: request, target: target),
            to: endpoint,
            apiKey: apiKey
        )
        if let direct = try directVideoResult(
            from: submittedResponse,
            target: target,
            taskID: nil,
            responseObject: nil
        ) {
            return direct
        }

        var current = try jsonObject(from: submittedResponse.data)
        try enforceMetadataSizeIfNeeded(current, responseBytes: submittedResponse.data.count)
        var taskID = taskIdentifier(in: current)
        var pollingLocation = pollingLocationString(in: current)
        let deadline = Date().addingTimeInterval(pollingTimeout)

        while true {
            try Task.checkCancellation()
            if isFailed(current) {
                throw VideoAPIError.generationFailed(failureMessage(in: current))
            }
            if let candidate = videoCandidate(in: current) {
                let resolved = try await resolveVideo(candidate)
                return result(
                    resolved,
                    target: target,
                    taskID: taskID,
                    responseObject: current
                )
            }
            if isCompleted(current) {
                guard let taskID else {
                    throw VideoAPIError.missingVideo
                }
                let contentResponse = try await fetchVideoContent(
                    taskID: taskID,
                    endpoint: endpoint,
                    apiKey: apiKey
                )
                if let direct = try directDownloadedVideoResult(
                    from: contentResponse,
                    target: target,
                    taskID: taskID,
                    responseObject: current
                ) {
                    return direct
                }
                let contentData = try downloadedMetadataData(from: contentResponse)
                let contentObject = try jsonObject(from: contentData)
                try enforceMetadataSizeIfNeeded(
                    contentObject,
                    responseBytes: contentData.count
                )
                guard let candidate = videoCandidate(in: contentObject) else {
                    throw VideoAPIError.missingVideo
                }
                let resolved = try await resolveVideo(candidate)
                return result(
                    resolved,
                    target: target,
                    taskID: taskID,
                    responseObject: current
                )
            }

            guard taskID != nil || pollingLocation != nil else {
                throw VideoAPIError.missingTaskIdentifier
            }
            guard Date() < deadline else {
                throw VideoAPIError.pollingTimedOut
            }

            let remaining = max(0.01, deadline.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(min(pollingInterval, remaining)))
            try Task.checkCancellation()

            let pollURL = try pollingURL(
                location: pollingLocation,
                taskID: taskID,
                endpoint: endpoint
            )
            let pollResponse = try await sendGET(
                pollURL,
                apiKey: shouldAuthorize(pollURL, relativeTo: endpoint) ? apiKey : nil,
                expectedKind: .metadataOrVideo
            )
            if let direct = try directVideoResult(
                from: pollResponse,
                target: target,
                taskID: taskID,
                responseObject: current
            ) {
                return direct
            }

            current = try jsonObject(from: pollResponse.data)
            try enforceMetadataSizeIfNeeded(current, responseBytes: pollResponse.data.count)
            taskID = taskIdentifier(in: current) ?? taskID
            pollingLocation = pollingLocationString(in: current) ?? pollingLocation
        }
    }

    private func requestBody(
        for request: VideoToolRequest,
        target: VideoModelTarget
    ) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": target.modelIdentifier,
            "prompt": request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "duration": request.duration.rawValue,
            "resolution": request.resolution.rawValue,
            "aspect_ratio": request.aspectRatio.rawValue,
        ]
        if !request.referenceImages.isEmpty {
            body["input_references"] = try request.referenceImages.map { image in
                let jpegData = try VideoReferenceImageProcessor.jpegData(
                    for: image,
                    resolution: request.resolution,
                    aspectRatio: request.aspectRatio
                )
                guard jpegData.count <= ImageInputLoader.maximumFileSize else {
                    throw VideoAPIError.referenceImageTooLarge(ImageInputLoader.maximumFileSize)
                }
                return [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
                    ],
                ]
            }
        }
        return body
    }

    private func sendJSON(
        _ object: [String: Any],
        to endpoint: URL,
        apiKey: String?
    ) async throws -> HTTPVideoResponse {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw VideoAPIError.invalidRequest
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, video/*", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try await send(request, expectedKind: .metadataOrVideo)
    }

    private func sendGET(
        _ url: URL,
        apiKey: String?,
        expectedKind: VideoResponseKind
    ) async throws -> HTTPVideoResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json, video/*,*/*", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, to: &request)
        return try await send(request, expectedKind: expectedKind)
    }

    private func downloadGET(
        _ url: URL,
        apiKey: String?,
        expectedKind: VideoResponseKind
    ) async throws -> DownloadedHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("video/*, application/json,*/*", forHTTPHeaderField: "Accept")
        applyAuthorization(apiKey, to: &request)
        return try await download(request, expectedKind: expectedKind)
    }

    private func send(
        _ request: URLRequest,
        expectedKind: VideoResponseKind
    ) async throws -> HTTPVideoResponse {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VideoAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoAPIError.invalidResponse
        }
        let maximumBytes = responseLimit(for: httpResponse, expectedKind: expectedKind)
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            throw VideoAPIError.responseTooLarge(displayedLimit(for: expectedKind))
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(httpResponse.expectedContentLength), maximumBytes))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw VideoAPIError.responseTooLarge(displayedLimit(for: expectedKind))
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoAPIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VideoAPIError.network(error.localizedDescription)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw VideoAPIError.httpStatus(
                httpResponse.statusCode,
                errorMessage(from: data, fallbackStatusCode: httpResponse.statusCode)
            )
        }
        return HTTPVideoResponse(data: data, response: httpResponse)
    }

    private func download(
        _ request: URLRequest,
        expectedKind: VideoResponseKind
    ) async throws -> DownloadedHTTPResponse {
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw VideoAPIError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoAPIError.invalidResponse
        }
        let maximumBytes = responseLimit(for: httpResponse, expectedKind: expectedKind)
        if httpResponse.expectedContentLength > Int64(maximumBytes) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoAPIError.responseTooLarge(displayedLimit(for: expectedKind))
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoAPIError.invalidResponse
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= maximumBytes else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoAPIError.responseTooLarge(displayedLimit(for: expectedKind))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorData = (try? fileData(
                at: temporaryURL,
                maximumBytes: maximumMetadataResponseBytes
            )) ?? Data()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw VideoAPIError.httpStatus(
                httpResponse.statusCode,
                errorMessage(from: errorData, fallbackStatusCode: httpResponse.statusCode)
            )
        }
        return DownloadedHTTPResponse(
            temporaryURL: temporaryURL,
            response: httpResponse,
            byteCount: byteCount
        )
    }

    private func fileData(at url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        return try handle.read(upToCount: maximumBytes + 1) ?? Data()
    }

    private func downloadedMetadataData(
        from response: DownloadedHTTPResponse
    ) throws -> Data {
        defer {
            try? FileManager.default.removeItem(at: response.temporaryURL)
        }
        let data = try fileData(
            at: response.temporaryURL,
            maximumBytes: maximumEncodedVideoBytes
        )
        guard data.count <= maximumEncodedVideoBytes else {
            throw VideoAPIError.responseTooLarge(maximumVideoResponseBytes)
        }
        return data
    }

    private func fetchVideoContent(
        taskID: String,
        endpoint: URL,
        apiKey: String?
    ) async throws -> DownloadedHTTPResponse {
        let contentURL = endpoint
            .appendingPathComponent(taskID)
            .appendingPathComponent("content")
        return try await downloadGET(
            contentURL,
            apiKey: apiKey,
            expectedKind: .metadataOrVideo
        )
    }

    private func directVideoResult(
        from response: HTTPVideoResponse,
        target: VideoModelTarget,
        taskID: String?,
        responseObject: Any?
    ) throws -> VideoAPIResult? {
        let contentType = mimeType(from: response.response)
        let isBinaryResponse = contentType?.hasPrefix("video/") == true
            || contentType == "application/octet-stream"
        guard isBinaryResponse else { return nil }

        let detectedMimeType: String
        do {
            detectedMimeType = try VideoDataInspector.detectedMimeType(
                for: response.data,
                preferredMimeType: contentType
            )
        } catch {
            throw VideoAPIError.invalidVideoData
        }
        guard response.data.count <= maximumVideoResponseBytes else {
            throw VideoAPIError.responseTooLarge(maximumVideoResponseBytes)
        }
        return VideoAPIResult(
            content: .data(response.data),
            mimeType: detectedMimeType,
            resultSummary: target.displayName,
            responseJSON: responseObject.flatMap(sanitizedJSONString),
            taskID: taskID
        )
    }

    private func directDownloadedVideoResult(
        from response: DownloadedHTTPResponse,
        target: VideoModelTarget,
        taskID: String?,
        responseObject: Any?
    ) throws -> VideoAPIResult? {
        let contentType = mimeType(from: response.response)
        if contentType == "application/json" || contentType?.hasSuffix("+json") == true {
            return nil
        }

        let detectedMimeType: String
        do {
            detectedMimeType = try VideoDataInspector.detectedMimeType(
                forFileAt: response.temporaryURL,
                preferredMimeType: contentType
            )
        } catch {
            let declaredBinary = contentType?.hasPrefix("video/") == true
                || contentType == "application/octet-stream"
            if declaredBinary {
                try? FileManager.default.removeItem(at: response.temporaryURL)
                throw VideoAPIError.invalidVideoData
            }
            return nil
        }
        return VideoAPIResult(
            content: .temporaryFile(response.temporaryURL, byteCount: response.byteCount),
            mimeType: detectedMimeType,
            resultSummary: target.displayName,
            responseJSON: responseObject.flatMap(sanitizedJSONString),
            taskID: taskID
        )
    }

    private func result(
        _ resolved: ResolvedVideo,
        target: VideoModelTarget,
        taskID: String?,
        responseObject: Any
    ) -> VideoAPIResult {
        let responseModel = (responseObject as? [String: Any])?["model"] as? String
        return VideoAPIResult(
            content: resolved.content,
            mimeType: resolved.mimeType,
            resultSummary: responseModel?.isEmpty == false ? responseModel! : target.displayName,
            responseJSON: sanitizedJSONString(responseObject),
            taskID: taskID
        )
    }

    private func resolveVideo(_ candidate: VideoCandidate) async throws -> ResolvedVideo {
        switch candidate {
        case .base64(let value, let preferredMimeType):
            guard value.utf8.count <= maximumEncodedVideoBytes,
                  let data = Data(base64Encoded: value),
                  !data.isEmpty else {
                if value.utf8.count > maximumEncodedVideoBytes {
                    throw VideoAPIError.responseTooLarge(maximumVideoResponseBytes)
                }
                throw VideoAPIError.invalidVideoData
            }
            return try validatedVideo(data, preferredMimeType: preferredMimeType)

        case .dataURL(let value):
            guard value.utf8.count <= maximumEncodedVideoBytes + 256,
                  let separator = value.range(of: ";base64,"),
                  let data = Data(base64Encoded: String(value[separator.upperBound...])),
                  !data.isEmpty else {
                if value.utf8.count > maximumEncodedVideoBytes + 256 {
                    throw VideoAPIError.responseTooLarge(maximumVideoResponseBytes)
                }
                throw VideoAPIError.invalidVideoData
            }
            let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<separator.lowerBound])
            return try validatedVideo(data, preferredMimeType: mimeType)

        case .remoteURL(let url):
            return try await downloadVideo(from: url, apiKey: nil)
        }
    }

    private func downloadVideo(
        from url: URL,
        apiKey: String?
    ) async throws -> ResolvedVideo {
        let response = try await downloadGET(url, apiKey: apiKey, expectedKind: .video)
        do {
            let mimeType = try VideoDataInspector.detectedMimeType(
                forFileAt: response.temporaryURL,
                preferredMimeType: mimeType(from: response.response)
            )
            return ResolvedVideo(
                content: .temporaryFile(response.temporaryURL, byteCount: response.byteCount),
                mimeType: mimeType
            )
        } catch let error as VideoAPIError {
            try? FileManager.default.removeItem(at: response.temporaryURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: response.temporaryURL)
            throw VideoAPIError.invalidVideoData
        }
    }

    private func validatedVideo(
        _ data: Data,
        preferredMimeType: String?
    ) throws -> ResolvedVideo {
        guard !data.isEmpty else {
            throw VideoAPIError.invalidVideoData
        }
        guard data.count <= maximumVideoResponseBytes else {
            throw VideoAPIError.responseTooLarge(maximumVideoResponseBytes)
        }
        do {
            let mimeType = try VideoDataInspector.detectedMimeType(
                for: data,
                preferredMimeType: preferredMimeType
            )
            return ResolvedVideo(content: .data(data), mimeType: mimeType)
        } catch {
            throw VideoAPIError.invalidVideoData
        }
    }

    private func videoCandidate(in value: Any) -> VideoCandidate? {
        if let string = normalizedString(value) {
            return candidate(fromString: string)
        }
        if let array = value as? [Any] {
            for item in array {
                if let candidate = videoCandidate(in: item) {
                    return candidate
                }
            }
            return nil
        }
        guard let dictionary = value as? [String: Any] else { return nil }

        let preferredMimeType = normalizedString(dictionary["mime_type"])
            ?? normalizedString(dictionary["content_type"])
        for key in ["b64_json", "video_base64", "base64"] {
            if let base64 = normalizedString(dictionary[key]) {
                if let direct = candidate(fromString: base64) {
                    return direct
                }
                return .base64(base64, preferredMimeType)
            }
        }
        for key in ["media_data_url", "video_url", "download_url", "output_url", "url"] {
            if let candidate = dictionary[key].flatMap(videoCandidate) {
                return candidate
            }
        }
        for key in ["unsigned_urls", "urls"] {
            if let candidate = dictionary[key].flatMap(videoCandidate) {
                return candidate
            }
        }
        for key in ["output", "result", "data", "video", "videos", "content"] {
            if let candidate = dictionary[key].flatMap(videoCandidate) {
                return candidate
            }
        }
        return nil
    }

    private func candidate(fromString rawValue: String) -> VideoCandidate? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("data:video/"),
           value.range(of: ";base64,") != nil {
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

    private func isCompleted(_ object: Any) -> Bool {
        guard let status = statusString(in: object)?.lowercased() else { return false }
        return ["completed", "succeeded", "success", "ready", "done"].contains(status)
    }

    private func isFailed(_ object: Any) -> Bool {
        guard let status = statusString(in: object)?.lowercased() else { return false }
        return ["failed", "error", "cancelled", "canceled", "rejected", "expired"].contains(status)
    }

    private func statusString(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let status = normalizedString(dictionary["status"])
            ?? normalizedString(dictionary["state"]) {
            return status
        }
        if let data = dictionary["data"] as? [String: Any] {
            return normalizedString(data["status"]) ?? normalizedString(data["state"])
        }
        return nil
    }

    private func taskIdentifier(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in ["id", "task_id", "video_id"] {
            if let value = normalizedScalarString(dictionary[key]) {
                return value
            }
        }
        if let data = dictionary["data"] as? [String: Any] {
            for key in ["id", "task_id", "video_id"] {
                if let value = normalizedScalarString(data[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private func pollingLocationString(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in ["polling_url", "status_url"] {
            if let value = normalizedString(dictionary[key]) {
                return value
            }
        }
        if let data = dictionary["data"] as? [String: Any] {
            return normalizedString(data["polling_url"])
                ?? normalizedString(data["status_url"])
        }
        return nil
    }

    private func failureMessage(in object: Any) -> String {
        guard let dictionary = object as? [String: Any] else {
            return "视频生成失败，请调整提示词后重试。"
        }
        if let error = dictionary["error"] as? [String: Any],
           let message = normalizedString(error["message"]) {
            return message
        }
        if let message = normalizedString(dictionary["error"])
            ?? normalizedString(dictionary["message"])
            ?? normalizedString(dictionary["detail"]) {
            return message
        }
        return "视频生成失败，请调整提示词后重试。"
    }

    private func pollingURL(
        location: String?,
        taskID: String?,
        endpoint: URL
    ) throws -> URL {
        if let location {
            if let absoluteURL = URL(string: location),
               let scheme = absoluteURL.scheme?.lowercased(),
               ["http", "https"].contains(scheme),
               absoluteURL.host != nil {
                return absoluteURL
            }
            if let relativeURL = URL(string: location, relativeTo: endpoint)?.absoluteURL,
               let scheme = relativeURL.scheme?.lowercased(),
               ["http", "https"].contains(scheme),
               relativeURL.host != nil {
                return relativeURL
            }
            throw VideoAPIError.invalidPollingURL
        }
        guard let taskID else {
            throw VideoAPIError.missingTaskIdentifier
        }
        return endpoint.appendingPathComponent(taskID)
    }

    private func shouldAuthorize(_ url: URL, relativeTo endpoint: URL) -> Bool {
        guard url.scheme?.lowercased() == endpoint.scheme?.lowercased(),
              url.host?.lowercased() == endpoint.host?.lowercased() else {
            return false
        }
        return effectivePort(for: url) == effectivePort(for: endpoint)
    }

    private func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func endpointURL(from rawValue: String, appending endpointPath: String) throws -> URL {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: normalized),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host != nil else {
            throw VideoAPIError.invalidBaseURL(rawValue)
        }

        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix(endpointPath) {
            return baseURL
        }
        return baseURL.appending(path: endpointPath)
    }

    private func validate(
        _ request: VideoToolRequest,
        target: VideoModelTarget
    ) throws {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw VideoAPIError.emptyPrompt
        }
        guard prompt.count <= 4_000 else {
            throw VideoAPIError.promptTooLong
        }
        guard request.referenceImages.count <= ImageInputLoader.maximumFileCount else {
            throw VideoAPIError.tooManyReferenceImages
        }
        for image in request.referenceImages {
            guard !image.data.isEmpty else {
                throw VideoAPIError.invalidReferenceImage
            }
            guard image.data.count <= ImageInputLoader.maximumFileSize else {
                throw VideoAPIError.referenceImageTooLarge(ImageInputLoader.maximumFileSize)
            }
            do {
                _ = try ImageInputLoader.detectedMimeType(
                    for: image.data,
                    requiringSupportedInputType: true
                )
            } catch {
                throw VideoAPIError.invalidReferenceImage
            }
        }

        let capabilities = VideoModelCapabilities.resolve(for: target.modelIdentifier)
        guard capabilities.resolutions.contains(request.resolution) else {
            throw VideoAPIError.unsupportedResolution(
                capabilities.resolutions.map(\.displayName).joined(separator: "、")
            )
        }
        guard capabilities.aspectRatios.contains(request.aspectRatio) else {
            throw VideoAPIError.unsupportedAspectRatio(
                capabilities.aspectRatios.map(\.displayName).joined(separator: "、")
            )
        }
        guard capabilities.durations.contains(request.duration) else {
            throw VideoAPIError.unsupportedDuration(
                capabilities.durations.map { String($0.rawValue) }.joined(separator: "、")
            )
        }
    }

    private func enforceMetadataSizeIfNeeded(
        _ object: Any,
        responseBytes: Int
    ) throws {
        if responseBytes > maximumMetadataResponseBytes,
           !containsEmbeddedVideo(in: object) {
            throw VideoAPIError.responseTooLarge(maximumMetadataResponseBytes)
        }
    }

    private func containsEmbeddedVideo(in object: Any) -> Bool {
        guard let candidate = videoCandidate(in: object) else { return false }
        switch candidate {
        case .base64, .dataURL:
            return true
        case .remoteURL:
            return false
        }
    }

    private var maximumEncodedVideoBytes: Int {
        let encoded = ((maximumVideoResponseBytes + 2) / 3) * 4
        return encoded > Int.max - maximumMetadataResponseBytes
            ? Int.max
            : encoded + maximumMetadataResponseBytes
    }

    private func responseLimit(
        for response: HTTPURLResponse,
        expectedKind: VideoResponseKind
    ) -> Int {
        switch expectedKind {
        case .metadata:
            return maximumMetadataResponseBytes
        case .video:
            return maximumVideoResponseBytes
        case .metadataOrVideo:
            if mimeType(from: response)?.hasPrefix("video/") == true
                || mimeType(from: response) == "application/octet-stream" {
                return maximumVideoResponseBytes
            }
            return maximumEncodedVideoBytes
        }
    }

    private func displayedLimit(for expectedKind: VideoResponseKind) -> Int {
        switch expectedKind {
        case .metadata:
            maximumMetadataResponseBytes
        case .video, .metadataOrVideo:
            maximumVideoResponseBytes
        }
    }

    private func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VideoAPIError.invalidPayload(error.localizedDescription)
        }
    }

    private func applyAuthorization(_ apiKey: String?, to request: inout URLRequest) {
        guard let apiKey,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        return "视频请求失败，状态码 \(fallbackStatusCode)。"
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

    private func normalizedScalarString(_ value: Any?) -> String? {
        if let string = normalizedString(value) {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func sanitizedJSONString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let sanitized = sanitizeJSONValue(object, key: nil)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func sanitizeJSONValue(_ value: Any, key: String?) -> Any {
        let normalizedKey = key?.lowercased() ?? ""
        if normalizedKey == "b64_json"
            || normalizedKey == "video_base64"
            || normalizedKey == "base64"
            || normalizedKey == "media_data_url"
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

private struct HTTPVideoResponse {
    let data: Data
    let response: HTTPURLResponse
}

private struct DownloadedHTTPResponse {
    let temporaryURL: URL
    let response: HTTPURLResponse
    let byteCount: Int
}

private struct ResolvedVideo {
    let content: VideoResultContent
    let mimeType: String
}

private enum VideoCandidate {
    case base64(String, String?)
    case dataURL(String)
    case remoteURL(URL)
}

private enum VideoResponseKind {
    case metadata
    case video
    case metadataOrVideo
}

enum VideoAPIError: LocalizedError {
    case unsupportedProvider
    case emptyPrompt
    case promptTooLong
    case tooManyReferenceImages
    case referenceImageTooLarge(Int)
    case invalidReferenceImage
    case referenceImageProcessingFailed
    case unsupportedResolution(String)
    case unsupportedAspectRatio(String)
    case unsupportedDuration(String)
    case invalidRequest
    case invalidBaseURL(String)
    case invalidPollingURL
    case invalidResponse
    case invalidPayload(String)
    case missingTaskIdentifier
    case generationFailed(String)
    case pollingTimedOut
    case missingVideo
    case invalidVideoData
    case responseTooLarge(Int)
    case network(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "视频工具仅支持 OpenAI 兼容模型。"
        case .emptyPrompt:
            "请先输入视频提示词。"
        case .promptTooLong:
            "视频提示词最多 4000 个字符。"
        case .tooManyReferenceImages:
            "一次最多使用 5 张视频参考图。"
        case .referenceImageTooLarge(let maximumFileSize):
            "单张视频参考图不能超过 \(maximumFileSize / 1024 / 1024) MB。"
        case .invalidReferenceImage:
            "视频参考图无效，仅支持 PNG、JPEG 或 WebP。"
        case .referenceImageProcessingFailed:
            "视频参考图尺寸处理失败，请更换图片后重试。"
        case .unsupportedResolution(let supportedValues):
            "当前模型支持的分辨率：\(supportedValues)。"
        case .unsupportedAspectRatio(let supportedValues):
            "当前模型支持的画面比例：\(supportedValues)。"
        case .unsupportedDuration(let supportedValues):
            "当前模型支持的视频时长：\(supportedValues) 秒。"
        case .invalidRequest:
            "无法构建视频请求。"
        case .invalidBaseURL(let value):
            "Base URL 无效：\(value)"
        case .invalidPollingURL:
            "视频服务返回了无效的轮询地址。"
        case .invalidResponse:
            "视频服务返回了无效响应。"
        case .invalidPayload(let detail):
            "无法解析视频响应：\(detail)"
        case .missingTaskIdentifier:
            "视频任务缺少 ID 或轮询地址，无法继续查询。"
        case .generationFailed(let message):
            message
        case .pollingTimedOut:
            "视频生成等待超时，请稍后重试。"
        case .missingVideo:
            "视频任务已完成，但响应中没有可用的视频。"
        case .invalidVideoData:
            "视频服务返回了无效的视频数据。"
        case .responseTooLarge(let maximumResponseBytes):
            "视频服务返回的数据超过 \(maximumResponseBytes / 1024 / 1024) MB 限制。"
        case .network(let detail):
            "无法连接视频服务：\(detail)"
        case .httpStatus(_, let message):
            message
        }
    }
}
