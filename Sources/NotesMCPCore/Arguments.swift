import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Text

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func requiredString(_ name: String) throws -> String {
        guard given(name) != nil else { throw ToolError.missingArgument(name) }
        guard let text = try optionalString(name) else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return text
    }

    /// A note's body, kept exactly as it was written.
    ///
    /// Unlike every other string argument this one is not trimmed: leading whitespace is
    /// part of the HTML the caller composed, and a body that appends onto an existing note
    /// may legitimately begin with a break.
    public func requiredBody(_ name: String) throws -> String {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.badArgument(
                name: name,
                reason: "it is empty. A note with no content cannot be told apart from a "
                    + "mistake, and replacing a note with nothing is the mistake this "
                    + "server refuses hardest.")
        }
        return text
    }

    // MARK: Flags and numbers

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A quantity: a size or a count. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used. Every
    /// identifier this server takes is text, so no number is ever refused for its value.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    // MARK: Enumerations

    /// One of a fixed set of words, compared case-insensitively. `nil` when not given.
    private func choice(_ name: String, among allowed: [String]) throws -> String? {
        guard let raw = try optionalString(name) else { return nil }
        let word = raw.lowercased()
        guard allowed.contains(word) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected one of: " + allowed.joined(separator: ", ")
                    + "; got '\(ToolStandard.echo(raw))'")
        }
        return word
    }

    /// Required and with no default: see `UpdateMode`.
    public func updateMode(_ name: String) throws -> UpdateMode {
        guard given(name) != nil else { throw ToolError.missingArgument(name) }
        guard let word = try choice(name, among: UpdateMode.allCases.map(\.rawValue)),
            let mode = UpdateMode(rawValue: word)
        else {
            throw ToolError.badArgument(
                name: name,
                reason: "it is empty; expected append or replace. "
                    + "replace discards the note's current content.")
        }
        return mode
    }

    public func dateField(_ name: String) throws -> NoteDateField {
        guard let word = try choice(name, among: NoteDateField.allCases.map(\.rawValue)),
            let field = NoteDateField(rawValue: word)
        else { return .modified }
        return field
    }

    // MARK: Dates

    /// `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, or either with seconds and an offset.
    ///
    /// Read here, digit by digit, not by a date formatter: Foundation's ISO 8601 formatter
    /// takes `+25:99` for an offset and its calendars roll 30 February over into March, and
    /// either would search a range nobody asked for where this refuses.
    ///
    /// `isDateOnly` records what the caller actually wrote. Discarding it turns a bare day
    /// into midnight, so an upper bound documented as "on or before this date" would
    /// exclude that whole day.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = try optionalString(name) else { return nil }
        let refused = ToolError.badDate(argument: name, value: raw)

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count <= 2, let day = Self.numbers(parts[0], separatedBy: "-", count: 3...3)
        else { throw refused }
        var asked = DateComponents(year: day[0], month: day[1], day: day[2])

        // A time with an offset (Z, +02:00, -05:00) is an instant of its own. Without one
        // it is local, and so is a bare day.
        var zone = calendar.timeZone
        if parts.count == 2 {
            var clock = parts[1]
            if clock.hasSuffix("Z") {
                clock = clock.dropLast()
                zone = .gmt
            } else if let sign = clock.lastIndex(where: { $0 == "+" || $0 == "-" }) {
                guard let offset = Self.numbers(clock[clock.index(after: sign)...], separatedBy: ":", count: 2...2),
                    (0...14).contains(offset[0]), (0...59).contains(offset[1]),
                    let fixed = TimeZone(
                        secondsFromGMT: (clock[sign] == "-" ? -1 : 1) * (offset[0] * 3600 + offset[1] * 60))
                else { throw refused }
                clock = clock[..<sign]
                zone = fixed
            }
            guard let time = Self.numbers(clock, separatedBy: ":", count: 2...3),
                (0...23).contains(time[0]), (0...59).contains(time[1]),
                time.count == 2 || (0...59).contains(time[2])
            else { throw refused }
            asked.hour = time[0]
            asked.minute = time[1]
            asked.second = time.count == 3 ? time[2] : 0
        }

        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        guard let date = gregorian.date(from: asked) else { throw refused }
        // The calendar answers for a day that does not exist with the one it rolls over
        // to, so the day it found is held against the day that was written.
        let found = gregorian.dateComponents([.year, .month, .day], from: date)
        guard found.year == day[0], found.month == day[1], found.day == day[2] else { throw refused }
        return (date, parts.count == 1)
    }

    /// The whole numbers of `text` between `separator`s, when there are `count` of them and
    /// each is digits alone: `Int("+2")` and `Int("-0")` are numbers, and neither is a month.
    private static func numbers(
        _ text: Substring, separatedBy separator: Character, count: ClosedRange<Int>
    ) -> [Int]? {
        let fields = text.split(separator: separator, omittingEmptySubsequences: false)
        guard count.contains(fields.count) else { return nil }
        var numbers: [Int] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 4, field.allSatisfy({ $0.isASCII && $0.isNumber }),
                let number = Int(field)
            else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}
