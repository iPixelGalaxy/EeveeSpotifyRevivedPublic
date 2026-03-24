import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

var spicyLyricsOverlay: SpicyLyricsOverlayView?

// SPTPlayerTrack metadata hooks not compatible with 9.1.x
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()
        
        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {
            return uri
        }
        
        return NSURL(string: "spotify:track:")!
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)

        guard UserDefaults.lyricsSource == .spicyLyrics,
              spicySyllableLines != nil || spicyLineSyncLines != nil else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let vc = Dynamic.convert(self.target, to: UIViewController.self)
            spicyLyricsOverlay?.stop()
            spicyLyricsOverlay?.removeFromSuperview()

            let overlay = SpicyLyricsOverlayView(frame: vc.view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            vc.view.addSubview(overlay)
            spicyLyricsOverlay = overlay

            if let syllable = spicySyllableLines {
                overlay.configureSyllable(syllable)
            } else if let lineSync = spicyLineSyncLines {
                overlay.configureLineSync(lineSync)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)

        spicyLyricsOverlay?.stop()
        spicyLyricsOverlay?.removeFromSuperview()
        spicyLyricsOverlay = nil
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)

        guard UserDefaults.lyricsSource == .spicyLyrics,
              spicySyllableLines != nil || spicyLineSyncLines != nil else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let vc = Dynamic.convert(self.target, to: UIViewController.self)
            spicyLyricsOverlay?.stop()
            spicyLyricsOverlay?.removeFromSuperview()

            let overlay = SpicyLyricsOverlayView(frame: vc.view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            vc.view.addSubview(overlay)
            spicyLyricsOverlay = overlay

            if let syllable = spicySyllableLines {
                overlay.configureSyllable(syllable)
            } else if let lineSync = spicyLineSyncLines {
                overlay.configureLineSync(lineSync)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)

        spicyLyricsOverlay?.stop()
        spicyLyricsOverlay?.removeFromSuperview()
        spicyLyricsOverlay = nil
    }
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Dummy target for 9.1.6
        : "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
