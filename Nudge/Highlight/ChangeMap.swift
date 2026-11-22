import Foundation

/// Works out which words a rewrite changed and where they sit in a field.
///
/// Fields disagree about spaces, line breaks and curly quotes, and some split
/// their text into pieces. So positions are matched on the visible characters
/// only, with straight quotes, across all the pieces.
enum ChangeMap {
    /// A UTF-16 range inside one piece of a field's text.
    struct Span: Equatable {
        let piece: Int
        let range: NSRange
    }

    /// The most words marked at once. Each one costs a question to the other app.
    static let maxWords = 200

    /// Where each new or changed word is.
    /// - Parameters:
    ///   - pieces: The field's text, whole or in pieces, in reading order.
    ///   - location: Where the rewrite starts in the whole text, in UTF-16
    ///     units. It picks between identical copies of the same words.
    /// - Returns: Empty when nothing changed or the rewrite cannot be found.
    static func spans(original: String, rewrite: String, pieces: [String], location: Int?) -> [Span] {
        let words = changedWords(original: original, rewrite: rewrite)
        guard !words.isEmpty else { return [] }

        var units: [UInt16] = []
        var places: [(piece: Int, offset: Int)] = []
        var wanted: Int?  // `location`, counted in visible characters
        var position = 0
        for (index, piece) in pieces.enumerated() {
            for (offset, unit) in piece.utf16.enumerated() {
                if position == location { wanted = units.count }
                position += 1
                guard let visible = visible(unit) else { continue }
                units.append(visible)
                places.append((index, offset))
            }
        }
        let target = rewrite.utf16.compactMap(visible)
        guard let start = find(target, in: units, near: wanted) else { return [] }

        var spans: [Span] = []
        for word in words.prefix(maxWords) {
            let wordPlaces = places[(start + word.lowerBound)..<(start + word.upperBound)]
            // One word can cross pieces, for example when half of it is bold.
            var first: (piece: Int, offset: Int)?
            var last = 0
            for place in wordPlaces {
                if let current = first, current.piece != place.piece {
                    spans.append(Span(piece: current.piece, range: NSRange(location: current.offset, length: last - current.offset + 1)))
                    first = nil
                }
                if first == nil { first = place }
                last = place.offset
            }
            if let first {
                spans.append(Span(piece: first.piece, range: NSRange(location: first.offset, length: last - first.offset + 1)))
            }
        }
        return spans
    }

    /// The changed words, as ranges of the rewrite's visible characters.
    static func changedWords(original: String, rewrite: String) -> [Range<Int>] {
        let old = words(original)
        let new = words(rewrite)
        var changed = Set<Int>()
        for case .insert(let offset, _, _) in new.difference(from: old) {
            changed.insert(offset)
        }
        var result: [Range<Int>] = []
        var start = 0
        for (index, word) in new.enumerated() {
            if changed.contains(index) { result.append(start..<(start + word.count)) }
            start += word.count
        }
        return result
    }

    private static func words(_ text: String) -> [[UInt16]] {
        text.utf16
            .split(whereSeparator: isSpace)
            .map { $0.compactMap(visible) }
            .filter { !$0.isEmpty }
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    /// nil for characters nobody sees. Curly quotes become straight ones.
    private static func visible(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x200B, 0xFEFF, 0xFFFC: nil
        case 0x2018, 0x2019: 0x27
        case 0x201C, 0x201D: 0x22
        default: isSpace(unit) ? nil : unit
        }
    }

    /// The copy of `target` nearest `wanted`. With no hint there must be only
    /// one copy, so the wrong one is never marked.
    private static func find(_ target: [UInt16], in units: [UInt16], near wanted: Int?) -> Int? {
        guard let first = target.first, target.count <= units.count else { return nil }
        var found: [Int] = []
        for start in 0...(units.count - target.count)
        where units[start] == first && units[start..<(start + target.count)].elementsEqual(target) {
            found.append(start)
        }
        guard let wanted else { return found.count == 1 ? found.first : nil }
        return found.min { abs($0 - wanted) < abs($1 - wanted) }
    }
}
