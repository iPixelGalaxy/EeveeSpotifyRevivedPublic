import UIKit
import ObjectiveC

// MARK: - Position probe helper

/// Tries to read a Double playback position (in seconds) from statefulPlayer via ObjC runtime.
/// Returns nil if no known selector responds.
private func probePlaybackPositionSeconds() -> Double? {
    guard let player = statefulPlayer as AnyObject? else { return nil }

    // Selectors that might return a Double position in seconds
    let doubleSelectors = [
        "currentPosition", "playbackPosition", "position",
        "currentPlaybackPosition", "currentPositionSeconds"
    ]
    for name in doubleSelectors {
        let sel = Selector((name))
        guard (player as AnyObject).responds(to: sel),
              let method = class_getInstanceMethod(type(of: player as AnyObject), sel) else { continue }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector) -> Double
        let val = unsafeBitCast(imp, to: Fn.self)(player as AnyObject, sel)
        if val > 0 { return val }
    }

    // Selectors that might return an Int/Int64 position in milliseconds
    let intSelectors = [
        "currentPositionMs", "positionMs", "currentPositionMilliseconds",
        "playbackPositionMs", "positionInMs"
    ]
    for name in intSelectors {
        let sel = Selector((name))
        guard (player as AnyObject).responds(to: sel),
              let method = class_getInstanceMethod(type(of: player as AnyObject), sel) else { continue }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyObject, Selector) -> Int
        let val = unsafeBitCast(imp, to: Fn.self)(player as AnyObject, sel)
        if val > 0 { return Double(val) / 1000.0 }
    }

    return nil
}

// MARK: - Single line view

class SpicyLyricsLineView: UIView {
    enum LineState { case past, active, future }

    private let label = UILabel()
    private(set) var state: LineState = .future

    // Syllable data (nil = line-sync mode, uses fullText only)
    var words: [SpicySyllableWord]?
    var fullText: String = ""

    // Colors
    static let colorPast    = UIColor.white.withAlphaComponent(0.35)
    static let colorFuture  = UIColor.white.withAlphaComponent(0.55)
    static let colorSung    = UIColor.white
    static let colorUnssung = UIColor.white.withAlphaComponent(0.50)

    init(text: String, words: [SpicySyllableWord]?) {
        super.init(frame: .zero)
        self.fullText = text
        self.words = words

        label.text = text
        label.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        label.textColor = Self.colorFuture
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(state newState: LineState, positionMs: Int = 0) {
        state = newState
        switch newState {
        case .past:
            label.attributedText = nil
            label.text = fullText
            label.textColor = Self.colorPast
        case .future:
            label.attributedText = nil
            label.text = fullText
            label.textColor = Self.colorFuture
        case .active:
            updateKaraoke(positionMs: positionMs)
        }
    }

    func updateKaraoke(positionMs: Int) {
        guard let words = words, !words.isEmpty else {
            // Line-sync mode: just show bright
            label.attributedText = nil
            label.text = fullText
            label.textColor = Self.colorSung
            return
        }

        // Build attributed string: sung syllables bright, rest dim
        let attributed = NSMutableAttributedString()
        let font = label.font!

        for (i, word) in words.enumerated() {
            let prefix = (i > 0 && !word.isPartOfWord) ? " " : ""
            let syllableStr = prefix + word.text

            let isSung = positionMs >= word.startMs
            let color: UIColor = isSung ? Self.colorSung : Self.colorUnssung
            attributed.append(NSAttributedString(
                string: syllableStr,
                attributes: [.font: font, .foregroundColor: color]
            ))
        }
        label.attributedText = attributed
    }
}

// MARK: - Overlay view

class SpicyLyricsOverlayView: UIView {

    private let scrollView = UIScrollView()
    private let stackView  = UIStackView()
    private var lineViews: [SpicyLyricsLineView] = []

    private var syllableLines: [SpicySyllableLine] = []
    private var lineSyncLines: [SpicyLineSyncLine] = []
    private var isSyllableMode = false

    private var displayLink: CADisplayLink?

    // Wall-clock fallback when no player selector works
    private var wallClockBase: CFTimeInterval = 0
    private var wallClockOffsetMs: Int = 0

    private var lastLineIndex = -1

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.85)
        setupScrollView()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupScrollView() {
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    // MARK: Configuration

    func configureSyllable(_ lines: [SpicySyllableLine]) {
        isSyllableMode = true
        syllableLines = lines
        buildLineViews()
        startDisplayLink()
        calibrateWallClock()
    }

    func configureLineSync(_ lines: [SpicyLineSyncLine]) {
        isSyllableMode = false
        lineSyncLines = lines
        buildLineViews()
        startDisplayLink()
        calibrateWallClock()
    }

    private func buildLineViews() {
        lineViews.forEach { $0.removeFromSuperview() }
        lineViews.removeAll()
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        // Top padding spacer
        let topSpacer = UIView()
        topSpacer.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stackView.addArrangedSubview(topSpacer)

        if isSyllableMode {
            for line in syllableLines {
                let view = SpicyLyricsLineView(text: line.fullText, words: line.words)
                lineViews.append(view)
                stackView.addArrangedSubview(view)
            }
        } else {
            for line in lineSyncLines {
                let view = SpicyLyricsLineView(text: line.text, words: nil)
                lineViews.append(view)
                stackView.addArrangedSubview(view)
            }
        }

        // Bottom padding spacer
        let bottomSpacer = UIView()
        bottomSpacer.heightAnchor.constraint(equalToConstant: 200).isActive = true
        stackView.addArrangedSubview(bottomSpacer)

        // Set initial state
        lineViews.forEach { $0.apply(state: .future) }
    }

    // MARK: Timing

    private func calibrateWallClock() {
        // Try to read actual position from player first
        if let pos = probePlaybackPositionSeconds() {
            wallClockOffsetMs = Int(pos * 1000)
        } else {
            wallClockOffsetMs = 0
        }
        wallClockBase = CACurrentMediaTime()
    }

    private var currentPositionMs: Int {
        // Always try player first for accuracy (handles seeks)
        if let pos = probePlaybackPositionSeconds() {
            return Int(pos * 1000)
        }
        // Fall back to wall-clock estimate
        let elapsed = CACurrentMediaTime() - wallClockBase
        return wallClockOffsetMs + Int(elapsed * 1000)
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Tick

    @objc private func tick() {
        let posMs = currentPositionMs

        if isSyllableMode {
            updateSyllableMode(posMs: posMs)
        } else {
            updateLineSyncMode(posMs: posMs)
        }
    }

    private func currentLineIndex(posMs: Int) -> Int {
        if isSyllableMode {
            // Find the last line whose startMs <= posMs
            var best = -1
            for (i, line) in syllableLines.enumerated() {
                if line.startMs <= posMs { best = i }
            }
            return best
        } else {
            var best = -1
            for (i, line) in lineSyncLines.enumerated() {
                if line.startMs <= posMs { best = i }
            }
            return best
        }
    }

    private func updateSyllableMode(posMs: Int) {
        let lineIdx = currentLineIndex(posMs: posMs)

        for (i, view) in lineViews.enumerated() {
            if i < lineIdx {
                if view.state != .past { view.apply(state: .past) }
            } else if i == lineIdx {
                view.apply(state: .active, positionMs: posMs)
            } else {
                if view.state != .future { view.apply(state: .future) }
            }
        }

        if lineIdx != lastLineIndex {
            lastLineIndex = lineIdx
            scrollToLine(lineIdx, animated: true)
        }
    }

    private func updateLineSyncMode(posMs: Int) {
        let lineIdx = currentLineIndex(posMs: posMs)

        for (i, view) in lineViews.enumerated() {
            if i < lineIdx {
                if view.state != .past { view.apply(state: .past) }
            } else if i == lineIdx {
                if view.state != .active { view.apply(state: .active, positionMs: posMs) }
            } else {
                if view.state != .future { view.apply(state: .future) }
            }
        }

        if lineIdx != lastLineIndex {
            lastLineIndex = lineIdx
            scrollToLine(lineIdx, animated: true)
        }
    }

    private func scrollToLine(_ index: Int, animated: Bool) {
        guard index >= 0 && index < lineViews.count else { return }
        let lineView = lineViews[index]

        // Wait for layout to be valid
        layoutIfNeeded()

        let lineOrigin = lineView.convert(CGPoint.zero, to: scrollView)
        let lineHeight = lineView.bounds.height
        let targetY = lineOrigin.y - (scrollView.bounds.height * 0.35) + lineHeight / 2

        let maxY = scrollView.contentSize.height - scrollView.bounds.height
        let clampedY = max(0, min(targetY, maxY))

        scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)
    }
}
