import Foundation

/// Deepgram Nova-3 pre-recorded / chunk STT (`POST /v1/listen`).
struct DeepgramRecognizer: SpeechRecognizing, LiveChunkASREngine, Sendable {
    var apiKey: String
    var model: String
    var vocabularyBias: String
    var timeout: TimeInterval

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.Speech.deepgramTimeoutSeconds
        config.timeoutIntervalForResource = Constants.Speech.deepgramTimeoutSeconds + 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    init(
        apiKey: String,
        model: String = Constants.Speech.defaultDeepgramModel,
        vocabularyBias: String = "",
        timeout: TimeInterval = Constants.Speech.deepgramTimeoutSeconds
    ) {
        self.apiKey = apiKey
        self.model = model
        self.vocabularyBias = vocabularyBias
        self.timeout = timeout
    }

    func transcribe(audioURL: URL) async throws -> SpeechTranscription {
        let data: Data
        do {
            data = try Data(contentsOf: audioURL)
        } catch {
            throw AppError.transcriptionFailed("Could not read audio file")
        }
        guard !data.isEmpty else { return SpeechTranscription(text: "") }
        return try await listen(
            body: data,
            contentType: "audio/wav",
            queryExtras: [:]
        )
    }

    /// Live-chunk path: 16 kHz mono float samples → linear16 PCM.
    func transcribe(samples: [Float], promptContext: String? = nil) async throws -> SpeechTranscription {
        guard !samples.isEmpty else { return SpeechTranscription(text: "") }
        let pcm = Self.floatToLinear16(samples)
        // promptContext is Whisper-specific; Deepgram uses keyterms from vocabulary bias.
        _ = promptContext
        return try await listen(
            body: pcm,
            contentType: "audio/raw",
            queryExtras: [
                "encoding": "linear16",
                "sample_rate": "16000",
                "channels": "1"
            ]
        )
    }

    // MARK: - Private

    private func listen(
        body: Data,
        contentType: String,
        queryExtras: [String: String]
    ) async throws -> SpeechTranscription {
        guard !apiKey.isEmpty else {
            throw AppError.notConfigured("Deepgram API Key Missing")
        }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        let model = DeepgramRequestSupport.sanitizedModel(self.model)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true")
        ]
        for (key, value) in queryExtras.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        for term in DeepgramRequestSupport.keyterms(from: vocabularyBias, model: model) {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items

        guard let endpoint = components.url else {
            throw AppError.transcriptionFailed("Invalid Deepgram endpoint")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = body

        DiagnosticLog.write("deepgram request model=\(model) bytes=\(body.count)")

        return try await AppLogger.measure("Deepgram.listen", logger: AppLogger.speech) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw AppError.transcriptionFailed("Deepgram timed out")
            } catch {
                throw AppError.transcriptionFailed("Deepgram unreachable")
            }

            guard let http = response as? HTTPURLResponse else {
                throw AppError.transcriptionFailed("Invalid Deepgram response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
                DiagnosticLog.write("deepgram HTTP \(http.statusCode) \(snippet)")
                throw AppError.transcriptionFailed("Deepgram HTTP \(http.statusCode)")
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let results = json["results"] as? [String: Any],
                let channels = results["channels"] as? [[String: Any]],
                let alternatives = channels.first?["alternatives"] as? [[String: Any]],
                let best = alternatives.first,
                let transcript = best["transcript"] as? String
            else {
                throw AppError.transcriptionFailed("Malformed Deepgram payload")
            }

            let confidence = best["confidence"] as? Double
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if let confidence {
                DiagnosticLog.write(
                    String(format: "deepgram ok chars=%d confidence=%.3f", text.count, confidence)
                )
            }
            return SpeechTranscription(text: text, confidence: confidence)
        }
    }

    private static func floatToLinear16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16((clamped * Float(Int16.max)).rounded())
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
