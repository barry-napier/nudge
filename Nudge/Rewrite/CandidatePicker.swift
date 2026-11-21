import Foundation

/// Apple's small model is random: the same request sometimes comes back
/// barely changed. For some actions Nudge asks for a few versions at once
/// and keeps the best one.
enum CandidatePicker {
    enum Strategy: Sendable {
        /// One version. For fixes, where small changes are the point.
        case single
        /// Keep the version that changed the wording most. For tone changes.
        case mostChanged
        /// Keep the shortest version. For making text concise.
        case shortest

        var count: Int { self == .single ? 1 : 3 }
    }

    static func pick(_ candidates: [String], original: String, strategy: Strategy) -> String? {
        let usable = candidates.filter { !$0.isEmpty }
        // Never pick a version that lost a number from the original.
        let faithful = usable.filter { keepsNumbers(of: original, in: $0) }
        let pool = faithful.isEmpty ? usable : faithful
        switch strategy {
        case .single:
            return pool.first
        case .mostChanged:
            return pool.max { changeRatio(original, $0) < changeRatio(original, $1) }
        case .shortest:
            return pool.min { $0.count < $1.count }
        }
    }

    /// Share of words that differ, from 0 (same words) to 1 (all new).
    static func changeRatio(_ a: String, _ b: String) -> Double {
        let x = words(a)
        let y = words(b)
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0..<x.count {
            for j in 0..<y.count {
                table[i + 1][j + 1] = x[i] == y[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
            }
        }
        return 1 - Double(table[x.count][y.count]) / Double(max(x.count, y.count))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func keepsNumbers(of original: String, in candidate: String) -> Bool {
        let numbers = original.matches(of: /\d+/).map { String($0.output) }
        return numbers.allSatisfy { candidate.contains($0) }
    }
}
