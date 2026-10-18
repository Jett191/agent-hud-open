import Foundation

/// Independent, additive token kinds (`TokenKind`): input and output without the cache writes and reasoning counted
/// separately, and cache reads.
public struct TokenDimensions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let input = Self(rawValue: 1)
    public static let output = Self(rawValue: 2)
    public static let cacheRead = Self(rawValue: 4)
    public static let cacheWrite = Self(rawValue: 8)
    public static let reasoning = Self(rawValue: 16)
    /// What calls added: everything but cache reads.
    public static let fresh: Self = [.cacheWrite, .input, .reasoning, .output]
    public static let all: Self = [.cacheWrite, .input, .reasoning, .output, .cacheRead]
    public static var choices: [(value: Self, label: String)] { TokenKind.allCases.map { ($0.dimension, $0.label) } }
    public var label: String {
        switch self {
        case .fresh: L10n.text("不含缓存读取", "Excl. cache reads")
        case .all: L10n.text("全部", "All")
        default: Self.choices.filter { contains($0.value) }.map(\.label).joined(separator: " + ")
        }
    }
    public func count(_ kinds: TokenKinds) -> Int {
        TokenKind.allCases.reduce(0) { $0 + (contains($1.dimension) ? kinds[$1] : 0) }
    }
    /// The selected kinds of `kinds`, the others zero.
    public func masking(_ kinds: TokenKinds) -> TokenKinds {
        TokenKinds(cacheWrite: contains(.cacheWrite) ? kinds.cacheWrite : 0, input: contains(.input) ? kinds.input : 0,
                   reasoning: contains(.reasoning) ? kinds.reasoning : 0, output: contains(.output) ? kinds.output : 0,
                   cacheRead: contains(.cacheRead) ? kinds.cacheRead : 0)
    }
    /// For counts without a split: input that includes cache writes, output that includes reasoning.
    public func count(input: Int, output: Int, cache: Int) -> Int {
        (isDisjoint(with: [.input, .cacheWrite]) ? 0 : input) + (isDisjoint(with: [.output, .reasoning]) ? 0 : output)
            + (contains(.cacheRead) ? cache : 0)
    }
    public func count(_ event: UsageEvent) -> Int { count(event.kinds) }
    public func count(_ bucket: UsageBucket) -> Int { count(bucket.kinds) }
}

public enum StatsRange: Int, CaseIterable, Sendable, Hashable {
    case hours5 = 5
    case hours24 = 24
    case days7 = 168
    case days30 = 720

    public var label: String {
        switch self {
        case .hours5: return L10n.text("5 小时", "5 h")
        case .hours24: return L10n.text("24 小时", "24 h")
        case .days7: return L10n.text("7 天", "7 days")
        case .days30: return L10n.text("30 天", "30 days")
        }
    }

    public var hours: Int { rawValue }

    /// The chart's buckets for the range: a month only by day.
    public var bucketSizes: [TokenBucketSize] { self == .days30 ? [.day1] : TokenBucketSize.allCases }

    public var recentLabel: String { L10n.text("近 \(label)", "Last \(label)") }

    public func interval(endingAt now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-Double(hours) * 3600), end: now)
    }
}

public enum TokenBucketSize: Int, CaseIterable, Sendable, Hashable {
    case minutes15 = 15
    case minutes30 = 30
    case hour1 = 60
    case day1 = 1440

    public var duration: TimeInterval { Double(rawValue) * 60 }
    public var label: String {
        switch self {
        case .hour1: "1hr"
        case .day1: "1d"
        default: "\(rawValue)min"
        }
    }
}

/// One stack on the token chart, preserving integer counts and its position on the shared time axis.
public struct TokenColumn: Hashable, Sendable, Identifiable {
    public let interval: DateInterval
    public let tokens: [Int]
    public var id: Date { interval.start }
    public var total: Int { tokens.reduce(0, +) }
}

/// One bar of an API account's estimated cost in one currency, at its position on the shared time axis.
public struct CostColumn: Hashable, Sendable, Identifiable {
    public let interval: DateInterval
    /// The estimated cost of the requests recorded in the column; nil where one of them had no price in the currency.
    public let amount: Decimal?
    public var id: Date { interval.start }

    public init(interval: DateInterval, amount: Decimal?) {
        self.interval = interval
        self.amount = amount
    }
}

/// Pure transforms from usage buckets to drawable series.
public enum ChartData {
    /// Sums 15-minute buckets into local quarter-hour, hour or day columns. A bucket counts when it overlaps the range,
    /// so the period holding the range's start or the current moment counts whole.
    /// Empty periods retain their position, and integer token counts are never rounded or interpolated.
    public static func tokenBars(usage: [UsageBucket], agentIds: [String], range: StatsRange, bucketSize: TokenBucketSize = .hour1, now: Date, calendar: Calendar = .current, dimensions: TokenDimensions = .fresh) -> [TokenColumn] {
        tokenBars(usage: usage, agentIds: agentIds, interval: range.interval(endingAt: now), bucketSize: bucketSize, calendar: calendar,
                  dimensions: dimensions)
    }

    public static func tokenBars(usage: [UsageBucket], agentIds: [String], interval: DateInterval, bucketSize: TokenBucketSize,
                                 calendar: Calendar = .current, dimensions: TokenDimensions = .fresh) -> [TokenColumn] {
        let periods = periods(interval: interval, bucketSize: bucketSize, calendar: calendar)
        let dayIndices = bucketSize == .day1
            ? Dictionary(uniqueKeysWithValues: periods.enumerated().map { ($0.element.start, $0.offset) }) : [:]
        var values = Array(repeating: Array(repeating: 0, count: agentIds.count), count: periods.count)
        let indices = Dictionary(uniqueKeysWithValues: agentIds.enumerated().map { ($0.element, $0.offset) })
        for bucket in usage where bucket.overlaps(interval) {
            guard let agent = indices[bucket.agentId], let first = periods.first else { continue }
            let start = max(bucket.start, first.start)
            let column = bucketSize == .day1 ? dayIndices[calendar.startOfDay(for: start)] ?? 0
                : min(periods.count - 1, Int(start.timeIntervalSince(first.start) / bucketSize.duration))
            values[column][agent] += dimensions.count(bucket)
        }
        return values.enumerated().map { index, tokens in
            TokenColumn(interval: periods[index], tokens: tokens)
        }
    }

    /// Sums an API account's 15-minute costs in `currency` into the columns `tokenBars` lays the same interval out in,
    /// counting a bucket that overlaps the interval in the column its start falls in, as the token chart counts tokens,
    /// so the columns add up to `APIBilling.estimatedCost(currency:during:)`. A column holding a bucket without a price
    /// in the currency has no amount; an empty one keeps its place at zero.
    public static func costBars(costs: [CostBucket], currency: String, interval: DateInterval, bucketSize: TokenBucketSize,
                                calendar: Calendar = .current) -> [CostColumn] {
        let periods = periods(interval: interval, bucketSize: bucketSize, calendar: calendar)
        let dayIndices = bucketSize == .day1
            ? Dictionary(uniqueKeysWithValues: periods.enumerated().map { ($0.element.start, $0.offset) }) : [:]
        var amounts: [Decimal?] = Array(repeating: 0, count: periods.count)
        for bucket in costs where bucket.overlaps(interval) {
            guard let first = periods.first else { continue }
            let start = max(bucket.start, first.start)
            let column = bucketSize == .day1 ? dayIndices[calendar.startOfDay(for: start)] ?? 0
                : min(periods.count - 1, Int(start.timeIntervalSince(first.start) / bucketSize.duration))
            guard let amount = bucket.amounts[currency] else {
                amounts[column] = nil
                continue
            }
            amounts[column] = amounts[column].map { $0 + amount }
        }
        return zip(periods, amounts).map { CostColumn(interval: $0, amount: $1) }
    }

    private static func periods(interval: DateInterval, bucketSize: TokenBucketSize, calendar: Calendar) -> [DateInterval] {
        let duration = bucketSize.duration
        if bucketSize == .day1 {
            // Calendar days start at local midnight and can span 23 or 25 hours at DST changes.
            var days: [DateInterval] = []
            var start = calendar.startOfDay(for: interval.start)
            while start < interval.end {
                let day = calendar.dateInterval(of: .day, for: start)!
                days.append(day)
                start = day.end
            }
            return days
        }
        let firstHour = calendar.dateInterval(of: .hour, for: interval.start)!.start
        let firstBucket = firstHour.addingTimeInterval(floor(interval.start.timeIntervalSince(firstHour) / duration) * duration)
        let count = Int(ceil(interval.end.timeIntervalSince(firstBucket) / duration))
        return (0..<count).map { DateInterval(start: firstBucket.addingTimeInterval(Double($0) * duration), duration: duration) }
    }

    /// The column width that keeps a span at no more than about a hundred columns: quarter hours for a day, hours for four.
    public static func bucketSize(spanning duration: TimeInterval) -> TokenBucketSize {
        duration <= 86400 ? .minutes15 : duration <= 4 * 86400 ? .hour1 : .day1
    }

    /// Hit-test whole time buckets, including empty ones and the chart's rightmost edge.
    public static func tokenColumn(at date: Date, in columns: [TokenColumn]) -> TokenColumn? {
        columns.first { date >= $0.interval.start && date < $0.interval.end }
            ?? columns.last.flatMap { date == $0.interval.end ? $0 : nil }
    }

    /// Four x-axis labels: dates and times, with the current one marked "现在".
    public static func axisLabels(range: StatsRange, now: Date, calendar: Calendar = .current) -> [String] {
        let hours = Double(range.hours)
        let offsets = [hours, hours * 2 / 3, hours / 3]
        let earlier = offsets.map { offset -> String in
            let date = now.addingTimeInterval(-offset * 3600)
            return dateTime(date, calendar: calendar)
        }
        return earlier + [L10n.text("现在 ", "Now ") + dateTime(now, calendar: calendar)]
    }

    public static func weekdayName(_ date: Date, calendar: Calendar = .current) -> String {
        L10n.weekdayNames[calendar.component(.weekday, from: date) - 1]
    }

    /// A weekday, concrete month/day and 24-hour time in the interface's date locale.
    public static func dateTime(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: L10n.dateLocale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// A stretch of time with its date written once when it stays inside one day: "Sun 11 Oct at 23:00 – 23:15",
    /// and the date alone for a whole day. A stretch that ends at midnight still belongs to the day it started in.
    public static func period(_ interval: DateInterval, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(locale: L10n.dateLocale, calendar: calendar, timeZone: calendar.timeZone)
        guard let day = calendar.dateInterval(of: .day, for: interval.start), interval.end <= day.end else {
            return "\(dateTime(interval.start, calendar: calendar)) – \(dateTime(interval.end, calendar: calendar))"
        }
        if interval == day {
            return interval.start.formatted(style.weekday(.abbreviated).month(.abbreviated).day())
        }
        let end = interval.end.formatted(style.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        return "\(dateTime(interval.start, calendar: calendar)) – \(end)"
    }

    /// "周二 16:10"
    public static func weekdayTime(_ date: Date, calendar: Calendar = .current) -> String {
        let hh = calendar.component(.hour, from: date), mm = calendar.component(.minute, from: date)
        return "\(weekdayName(date, calendar: calendar)) \(String(format: "%02d:%02d", hh, mm))"
    }

    /// A future date's weekday with which week it falls in, "下周二 16:10" / "Next Tue 16:10", so two
    /// Tuesdays apart still read differently. The week a date shares with `now` needs no marker, and a date
    /// more than three weeks out names its concrete month and day instead of piling up "下".
    public static func relativeWeekdayTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        // "下周" in Chinese counts Monday-started weeks whatever the system calendar prefers; English
        // follows the locale's own week start, where "next" week begins Sunday in the US and Monday in the UK.
        var cal = calendar
        if L10n.resolved == .zhHans { cal.firstWeekday = 2 }
        let delta = weeksBetween(now, and: date, calendar: cal)
        guard delta > 0 else { return weekdayTime(date, calendar: calendar) }
        if delta <= 3 {
            let zh = String(repeating: "下", count: delta) + weekdayTime(date, calendar: calendar)
            let en = delta == 1 ? "Next \(weekdayTime(date, calendar: calendar))" : dateTime(date, calendar: calendar)
            return L10n.text(zh, en)
        }
        return dateTime(date, calendar: calendar)
    }

    /// Whole calendar weeks between the week containing `from` and the week containing `to`, by each locale's
    /// own week start; negative when `to` sits in an earlier week.
    private static func weeksBetween(_ from: Date, and to: Date, calendar: Calendar) -> Int {
        guard let a = calendar.dateInterval(of: .weekOfYear, for: from)?.start,
              let b = calendar.dateInterval(of: .weekOfYear, for: to)?.start else { return 0 }
        return calendar.dateComponents([.weekOfYear], from: a, to: b).weekOfYear ?? 0
    }

}
