import Foundation

struct AssistantProjectFields {
    var owner: String?
    var start: String?
    var end: String?
    var unspecifiedDate: String?

    static func parse(_ input: String, today: String) -> (title: String, fields: Self) {
        let pattern = #"(?i)(?:^|\s)(дата\s+(?:начала|окончания|завершения)|ответственн[а-яё]*|ответсвенн[а-яё]*|владелец|начало|срок|дедлайн|завершение|дата)(?=\s|:|$)\s*:?\s*"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.:;«»\""))
        guard let first = matches.first, let firstRange = Range(first.range, in: input) else {
            return (input, Self())
        }
        let title = String(input[..<firstRange.lowerBound]).trimmingCharacters(in: trim)
        var fields = Self()
        for (index, match) in matches.enumerated() {
            guard let marker = Range(match.range(at: 1), in: input), let range = Range(match.range, in: input) else { continue }
            let next = matches.dropFirst(index + 1).first.flatMap { Range($0.range, in: input)?.lowerBound }
            let value = String(input[range.upperBound..<(next ?? input.endIndex)]).trimmingCharacters(in: trim)
            guard !value.isEmpty else { continue }
            let label = input[marker].lowercased()
            if label.hasPrefix("ответ") || label == "владелец" {
                fields.owner = value
            } else {
                let date = parseDate(value, today: today) ?? value
                switch label {
                case "начало", "дата начала": fields.start = date
                case "дата": fields.unspecifiedDate = date
                default: fields.end = date
                }
            }
        }
        return (title, fields)
    }

    private static func parseDate(_ text: String, today: String) -> String? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "декбаря", with: "декабря")
            .replacingOccurrences(of: #"^до\s+"#, with: "", options: .regularExpression)
        let words = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                      "июля", "августа", "сентября", "октября", "ноября", "декабря"]
        if words.count >= 2, let day = Int(words[0]), let month = months.firstIndex(of: words[1]),
           let year = (words.count > 2 ? Int(words[2]) : Int(today.prefix(4))) {
            let fullYear = year < 100 ? 2000 + year : year
            let candidate = String(format: "%04d-%02d-%02d", fullYear, month + 1, day)
            let format = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
            if let date = try? format.parse(candidate), format.format(date) == candidate { return candidate }
            return nil
        }
        if case let .dates(range)? = AssistantTaskFilters.parse(normalized, today: today).filters.deadline,
           range.lowerBound == range.upperBound {
            return range.lowerBound
        }
        return nil
    }
}
