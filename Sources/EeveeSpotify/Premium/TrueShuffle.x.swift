import Foundation
import ObjectiveC

/// Installs runtime hooks that neutralise Spotify's weighted shuffle algorithm,
/// producing a genuinely random playback order rather than one biased towards
/// Spotify's recommended / frequently-repeated tracks.
///
/// Spotify's internal shuffle manager exposes two key methods:
///
///  - `weightForTrack:recommendedTrack:mergedList:`
///    Returns a numeric weight that biases which track is picked next.
///    We force `recommendedTrack` and `mergedList` to `false` so every track
///    receives an equal weight.
///
///  - `weightedShuffleListWithTracks:recommendations:`
///    Pre-computes a biased order using recommendation data.
///    We return `nil` to skip the pre-computation entirely.
///
/// The class name is found dynamically at runtime (case-insensitive search for
/// "shuff") so the hook remains valid across Spotify version updates that may
/// rename or obfuscate the class.

struct TrueShuffleHookInstaller {

    private static var didInstall = false

    static func installIfEnabled() {
        guard UserDefaults.trueShuffleEnabled else { return }
        guard !didInstall else { return }
        didInstall = true

        guard let shuffleClass = findShuffleClass() else {
            NSLog("[EeveeSpotify] TrueShuffle: could not locate shuffle manager class")
            return
        }

        swizzleWeightForTrack(on: shuffleClass)
        swizzleWeightedShuffleList(on: shuffleClass)

        NSLog("[EeveeSpotify] TrueShuffle: hooks installed on %@", NSStringFromClass(shuffleClass))
    }

    // MARK: - Class discovery

    private static func findShuffleClass() -> AnyClass? {
        var count: UInt32 = 0
        guard let classes = objc_copyClassList(&count) else { return nil }

        // Collect into a Swift array so we can free the C array right away
        let allClasses: [AnyClass] = (0..<Int(count)).map { classes[$0] }
        free(unsafeBitCast(classes, to: UnsafeMutableRawPointer.self))

        return allClasses.first {
            String(cString: class_getName($0)).lowercased().contains("shuff")
        }
    }

    // MARK: - weightForTrack:recommendedTrack:mergedList:

    private static func swizzleWeightForTrack(on cls: AnyClass) {
        let sel = Selector(("weightForTrack:recommendedTrack:mergedList:"))
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        // Capture the original IMP and selector before installing the replacement.
        let origIMP = method_getImplementation(method)
        let capturedSel = sel

        // imp_implementationWithBlock expects a @convention(block) closure.
        // Unlike @convention(c), blocks ARE allowed to capture context.
        // The block receives (self, arg1, arg2, …) — the SEL is not passed.
        let replacement: @convention(block) (AnyObject, AnyObject, Bool, Bool) -> Double = { self_, track, _, _ in
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, Bool, Bool) -> Double
            // Call the original implementation but force both bias flags to false,
            // so every track receives an equal weight.
            return unsafeBitCast(origIMP, to: Fn.self)(self_, capturedSel, track, false, false)
        }

        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    // MARK: - weightedShuffleListWithTracks:recommendations:

    private static func swizzleWeightedShuffleList(on cls: AnyClass) {
        let sel = Selector(("weightedShuffleListWithTracks:recommendations:"))
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        // Return nil to skip Spotify's weighted pre-shuffle list generation entirely.
        let replacement: @convention(block) (AnyObject, AnyObject, AnyObject) -> AnyObject? = { _, _, _ in nil }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
