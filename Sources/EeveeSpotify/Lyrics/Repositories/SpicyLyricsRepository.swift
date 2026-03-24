import Foundation

class SpicyLyricsRepository: LyricsRepository {
    static let shared = SpicyLyricsRepository()

    private let apiUrl = "https://api.spicylyrics.org"
    // Must satisfy the server-side version check
    private let clientVersion = "100.10.67"
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        session = URLSession(configuration: configuration)
    }

    // MARK: - Network

    private func fetchLyricsData(trackId: String) throws -> SpicyLyricsData {
        let url = URL(string: "\(apiUrl)/query")!

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

        session.dataTask(with: request) { data, _, err in
            responseData = data
            networkError = err
            semaphore.signal()
        }.resume()
        semaphore.wait()

        if let networkError = networkError { throw networkError }
        guard let data = responseData else { throw LyricsError.decodingError }

        let envelope: SpicyLyricsResponse
        do {
            envelope = try JSONDecoder().decode(SpicyLyricsResponse.self, from: data)
        } catch {
            throw LyricsError.decodingError
        }

        guard let queryResult = envelope.queries.first(where: { $0.operationId == "0" }) else {
            throw LyricsError.decodingError
        }

        switch queryResult.result.httpStatus {
        case 200:
            guard let lyricsData = queryResult.result.data else { throw LyricsError.decodingError }
            return lyricsData
        case 404:
            throw LyricsError.noSuchSong
        default:
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

        return LyricsDto(lines: lines, timeSynced: timeSynced, romanization: romanizationStatus)
    }
}
