import Foundation

/// Matches web/mac/app.js canonical/matchesQuery, including exact labels and inclusive ranges.
public enum MatchQuery {
    public static func canonical(_ input: String) -> String {
        var s = input.uppercased().replacingOccurrences(of: "[\\s#_()]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[–—]", with: "-", options: .regularExpression)
        for (pattern, replacement) in [("^QUALIFICATIONS?|^QUALIFIER|^QUAL", "Q"), ("^QUARTERFINALS?", "QF"),
            ("^SEMIFINALS?", "SF"), ("^ROUNDOF16", "R16"), ("^FINALS?", "F"), ("^PRACTICE", "P")] {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }
    public static func matches(_ match: Match, query: String) -> Bool {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return query.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map(canonical).filter { !$0.isEmpty }.contains { t in
            if let r = t.range(of: "^Q[0-9]+-Q?[0-9]+$", options: .regularExpression), r == t.startIndex..<t.endIndex {
                let ends = t.split(separator: "-").compactMap { Int($0.replacingOccurrences(of: "Q", with: "")) }
                guard match.label.range(of: "^Q[0-9]+$", options: .regularExpression) != nil,
                      let n = Int(match.label.dropFirst()), ends.count == 2 else { return false }
                return n >= ends[0] && n <= ends[1]
            }
            if t.range(of: "^(?:Q[0-9]+|QF[0-9]+-[0-9]+|SF[0-9]+-[0-9]+|F[0-9]+-[0-9]+|R16[0-9]+-[0-9]+|P[0-9]+)$", options: .regularExpression) != nil {
                return match.label == t
            }
            return canonical(match.name).contains(t) || match.teams.contains { $0.uppercased().contains(t) }
        }
    }
}

/// Nil and empty values stay last even when descending; callers retain original order for ties.
public enum EmptyLast {
    public static func compare<T: Comparable>(_ a: T?, _ b: T?, order: SortOrder = .forward) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case (.some(let x), .some(let y)):
            if x == y { return .orderedSame }
            return (x < y) == (order == .forward) ? .orderedAscending : .orderedDescending
        }
    }
}

public struct OptionalLastComparator<Value: Comparable & Sendable>: SortComparator, Sendable {
    public var order: SortOrder
    public init(order: SortOrder = .forward) { self.order = order }
    public func compare(_ lhs: Value?, _ rhs: Value?) -> ComparisonResult { EmptyLast.compare(lhs, rhs, order: order) }
}
