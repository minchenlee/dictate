import Foundation

/// Where and how to send audio. Works with any OpenAI-compatible
/// `POST {baseURL}/audio/transcriptions` endpoint (OpenAI, OpenRouter, Groq, local servers).
public struct TranscriptionConfig: Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// ISO-639-1 code, or empty for auto-detect.
    public var language: String
    /// Optional context hint. Some providers ignore it.
    public var prompt: String

    public init(baseURL: String, apiKey: String, model: String, language: String = "", prompt: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.prompt = prompt
    }

    public var endpoint: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/audio/transcriptions"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case http(status: Int, message: String)
    case invalidResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: L("The API base URL is not valid")
        case .missingAPIKey: L("No API key is set")
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .invalidResponse: L("Could not read the transcription result")
        case .network(let message): L("Network error: %@", message)
        }
    }
}

/// multipart/form-data body builder.
public struct MultipartBody {
    public let boundary: String
    private var data = Data()

    public init(boundary: String = "dictate-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, mimeType: String, data fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(fileData)
        append("\r\n")
    }

    public func finalized() -> Data {
        var out = data
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private mutating func append(_ s: String) {
        data.append(Data(s.utf8))
    }
}

public enum Transcription {
    public static func makeRequest(
        _ config: TranscriptionConfig,
        audio: Data,
        filename: String = "audio.m4a",
        mimeType: String = "audio/mp4",
        boundary: String = "dictate-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard let url = config.endpoint else { throw TranscriptionError.invalidEndpoint }
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }

        var body = MultipartBody(boundary: boundary)
        body.addField("model", config.model.trimmingCharacters(in: .whitespacesAndNewlines))
        body.addField("response_format", "json")
        let language = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty { body.addField("language", language) }
        let prompt = config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { body.addField("prompt", prompt) }
        body.addFile("file", filename: filename, mimeType: mimeType, data: audio)

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Dictate", forHTTPHeaderField: "X-Title")
        request.httpBody = body.finalized()
        return request
    }

    /// Reads `{"text": "..."}`; maps `{"error": {"message": "..."}}` and non-2xx to errors.
    public static func parse(data: Data, status: Int) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw TranscriptionError.http(status: status, message: errorMessage(json: json, data: data))
        }
        if let text = json?["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if json?["error"] != nil {
            throw TranscriptionError.http(status: status, message: errorMessage(json: json, data: data))
        }
        throw TranscriptionError.invalidResponse
    }

    private static func errorMessage(json: [String: Any]?, data: Data) -> String {
        if let error = json?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json?["error"] as? String { return message }
        if let message = json?["message"] as? String { return message }
        let raw = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? L("(empty response)") : raw
    }

    public static func transcribe(
        _ config: TranscriptionConfig,
        audio: Data,
        filename: String = "audio.m4a",
        mimeType: String = "audio/mp4",
        session: URLSession = .shared
    ) async throws -> String {
        let request = try makeRequest(config, audio: audio, filename: filename, mimeType: mimeType)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        return try parse(data: data, status: http.statusCode)
    }
}
