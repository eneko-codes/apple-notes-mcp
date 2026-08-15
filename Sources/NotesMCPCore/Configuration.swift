import Foundation

/// Numeric limits, fixed to sensible defaults. "Folders Claude may use" used to be a
/// fourth, configurable setting; the owner's plug-and-play rule removed it; every folder is
/// visible now, unconditionally, and `extension/manifest.json` passes this process no
/// arguments at all. `parse` below still reads flags for these three, because none of them
/// is wired through `user_config` either — it is just where a manual run could still
/// override one by hand.
///
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is three numbers, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {
    /// How many notes one search walks before giving up. Raising it makes searches more
    /// complete and much slower: Notes, not this process, does the reading.
    public var scanCeiling: Int = 500

    /// Default truncation for the text `note_get` returns. The tool's own `text_limit`
    /// still wins.
    public var textLimit: Int = 8_000

    /// Default page size for `notes_search`.
    public var searchLimit: Int = 25

    public init() {}

    public static let scanCeilingRange = 50...5_000
    public static let textLimitRange = 200...100_000
    public static let searchLimitRange = 1...100

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Observed live in the
    /// sibling servers before they went plug-and-play: an empty `multiple: true` list
    /// produced a bare `${user_config.some_setting}` after the `--` separator. Kept for
    /// whichever numeric flag below is actually passed a value.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal. A server that will not launch is much
    /// harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            func clamped(_ range: ClosedRange<Int>) -> Int? {
                guard let value, !isPlaceholder(value), let number = Int(value) else {
                    return nil
                }
                return min(max(number, range.lowerBound), range.upperBound)
            }

            switch flag {
            case "--scan-ceiling":
                if let number = clamped(scanCeilingRange) { configuration.scanCeiling = number }
                index += 2

            case "--text-limit":
                if let number = clamped(textLimitRange) { configuration.textLimit = number }
                index += 2

            case "--search-limit":
                if let number = clamped(searchLimitRange) { configuration.searchLimit = number }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
