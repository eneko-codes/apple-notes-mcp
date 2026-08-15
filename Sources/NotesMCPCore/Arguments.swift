import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// A note's body, kept exactly as it was written.
    ///
    /// Unlike every other string argument this one is not trimmed: leading whitespace is
    /// part of the HTML the caller composed, and a body that appends onto an existing note
    /// may legitimately begin with a break.
    public func requiredBody(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.badArgument(
                name: name,
                reason: "it is empty. A note with no content cannot be told apart from a "
                    + "mistake, and replacing a note with nothing is the mistake this "
                    + "server refuses hardest.")
        }
        return raw
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    // MARK: Enumerations

    /// Required and with no default: see `UpdateMode`.
    public func updateMode(_ name: String) throws -> UpdateMode {
        let raw = try requiredString(name)
        guard let mode = UpdateMode(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \"append\" or \"replace\", got \"\(raw)\". "
                    + "\"replace\" discards the note's current content.")
        }
        return mode
    }

    public func dateField(_ name: String) throws -> NoteDateField {
        guard let raw = optionalString(name) else { return .modified }
        guard let field = NoteDateField(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name, reason: "expected \"modified\" or \"created\", got \"\(raw)\"")
        }
        return field
    }

    // MARK: Dates

    /// `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, or full ISO 8601 with an offset.
    ///
    /// `isDateOnly` records what the caller actually wrote. Discarding it turns a bare day
    /// into midnight, so an upper bound documented as "on or before this date" would
    /// exclude that whole day.
    public func optionalDate(_ name: String) throws -> (date: Date, isDateOnly: Bool)? {
        guard let raw = optionalString(name) else { return nil }

        let parts = raw.split(separator: "T", omittingEmptySubsequences: false)
        if parts.count == 1 || (parts.count == 2 && !raw.contains("Z") && !raw.contains("+")) {
            let dayParts = parts[0].split(separator: "-")
            guard dayParts.count == 3, let year = Int(dayParts[0]), let month = Int(dayParts[1]),
                let day = Int(dayParts[2]), (1...12).contains(month), (1...31).contains(day)
            else { throw ToolError.badDate(argument: name, value: raw) }

            var components = DateComponents(year: year, month: month, day: day)
            if parts.count == 2 {
                let time = parts[1].split(separator: ":")
                guard time.count >= 2, let hour = Int(time[0]), let minute = Int(time[1]),
                    (0...23).contains(hour), (0...59).contains(minute)
                else { throw ToolError.badDate(argument: name, value: raw) }
                components.hour = hour
                components.minute = minute
            }
            guard let date = calendar.date(from: components) else {
                throw ToolError.badDate(argument: name, value: raw)
            }
            return (date, parts.count == 1)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else {
            throw ToolError.badDate(argument: name, value: raw)
        }
        return (date, false)
    }
}
