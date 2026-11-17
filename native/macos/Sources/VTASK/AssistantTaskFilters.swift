import Foundation

struct AssistantTaskFilters {
    enum Deadline {
        case dates(ClosedRange<String>)
        case missing

        func matches(_ date: String?) -> Bool {
            switch self {
            case .dates(let range): return date.map(range.contains) ?? false
            case .missing: return date == nil
            }
        }
    }

    var deadline: Deadline?
    var stage: String?
    var priority: String?
    var blockedOnly = false
    var overdueOnly = false
    var unassignedOnly = false
    var noProjectOnly = false

    var isActive: Bool {
        deadline != nil || stage != nil || priority != nil || blockedOnly || overdueOnly || unassignedOnly || noProjectOnly
    }

    static func parse(_ text: String, today: String) -> (filters: Self, remaining: String) {
        var filters = Self()
        var remaining = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        func remove(_ pattern: String) -> Bool {
            guard remaining.range(of: pattern, options: .regularExpression) != nil else { return false }
            remaining = remaining.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
            return true
        }
        filters.overdueOnly = remove(#"\bпросроч\p{L}*\b"#)
        filters.unassignedOnly = remove(#"\bбез\s+(?:исполнителя|ответственного)\b"#)
        filters.noProjectOnly = remove(#"\bбез\s+проекта\b"#)
        filters.blockedOnly = remove(#"\bзаблокирован\p{L}*\b"#)
        if remove(#"\b(?:завершенн\p{L}*|выполненн\p{L}*|готовые)\b"#) { filters.stage = "done" }
        if remove(#"\b(?:активн\p{L}*|открыт\p{L}*|текущ\p{L}*)\b"#) { filters.stage = "active" }
        if remove(#"\bотмененн\p{L}*\b"#) { filters.stage = "cancelled" }
        for (pattern, priority) in [
            (#"\b(?:высок\p{L}*)\s+приоритет\p{L}*\b"#, "high"),
            (#"\b(?:низк\p{L}*)\s+приоритет\p{L}*\b"#, "low"),
            (#"\b(?:критическ\p{L}*)\b(?:\s+приоритет\p{L}*)?"#, "critical"),
            (#"\b(?:обычн\p{L}*)\s+приоритет\p{L}*\b"#, "normal")
        ] where remove(pattern) {
            filters.priority = priority
        }
        if remove(#"\bбез\s+(?:срока|даты)\b"#) {
            filters.deadline = .missing
        } else if let result = dateFilter(remaining, today: today) {
            filters.deadline = .dates(result.range)
            remaining.replaceSubrange(result.source, with: " ")
        }
        return (filters, remaining)
    }

    private static func dateFilter(_ text: String, today: String) -> (range: ClosedRange<String>, source: Range<String.Index>)? {
        let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let reference = try? format.parse(today) else { return nil }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let periods: [(String, Calendar.Component, Int)] = [
            (#"\b(?:на\s+)?сегодня\b"#, .day, 0),
            (#"\b(?:на\s+)?завтра\b"#, .day, 1),
            (#"\b(?:на\s+)?послезавтра\b"#, .day, 2),
            (#"\b(?:на\s+)?(?:эту|текущую)\s+недел[юе]\b"#, .weekOfYear, 0),
            (#"\b(?:на\s+)?следующую\s+неделю\b"#, .weekOfYear, 1),
            (#"\b(?:на\s+)?(?:этом|текущий|этот)\s+месяц(?:е)?\b"#, .month, 0),
            (#"\b(?:на\s+)?следующий\s+месяц\b"#, .month, 1)
        ]
        for (pattern, component, offset) in periods {
            if let source = text.range(of: pattern, options: .regularExpression),
               let date = calendar.date(byAdding: component, value: offset, to: reference),
               let interval = calendar.dateInterval(of: component, for: date),
               let last = calendar.date(byAdding: .day, value: -1, to: interval.end) {
                return (format.format(interval.start)...format.format(last), source)
            }
        }
        if let source = text.range(of: #"\b(?:на\s+неделю|(?:на\s+)?(?:ближайшие\s+)?7\s+дней)\b"#, options: .regularExpression),
           let last = calendar.date(byAdding: .day, value: 6, to: reference) {
            return (today...format.format(last), source)
        }
        if let source = text.range(of: #"\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}\.\d{1,2}(?:\.\d{4})?)\b"#, options: .regularExpression) {
            let raw = String(text[source])
            let parts = raw.split(separator: ".").compactMap { Int($0) }
            let value: String
            if parts.count >= 2 {
                let year = parts.count == 3 ? parts[2] : calendar.component(.year, from: reference)
                value = String(format: "%04d-%02d-%02d", year, parts[1], parts[0])
            } else {
                value = raw
            }
            if let date = try? format.parse(value), format.format(date) == value {
                return (value...value, source)
            }
        }
        return nil
    }
}
