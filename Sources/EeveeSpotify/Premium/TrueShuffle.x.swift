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
        var classCount: UInt32 = 0
        guard let classList = objc_copyClassList(&classCount) else { return nil }
        defer { free(UnsafeMutableRawPointer(mutating: classList)) }

        for i in 0..<Int(classCount) {
            let cls: AnyClass = classList[i]
            let name = String(cString: class_getName(cls))
            if name.lowercased().contains("shuff") {
                return cls
            }
        }
        return nil
    }

    // MARK: - weightForTrack:recommendedTrack:mergedList:

    private static func swizzleWeightForTrack(on cls: AnyClass) {
        let sel = Selector(("weightForTrack:recommendedTrack:mergedList:"))
        guard let originalMethod = class_getInstanceMethod(cls, sel) else { return }

        let originalIMP = method_getImplementation(originalMethod)

        // Replacement: pass `false` for both boolean parameters, neutralising the bias.
        typealias WeightIMP = @convention(c) (AnyObject, Selector, AnyObject, Bool, Bool) -> Double
        let replacement: WeightIMP = { slf, _sel, track, _, _ in
            let orig = unsafeBitCast(originalIMP, to: WeightIMP.self)
            return orig(slf, _sel, track, false, false)
        }

        method_setImplementation(originalMethod, imp_implementationWithBlock(replacement as AnyObject))
    }

    // MARK: - weightedShuffleListWithTracks:recommendations:

    private static func swizzleWeightedShuffleList(on cls: AnyClass) {
        let sel = Selector(("weightedShuffleListWithTracks:recommendations:"))
        guard let originalMethod = class_getInstanceMethod(cls, sel) else { return }

        // Replacement: return nil to skip the weighted pre-shuffle entirely.
        typealias ShuffleListIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> AnyObject?
        let replacement: ShuffleListIMP = { _, _, _, _ in nil }

        method_setImplementation(originalMethod, imp_implementationWithBlock(replacement as AnyObject))
    }
}
