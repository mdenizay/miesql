import AppKit
import SwiftUI
import MieSQLCore

/// The SQL editor: an `NSTextView` with syntax highlighting, a line-number ruler and
/// schema-aware word completion. AppKit rather than SwiftUI because a text view is where
/// the difference between "native" and "almost native" is most obvious.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var kind: DatabaseKind
    var fontSize: Double
    var showLineNumbers: Bool
    var wrapLines: Bool
    /// Table and column names offered alongside the SQL keywords.
    var completionWords: [String]
    var onRun: () -> Void
    var onRunSelection: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = SQLTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapLines
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onRun = onRun
        textView.onRunSelection = onRunSelection
        textView.completionProvider = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView

        textView.string = text
        context.coordinator.apply(configuration: self, to: textView)
        context.coordinator.highlight(textView)

        if showLineNumbers {
            let ruler = LineNumberRulerView(textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SQLTextView else { return }

        context.coordinator.parent = self
        textView.onRun = onRun
        textView.onRunSelection = onRunSelection

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let clamped = NSRange(
                location: min(selected.location, (text as NSString).length),
                length: 0
            )
            textView.setSelectedRange(clamped)
            context.coordinator.highlight(textView)
        }

        context.coordinator.apply(configuration: self, to: textView)

        let wantsRuler = showLineNumbers
        if wantsRuler, scrollView.verticalRulerView == nil {
            scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
            scrollView.hasVerticalRuler = true
        }
        scrollView.rulersVisible = wantsRuler
    }

    final class Coordinator: NSObject, NSTextViewDelegate, CompletionProviding {
        var parent: SQLEditorView
        weak var textView: SQLTextView?
        private var lastAppliedFontSize: Double = 0

        init(_ parent: SQLEditorView) {
            self.parent = parent
        }

        func apply(configuration: SQLEditorView, to textView: SQLTextView) {
            let font = Theme.editorFont(size: configuration.fontSize)
            if lastAppliedFontSize != configuration.fontSize {
                textView.font = font
                textView.typingAttributes[.font] = font
                lastAppliedFontSize = configuration.fontSize
                highlight(textView)
            }

            textView.textContainer?.widthTracksTextView = configuration.wrapLines
            if configuration.wrapLines {
                textView.textContainer?.containerSize = NSSize(
                    width: textView.enclosingScrollView?.contentSize.width ?? textView.frame.width,
                    height: .greatestFiniteMagnitude
                )
                textView.isHorizontallyResizable = false
            } else {
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: .greatestFiniteMagnitude
                )
                textView.isHorizontallyResizable = true
            }
            textView.enclosingScrollView?.hasHorizontalScroller = !configuration.wrapLines
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SQLTextView else { return }
            parent.text = textView.string
            highlight(textView)
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.needsDisplay = true
        }

        /// Re-colours the whole buffer. Fast enough for editor-sized scripts, and far
        /// simpler to reason about than incremental invalidation.
        func highlight(_ textView: SQLTextView) {
            guard let storage = textView.textStorage else { return }
            let appearance = textView.effectiveAppearance
            let full = NSRange(location: 0, length: storage.length)
            let font = Theme.editorFont(size: parent.fontSize)

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
            for token in SQLLexer.tokenize(textView.string, kind: parent.kind) {
                guard NSMaxRange(token.range) <= storage.length else { continue }
                let color = Theme.syntaxColor(for: token.kind, appearance: appearance)
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
                if token.kind == .keyword {
                    let bold = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .semibold)
                    storage.addAttribute(.font, value: bold, range: token.range)
                }
            }
            storage.endEditing()
        }

        // MARK: CompletionProviding

        func completionCandidates(forPartialWord word: String) -> [String] {
            let needle = word.lowercased()
            guard !needle.isEmpty else { return [] }

            let schemaMatches = parent.completionWords
                .filter { $0.lowercased().hasPrefix(needle) }
                .sorted()
            let keywordMatches = SQLKeywords.allWords
                .filter { $0.lowercased().hasPrefix(needle) }

            // Schema names first: they are what the user cannot remember.
            return Array((schemaMatches + keywordMatches).reduced(limit: 40))
        }
    }
}

private extension Array where Element == String {
    /// Removes duplicates, case-insensitively, keeping the first spelling seen.
    func reduced(limit: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in self {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                output.append(value)
                if output.count == limit { break }
            }
        }
        return output
    }
}

protocol CompletionProviding: AnyObject {
    func completionCandidates(forPartialWord word: String) -> [String]
}

/// Adds run shortcuts and word completion on top of `NSTextView`.
final class SQLTextView: NSTextView {
    var onRun: (() -> Void)?
    var onRunSelection: (() -> Void)?
    weak var completionProvider: (any CompletionProviding)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘↩ runs everything, ⇧⌘↩ runs just the selection — the pair most clients use.
        if modifiers == .command, event.keyCode == 36 {
            onRun?()
            return true
        }
        if modifiers == [.command, .shift], event.keyCode == 36 {
            onRunSelection?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertTab(_ sender: Any?) {
        // Spaces rather than a tab character, so SQL lines up the same everywhere.
        insertText("    ", replacementRange: selectedRange())
    }

    override var rangeForUserCompletion: NSRange {
        SQLLexer.wordRange(in: string, at: selectedRange().location) ?? super.rangeForUserCompletion
    }

    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String]? {
        let word = (string as NSString).substring(with: charRange)
        index?.pointee = 0
        return completionProvider?.completionCandidates(forPartialWord: word)
    }
}

/// A minimal line-number gutter.
final class LineNumberRulerView: NSRulerView {

    private weak var observedTextView: NSTextView?

    init(textView: NSTextView) {
        self.observedTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = observedTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let backgroundColor = NSColor.controlBackgroundColor
        backgroundColor.setFill()
        rect.fill()

        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        separator.lineWidth = 1
        separator.stroke()

        let text = textView.string as NSString
        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Count the newlines before the first visible character to know where to start.
        var lineNumber = 1
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: characterRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, textView.font!.pointSize - 2), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        var drawnFirstLine = false
        text.enumerateSubstrings(in: characterRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: container)
            let y = lineRect.minY + textView.textContainerInset.height - visibleRect.minY

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: self.bounds.maxX - size.width - 6, y: y),
                withAttributes: attributes
            )
            lineNumber += 1
            drawnFirstLine = true
        }

        // An empty buffer still shows line 1.
        if !drawnFirstLine {
            ("1" as NSString).draw(
                at: NSPoint(x: bounds.maxX - 14, y: textView.textContainerInset.height),
                withAttributes: attributes
            )
        }
    }
}
