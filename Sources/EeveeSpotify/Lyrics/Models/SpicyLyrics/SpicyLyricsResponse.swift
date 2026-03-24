import Foundation

// MARK: - Request

struct SpicyLyricsRequest: Encodable {
    struct Query: Encodable {
        struct Variables: Encodable {
            let id: String
            let auth: String
        }
        let operation: String
        let variables: Variables
    }
    struct Client: Encodable {
        let version: String
    }
    let queries: [Query]
    let client: Client
}

// MARK: - Response Envelope

struct SpicyLyricsResponse: Decodable {
    let queries: [SpicyQueryResult]
}

struct SpicyQueryResult: Decodable {
    let operationId: String
    let operation: String
    let result: SpicyQueryResultContent
}

struct SpicyQueryResultContent: Decodable {
    let httpStatus: Int
    let data: SpicyLyricsData?
}

// MARK: - Lyrics Data (top-level payload)

struct SpicyLyricsData: Decodable {
    let type: String                    // "Syllable", "Line", or "Static"
    let content: [SpicyVocalGroup]?     // Syllable and Line types
    let lines: [SpicyStaticLine]?       // Static type
    let language: String?
    let languageISO2: String?
    let includesRomanization: Bool

    enum CodingKeys: String, CodingKey {
        case type                 = "Type"
        case content              = "Content"
        case lines                = "Lines"
        case language             = "Language"
        case languageISO2         = "LanguageISO2"
        case includesRomanization = "IncludesRomanization"
    }
}

// MARK: - Vocal Group (used by both Syllable and Line content arrays)

struct SpicyVocalGroup: Decodable {
    let type: String            // "Vocal" or "Background"
    let lead: SpicyLead?        // Syllable type
    let text: String?           // Line type
    let romanizedText: String?  // Line type
    let startTime: Double?      // Line type (seconds)
    let endTime: Double?        // Line type (seconds)

    enum CodingKeys: String, CodingKey {
        case type          = "Type"
        case lead          = "Lead"
        case text          = "Text"
        case romanizedText = "RomanizedText"
        case startTime     = "StartTime"
        case endTime       = "EndTime"
    }
}

// MARK: - Syllable type nested structs

struct SpicyLead: Decodable {
    let startTime: Double
    let endTime: Double
    let syllables: [SpicySyllable]

    enum CodingKeys: String, CodingKey {
        case startTime = "StartTime"
        case endTime   = "EndTime"
        case syllables = "Syllables"
    }
}

struct SpicySyllable: Decodable {
    let text: String
    let romanizedText: String?
    let startTime: Double
    let endTime: Double
    let isPartOfWord: Bool

    enum CodingKeys: String, CodingKey {
        case text          = "Text"
        case romanizedText = "RomanizedText"
        case startTime     = "StartTime"
        case endTime       = "EndTime"
        case isPartOfWord  = "IsPartOfWord"
    }
}

// MARK: - Static type line

struct SpicyStaticLine: Decodable {
    let text: String
    let romanizedText: String?

    enum CodingKeys: String, CodingKey {
        case text          = "Text"
        case romanizedText = "RomanizedText"
    }
}
