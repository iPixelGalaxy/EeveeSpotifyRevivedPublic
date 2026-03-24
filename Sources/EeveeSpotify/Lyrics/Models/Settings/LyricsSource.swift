import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    case spicyLyrics = 5

    // All sources enabled now that we have reliable metadata fetching
    public static var allCases: [LyricsSource] {
        return [.musixmatch, .spicyLyrics]
    }

    // swift 5.8 compatible
    var description: String {
    switch self {
    case .genius:
        return "Genius"
    case .lrclib:
        return "LRCLIB"
    case .musixmatch:
        return "Musixmatch"
    case .petit:
        return "PetitLyrics"
    case .spicyLyrics:
        return "Spicy Lyrics"
    case .notReplaced:
        return "Spotify"
    }
    }

    
    var isReplacingLyrics: Bool { self != .notReplaced }
    
    static var defaultSource: LyricsSource {
        .musixmatch
    }
}
