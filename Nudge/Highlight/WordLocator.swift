import ApplicationServices

/// A changed word and where it is on screen, in Accessibility coordinates.
struct WordMark {
    let element: AXUIElement
    let range: CFRange
    let rect: CGRect
}

/// Asks the other app where the changed words are drawn.
@MainActor
enum WordLocator {
    /// These questions run on the main thread, which also passes on every key
    /// press. A slow app must never make typing lag, so it gets very little time.
    private static let timeBudget: Duration = .milliseconds(80)
    private static let answerTimeout: Float = 0.06
    private static let maxNodes = 400
    private static let maxDepth = 16

    static func marks(original: String, rewrite: String, location: Int?, in field: AXUIElement) -> [WordMark] {
        let deadline = ContinuousClock.now + timeBudget
        AXUIElementSetMessagingTimeout(field, answerTimeout)
        // Put back the timeout that rewrites and Undo rely on.
        defer { AXUIElementSetMessagingTimeout(field, 1.0) }
        guard let value = AX.string(field, kAXValueAttribute) else { return [] }

        // Most fields know where all of their own text is.
        let spans = ChangeMap.spans(original: original, rewrite: rewrite, pieces: [value], location: location)
        guard !spans.isEmpty else { return [] }
        let direct = measure(spans, pieces: [(field, value)], deadline: deadline)
        if direct.count == spans.count || ContinuousClock.now >= deadline { return tidy(direct) }

        // Chrome and Electron rich text boxes only know it piece by piece.
        let pieces = textPieces(of: field, deadline: deadline)
        let pieceSpans = ChangeMap.spans(
            original: original, rewrite: rewrite, pieces: pieces.map(\.text), location: location)
        let byPiece = measure(pieceSpans, pieces: pieces, deadline: deadline)
        return tidy(byPiece.count > direct.count ? byPiece : direct)
    }

    /// True while a mark still sits over its word.
    static func isInPlace(_ mark: WordMark) -> Bool {
        AXUIElementSetMessagingTimeout(mark.element, answerTimeout)
        defer { AXUIElementSetMessagingTimeout(mark.element, 1.0) }
        guard let now = AX.bounds(mark.element, range: mark.range) else { return false }
        return abs(now.minX - mark.rect.minX) < 1.5 && abs(now.minY - mark.rect.minY) < 1.5
            && abs(now.width - mark.rect.width) < 1.5
    }

    private static func measure(
        _ spans: [ChangeMap.Span], pieces: [(element: AXUIElement, text: String)], deadline: ContinuousClock.Instant
    ) -> [WordMark] {
        var marks: [WordMark] = []
        for span in spans {
            guard ContinuousClock.now < deadline else { break }
            let piece = pieces[span.piece]
            let range = CFRange(location: span.range.location, length: span.range.length)
            // Some apps count characters differently. Never mark the wrong word.
            if let actual = AX.string(piece.element, range: range),
               actual != (piece.text as NSString).substring(with: span.range) { continue }
            guard let rect = AX.bounds(piece.element, range: range), rect.width >= 1, rect.height >= 4 else { continue }
            marks.append(WordMark(element: piece.element, range: range, rect: rect))
        }
        return marks
    }

    private static func textPieces(
        of field: AXUIElement, deadline: ContinuousClock.Instant
    ) -> [(element: AXUIElement, text: String)] {
        var pieces: [(element: AXUIElement, text: String)] = []
        var visited = 0
        func visit(_ node: AXUIElement, depth: Int) {
            visited += 1
            guard visited <= maxNodes, depth <= maxDepth, ContinuousClock.now < deadline else { return }
            AXUIElementSetMessagingTimeout(node, answerTimeout)
            if AX.string(node, kAXRoleAttribute) == kAXStaticTextRole,
               let text = AX.string(node, kAXValueAttribute) {
                pieces.append((node, text))
                return
            }
            for child in AX.children(node) { visit(child, depth: depth + 1) }
        }
        for child in AX.children(field) { visit(child, depth: 1) }
        return pieces
    }

    /// A word broken over two lines reports one big box round both. Drop those.
    private static func tidy(_ marks: [WordMark]) -> [WordMark] {
        guard let line = marks.map(\.rect.height).min() else { return [] }
        return marks.filter { $0.rect.height < line * 1.8 }
    }
}
