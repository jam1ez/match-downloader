import Foundation

struct SortPreference: Codable {
    var column: String
    var reverse: Bool
    static func encode<Row>(_ sort: [KeyPathComparator<Row>], choices: [String: KeyPathComparator<Row>]) -> String {
        let values = sort.compactMap { comparator -> SortPreference? in
            guard let key = choices.first(where: { $0.value.keyPath == comparator.keyPath })?.key else { return nil }
            return SortPreference(column: key, reverse: comparator.order == .reverse)
        }
        return (try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "[]"
    }
    static func decode<Row>(_ text: String, choices: [String: KeyPathComparator<Row>], fallback: [KeyPathComparator<Row>]) -> [KeyPathComparator<Row>] {
        guard let values = try? JSONDecoder().decode([SortPreference].self, from: Data(text.utf8)) else { return fallback }
        let sort = values.compactMap { value -> KeyPathComparator<Row>? in
            guard var comparator = choices[value.column] else { return nil }
            comparator.order = value.reverse ? .reverse : .forward; return comparator
        }
        return sort.isEmpty ? fallback : sort
    }
}
