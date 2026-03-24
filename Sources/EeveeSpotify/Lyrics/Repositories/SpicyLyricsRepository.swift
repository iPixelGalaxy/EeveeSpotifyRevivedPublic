import Foundation

class SpicyLyricsRepository: LyricsRepository {
    static let shared = SpicyLyricsRepository()

    private let apiUrl = "https://api.spicylyrics.org"
    // Fallback version — overwritten at runtime by fetchServerVersion()
    private var clientVersion = "100.10.67"
    private var versionFetched = false
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Dynamic version fetch

    /// Queries the server's ext_version endpoint and caches the result.
    /// Call once before the first lyrics fetch.
    private func fetchServerVersion() {
        guard !versionFetched else { return }
        versionFetched = true  // Set early to avoid concurrent fetches

        // Dedicated Codable types — ext_version returns `data` as a plain String
        struct VersionRequest: Encodable {
            struct Query: Encodable { let operation: String }
            struct Client: Encodable { let version: String }
            let queries: [Query]
            let client: Client
        }
        struct VersionResultContent: Decodable {
            let httpStatus: Int
            let data: String?
        }
        struct VersionQueryResult: Decodable {
            let operationId: String
            let result: VersionResultContent
        }
        struct VersionResponse: Decodable {
            let queries: [VersionQueryResult]
        }

        let body = VersionRequest(
            queries: [VersionRequest.Query(operation: "ext_version")],
            client: VersionRequest.Client(version: clientVersion)
        )

        guard let url = URL(string: "\(apiUrl)/query"),
              let bodyData = try? JSONEncoder().encode(body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        request.httpBody = bodyData

        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { [weak self] data, _, _ in
            defer { semaphore.signal() }
            guard let self = self,
                  let data = data,
                  let envelope = try? JSONDecoder().decode(VersionResponse.self, from: data),
                  let result = envelope.queries.first(where: { $0.operationId == "0" }),
                  result.result.httpStatus == 200,
                  let versionString = result.result.data,
                  !versionString.isEmpty else { return }
            self.clientVersion = versionString
            writeDebugLog("[SpicyLyrics] Server version: \(versionString)")
        }.resume()
        semaphore.wait()
    }

    // MARK: - Network

    private func fetchLyricsData(trackId: String) throws -> SpicyLyricsData {
        fetchServerVersion()

        let url = URL(string: "\(apiUrl)/query")!
        let hasToken = spotifyAccessToken != nil
        writeDebugLog("[SpicyLyrics] Fetching trackId=\(trackId) hasToken=\(hasToken) version=\(clientVersion)")

        let body = SpicyLyricsRequest(
            queries: [
                SpicyLyricsRequest.Query(
                    operation: "lyrics",
                    variables: SpicyLyricsRequest.Query.Variables(
                        id: trackId,
                        auth: "SpicyLyrics-WebAuth"
                    )
                )
            ],
            client: SpicyLyricsRequest.Client(version: clientVersion)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Version check header — the API rejects requests without this
        request.setValue(clientVersion, forHTTPHeaderField: "SpicyLyrics-Version")
        // Spotify OAuth token forwarded as the WebAuth credential
        if let token = spotifyAccessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "SpicyLyrics-WebAuth")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var networkError: Error?
        var httpStatus: Int = -1

        session.dataTask(with: request) { data, response, err in
            responseData = data
            networkError = err
            if let http = response as? HTTPURLResponse {
                httpStatus = http.statusCode
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let networkError = networkError {
            writeDebugLog("[SpicyLyrics] Network error: \(networkError)")
            throw networkError
        }
        guard let data = responseData else {
            writeDebugLog("[SpicyLyrics] No response data")
            throw LyricsError.decodingError
        }
        writeDebugLog("[SpicyLyrics] HTTP \(httpStatus), body \(data.count) bytes")

        let envelope: SpicyLyricsResponse
        do {
            envelope = try JSONDecoder().decode(SpicyLyricsResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[SpicyLyrics] Decode error: \(error) | raw: \(raw.prefix(300))")
            throw LyricsError.decodingError
        }

        guard let queryResult = envelope.queries.first(where: { $0.operationId == "0" }) else {
            writeDebugLog("[SpicyLyrics] No query result with operationId=0")
            throw LyricsError.decodingError
        }

        let apiStatus = queryResult.result.httpStatus
        writeDebugLog("[SpicyLyrics] API status=\(apiStatus)")
        switch apiStatus {
        case 200:
            guard let lyricsData = queryResult.result.data else {
                writeDebugLog("[SpicyLyrics] 200 but data is nil")
                throw LyricsError.decodingError
            }
            writeDebugLog("[SpicyLyrics] Got lyrics type=\(lyricsData.type)")
            return lyricsData
        case 404:
            writeDebugLog("[SpicyLyrics] 404 no such song")
            throw LyricsError.noSuchSong
        default:
            writeDebugLog("[SpicyLyrics] Unexpected status \(apiStatus)")
            throw LyricsError.unknownError
        }
    }

    // MARK: - Conversion helpers

    private func resolveText(
        plain: String?,
        romanized: String?,
        useRomanization: Bool,
        hasRomanization: Bool
    ) -> String {
        if useRomanization && hasRomanization, let r = romanized, !r.isEmpty { return r }
        return plain ?? ""
    }

    private func mapSyllableLines(
        _ content: [SpicyVocalGroup],
        useRomanization: Bool,
        hasRomanization: Bool
    ) -> [LyricsLineDto] {
        content
            .filter { $0.type == "Vocal" }
            .compactMap { group -> LyricsLineDto? in
                guard let lead = group.lead, !lead.syllables.isEmpty else { return nil }
                var text = ""
                for (i, s) in lead.syllables.enumerated() {
                    let part = resolveText(
                        plain: s.text,
                        romanized: s.romanizedText,
                        useRomanization: useRomanization,
                        hasRomanization: hasRomanization
                    )
                    text += (i > 0 && !s.isPartOfWord) ? " \(part)" : part
                }
                return LyricsLineDto(
                    content: text.lyricsNoteIfEmpty,
                    offsetMs: Int(lead.startTime * 1000)
                )
            }
    }

    private func mapLineLines(
        _ content: [SpicyVocalGroup],
        useRomanization: Bool,
        hasRomanization: Bool
    ) -> [LyricsLineDto] {
        content
            .filter { $0.type == "Vocal" }
            .compactMap { group -> LyricsLineDto? in
                guard let startTime = group.startTime else { return nil }
                let text = resolveText(
                    plain: group.text,
                    romanized: group.romanizedText,
                    useRomanization: useRomanization,
                    hasRomanization: hasRomanization
                )
                return LyricsLineDto(
                    content: text.lyricsNoteIfEmpty,
                    offsetMs: Int(startTime * 1000)
                )
            }
    }

    private func mapStaticLines(
        _ lines: [SpicyStaticLine],
        useRomanization: Bool,
        hasRomanization: Bool
    ) -> [LyricsLineDto] {
        lines.map { line in
            let text = resolveText(
                plain: line.text,
                romanized: line.romanizedText,
                useRomanization: useRomanization,
                hasRomanization: hasRomanization
            )
            return LyricsLineDto(content: text)
        }
    }

    // MARK: - LyricsRepository

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let data = try fetchLyricsData(trackId: query.spotifyTrackId)

        let useRomanization = options.romanization
        let hasRomanization = data.includesRomanization

        let romanizationStatus: LyricsRomanizationStatus = hasRomanization
            ? (useRomanization ? .romanized : .canBeRomanized)
            : .original

        let lines: [LyricsLineDto]
        let timeSynced: Bool

        switch data.type {
        case "Syllable":
            guard let content = data.content else { throw LyricsError.decodingError }
            lines = mapSyllableLines(
                content,
                useRomanization: useRomanization,
                hasRomanization: hasRomanization
            )
            timeSynced = true
        case "Line":
            guard let content = data.content else { throw LyricsError.decodingError }
            lines = mapLineLines(
                content,
                useRomanization: useRomanization,
                hasRomanization: hasRomanization
            )
            timeSynced = true
        case "Static":
            guard let staticLines = data.lines else { throw LyricsError.decodingError }
            lines = mapStaticLines(
                staticLines,
                useRomanization: useRomanization,
                hasRomanization: hasRomanization
            )
            timeSynced = false
        default:
            throw LyricsError.decodingError
        }

        if lines.isEmpty { throw LyricsError.noSuchSong }

        // Store syllable data for the custom overlay renderer
        spicyLyricsTrackId = query.spotifyTrackId
        switch data.type {
        case "Syllable":
            if let content = data.content {
                spicySyllableLines = content
                    .filter { $0.type == "Vocal" }
                    .compactMap { group -> SpicySyllableLine? in
                        guard let lead = group.lead, !lead.syllables.isEmpty else { return nil }
                        let words = lead.syllables.map { s in
                            SpicySyllableWord(
                                text: s.text,
                                startMs: Int(s.startTime * 1000),
                                endMs: Int(s.endTime * 1000),
                                isPartOfWord: s.isPartOfWord
                            )
                        }
                        return SpicySyllableLine(
                            startMs: Int(lead.startTime * 1000),
                            endMs: Int(lead.endTime * 1000),
                            words: words
                        )
                    }
                spicyLineSyncLines = nil
            }
        case "Line":
            if let content = data.content {
                spicyLineSyncLines = content
                    .filter { $0.type == "Vocal" }
                    .compactMap { group -> SpicyLineSyncLine? in
                        guard let startTime = group.startTime, let endTime = group.endTime,
                              let text = group.text else { return nil }
                        return SpicyLineSyncLine(
                            text: text,
                            startMs: Int(startTime * 1000),
                            endMs: Int(endTime * 1000)
                        )
                    }
                spicySyllableLines = nil
            }
        default:
            spicySyllableLines = nil
            spicyLineSyncLines = nil
        }

        return LyricsDto(lines: lines, timeSynced: timeSynced, romanization: romanizationStatus)
    }
}
