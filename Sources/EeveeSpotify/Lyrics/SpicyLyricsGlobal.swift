import Foundation

// MARK: - Syllable data model (populated from SpicyLyricsRepository)

struct SpicySyllableWord {
    let text: String
    let startMs: Int
    let endMs: Int
    let isPartOfWord: Bool  // true = no space before this syllable
}

struct SpicySyllableLine {
    let startMs: Int
    let endMs: Int
    let words: [SpicySyllableWord]

    var fullText: String {
        var result = ""
        for (i, word) in words.enumerated() {
            if i > 0 && !word.isPartOfWord { result += " " }
            result += word.text
        }
        return result
    }
}

// Line-synced fallback (used when type == "Line")
struct SpicyLineSyncLine {
    let text: String
    let startMs: Int
    let endMs: Int
}

// MARK: - Global state

/// Full syllable data for the current track (nil if not Syllable type)
var spicySyllableLines: [SpicySyllableLine]? = nil

/// Line-sync data for the current track (nil if not Line type)
var spicyLineSyncLines: [SpicyLineSyncLine]? = nil

/// Track ID for which the above data was fetched
var spicyLyricsTrackId: String? = nil
