import SwiftUI

struct MeetingTopics {
    static let ungrouped = "Без темы"

    private static let zone = try? NSRegularExpression(
        pattern: #"\bзон(?:а|е|у|ы|ой)\s*(?:[«"]([^»"\n]{1,32})[»"]|(?:№\s*)?([0-9]{1,3}[а-яa-z]?))(?=$|[^\p{L}\p{N}])"#,
        options: .caseInsensitive
    )
    private struct Topic: Decodable {
        let title: String
        let prefixes: [String]
        let words: [String]?
        let phrases: [String]
        let actions: [String]?
        let searchPrefixes: [String]?
        let searchWords: [String]?

        func matches(_ wordsInText: [Substring], phrase: String) -> Bool {
            let mentionsTime = title == "Финансы" && wordsInText.contains {
                $0.hasPrefix("врем") || $0.hasPrefix("час") || $0.hasPrefix("минут")
            }
            return wordsInText.contains { word in
                if mentionsTime && (word.hasPrefix("потрат") || word.hasPrefix("трат")) { return false }
                return prefixes.contains { word.hasPrefix($0) } || words?.contains(String(word)) == true
            } || phrases.contains { phrase.contains(" " + $0 + " ") }
        }
    }

    private static let workTopics: [Topic] = {
        let url = Bundle.main.url(forResource: "meeting-topics", withExtension: "json")
            ?? Bundle.module.url(forResource: "meeting-topics", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode([Topic].self, from: data)) ?? []
    }()

    private static func words(in text: String) -> [Substring] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е").split { !$0.isLetter }
    }

    static func searchTerms(_ terms: [String]) -> (words: [String], topics: Set<String>) {
        var literal: [String] = []
        var categories = Set<String>()
        for term in terms {
            if let topic = workTopics.first(where: {
                $0.title.lowercased() == term || $0.searchWords?.contains(term) == true ||
                    $0.searchPrefixes?.contains(where: term.hasPrefix) == true
            }) {
                categories.insert(topic.title)
            } else {
                literal.append(term)
            }
        }
        return (literal, categories)
    }

    static func matchesSearchTopics(_ categories: Set<String>, fields: [String?]) -> Bool {
        guard !categories.isEmpty else { return true }
        let texts = fields.compactMap { $0 }.map { text in
            let terms = words(in: text)
            return (terms, " " + terms.joined(separator: " ") + " ")
        }
        return workTopics.filter { categories.contains($0.title) }.allSatisfy { topic in
            texts.contains { terms, phrase in
                return topic.matches(terms, phrase: phrase) || phrase == " " + topic.title.lowercased() + " "
            }
        }
    }

    static func title(topic: String?, text: String, context: String? = nil) -> String {
        let beginning = words(in: text).joined(separator: " ") + " "
        if let topic = workTopics.first(where: { topic in
            topic.actions?.contains { beginning.hasPrefix($0 + " ") } == true
        }) {
            return topic.title
        }
        let inferred = fallback(text)
        if inferred == "Финансы" { return "Финансы" }
        let explicit = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if explicit.caseInsensitiveCompare("Согласование и смета") == .orderedSame {
            return inferred ?? context.flatMap(fallback) ?? "Согласование"
        }
        if !explicit.isEmpty {
            return workTopics.first { $0.title.caseInsensitiveCompare(explicit) == .orderedSame }?.title ?? explicit
        }
        if let inferred { return inferred }
        if let context, let label = fallback(context) { return label }
        return ungrouped
    }

    private static func fallback(_ text: String) -> String? {
        let tokens = words(in: text)
        let phrase = " " + tokens.joined(separator: " ") + " "
        var matches = workTopics.filter { $0.matches(tokens, phrase: phrase) }
        if matches.contains(where: { $0.title == "Финансы" }) { return "Финансы" }
        if let match = zone?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            for group in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: group), in: text) {
                    return "Зона " + text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if matches.count > 1 { matches.removeAll { $0.title == "Согласование" } }
        return matches.count == 1 ? matches[0].title : nil
    }

    static func order(_ title: String) -> Int {
        if title == ungrouped { return workTopics.count + 1 }
        return workTopics.firstIndex { $0.title == title } ?? workTopics.count
    }
}

enum MeetingTopicEntry<Item: Identifiable>: Identifiable {
    case confirmed(Item)
    case proposed(Proposal)

    var id: String {
        switch self {
        case .confirmed(let item): return "confirmed-\(item.id)"
        case .proposed(let proposal): return "proposed-\(proposal.id)"
        }
    }

    static func rows(_ items: [Item], proposals: [Proposal]) -> [Self] {
        items.map(Self.confirmed) + proposals.map(Self.proposed)
    }

    static func proposalTopic(_ proposal: Proposal) -> String {
        MeetingTopics.title(topic: proposal.source?.topic, text: proposal.title ?? "",
                            context: [proposal.description, proposal.source?.quote].compactMap { $0 }.joined(separator: " "))
    }
}

struct MeetingTopicList<Row: Identifiable, Content: View>: View {
    let rows: [Row]
    let topic: (Row) -> String
    var visibleRange: Range<Int>? = nil
    @ViewBuilder let content: (Row) -> Content

    var body: some View {
        let labeled = rows.map { (row: $0, title: topic($0)) }
        let groups = Dictionary(grouping: labeled, by: { $0.title.lowercased() })
        let keys = groups.keys.sorted { lhs, rhs in
            let left = groups[lhs]![0].title
            let right = groups[rhs]![0].title
            let leftOrder = MeetingTopics.order(left)
            let rightOrder = MeetingTopics.order(right)
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return left.localizedStandardCompare(right) == .orderedAscending
        }

        let sections = visibleSections(keys: keys, groups: groups)
        ForEach(sections, id: \.key) { section in
            VStack(alignment: .leading, spacing: 6) {
                if section.title != MeetingTopics.ungrouped || groups.count > 1 || visibleRange != nil {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 2)
                }
                ForEach(section.rows, content: content)
            }
        }
    }

    private func visibleSections(keys: [String], groups: [String: [(row: Row, title: String)]])
        -> [(key: String, title: String, rows: [Row])] {
        var offset = 0
        return keys.compactMap { key in
            let group = groups[key]!
            let range = offset..<(offset + group.count)
            offset = range.upperBound
            let visible = visibleRange.map { range.clamped(to: $0) } ?? range
            guard !visible.isEmpty else { return nil }
            let first = visible.lowerBound - range.lowerBound
            let last = visible.upperBound - range.lowerBound
            return (key, group[0].title, group[first..<last].map(\.row))
        }
    }
}
