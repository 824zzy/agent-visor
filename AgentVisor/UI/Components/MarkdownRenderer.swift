//
//  MarkdownRenderer.swift
//  AgentVisor
//
//  Markdown renderer using swift-markdown for efficient parsing
//

import AppKit
import AgentVisorCore
import Highlightr
import Markdown
import os.log
import SwiftUI

// MARK: - Document Cache

/// Caches parsed markdown documents to avoid re-parsing
private final class DocumentCache: @unchecked Sendable {
    static let shared = DocumentCache()
    private var cache: [String: Document] = [:]
    private let lock = NSLock()
    private let maxSize = 100

    func document(for text: String) -> Document {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[text] {
            return cached
        }
        let prepared = MarkdownPreprocessor.transform(text)
        let doc = Document(parsing: prepared, options: [.parseBlockDirectives, .parseSymbolLinks])
        if cache.count >= maxSize {
            cache.removeAll()
        }
        cache[text] = doc
        return doc
    }
}

// MARK: - Markdown Preprocessor

/// Pre-transforms raw markdown so the renderer matches Claude Code's terminal
/// output for a few decorative idioms swift-markdown doesn't handle natively.
private enum MarkdownPreprocessor {
    /// Box-drawing + ASCII chars Claude tends to use as horizontal rules.
    private static let dividerChars: Set<Character> = [
        "\u{2500}", "\u{2501}", "\u{2550}", // ─ ━ ═
        "-", "=", "_"
    ]

    /// Promote `` `★ Label ──────────` `` and `` `──────────` `` lines to a
    /// real heading + thematic break. Claude Code renders these as block-level
    /// dividers; without this, swift-markdown leaves them as one inline-code
    /// run that flows into the next paragraph.
    static func transform(_ text: String) -> String {
        // Cheap fast-path: nothing to do unless the source has a backtick.
        guard text.contains("`") else { return text }

        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 7,
                  trimmed.hasPrefix("`"),
                  trimmed.hasSuffix("`") else {
                output.append(line)
                continue
            }
            let content = String(trimmed.dropFirst().dropLast())
            // A second backtick inside means we're not looking at a single
            // inline-code span; bail out and let swift-markdown handle it.
            if content.contains("`") {
                output.append(line)
                continue
            }
            let dashCount = content.reduce(into: 0) { count, ch in
                if dividerChars.contains(ch) { count += 1 }
            }
            guard dashCount >= 5,
                  Double(dashCount) / Double(content.count) >= 0.5 else {
                output.append(line)
                continue
            }

            let label = String(content.filter { !dividerChars.contains($0) })
                .trimmingCharacters(in: .whitespaces)

            output.append("")
            if !label.isEmpty {
                output.append("**\(label)**")
            }
            output.append("---")
            output.append("")
        }

        return output.joined(separator: "\n")
    }
}

// MARK: - Markdown Text View

/// Renders markdown text with inline formatting using swift-markdown
struct MarkdownText: View {
    let text: String
    let baseColor: Color
    let fontSize: CGFloat

    /// Multiplied into `fontSize` so every downstream AttributedString /
    /// SwiftUI Text picks up the scaled size without each call site
    /// having to thread the multiplier through.
    @Environment(\.chatFontScale) private var chatFontScale

    /// Observe the appearance selector so theme flips invalidate this
    /// view's body and re-evaluate downstream `Catppuccin.*` reads.
    /// Per-cell NSHostingControllers (used in the window-mode chat
    /// table) are graph-isolated and don't inherit invalidations from
    /// ancestor SwiftUI views, so each MarkdownText needs its own
    /// observation. Without this, code blocks rendered via
    /// `SyntaxHighlighterCache` keep painting in the previous palette
    /// (cache-hit by language+code, but that key is by *resolved*
    /// flavor — so refreshing the body is what's needed to re-key).
    @ObservedObject private var appearance = AppearanceSelector.shared

    private var effectiveFontSize: CGFloat { fontSize * chatFontScale }

    private let document: Document

    init(_ text: String, color: Color = Catppuccin.text, fontSize: CGFloat = 13) {
        self.text = text
        self.baseColor = color
        self.fontSize = fontSize
        self.document = DocumentCache.shared.document(for: text)
    }

    var body: some View {
        let children = Array(document.children)
        if children.isEmpty {
            SwiftUI.Text(text)
                .foregroundColor(baseColor)
                .font(.system(size: effectiveFontSize))
        } else {
            // Group consecutive flattenable blocks (paragraphs, lists, headings,
            // dividers, block quotes) into a single Text(AttributedString) so
            // selection drags continuously across them. Code blocks and tables
            // can't be expressed as inline AttributedString, so they break the
            // run and selection stops there.
            let groups = MarkdownText.makeBlockGroups(children)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    BlockGroupView(group: group, baseColor: baseColor, fontSize: effectiveFontSize)
                }
            }
        }
    }

    static func makeBlockGroups(_ blocks: [Markup]) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var pending: [Markup] = []
        for block in blocks {
            if isFlattenable(block) {
                pending.append(block)
            } else {
                if !pending.isEmpty {
                    groups.append(.flat(pending))
                    pending = []
                }
                groups.append(.opaque(block))
            }
        }
        if !pending.isEmpty {
            groups.append(.flat(pending))
        }
        return groups
    }

    private static func isFlattenable(_ block: Markup) -> Bool {
        block is Paragraph
            || block is Heading
            || block is UnorderedList
            || block is OrderedList
            || block is BlockQuote
            || block is ThematicBreak
    }
}

// MARK: - Block Group

enum BlockGroup {
    /// Run of blocks that fold into one AttributedString.
    case flat([Markup])
    /// Block that needs its own SwiftUI view (code block, table, unknown).
    case opaque(Markup)
}

private struct BlockGroupView: View {
    let group: BlockGroup
    let baseColor: Color
    let fontSize: CGFloat

    var body: some View {
        switch group {
        case .flat(let blocks):
            let pieces = AttributedMarkdownBuilder(baseColor: baseColor, fontSize: fontSize)
                .build(blocks: blocks)
            MarkdownPiecesText(pieces: pieces)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .opaque(let block):
            OpaqueBlockView(markup: block, baseColor: baseColor, fontSize: fontSize)
        }
    }
}

private struct OpaqueBlockView: View {
    let markup: Markup
    let baseColor: Color
    let fontSize: CGFloat

    var body: some View {
        if let codeBlock = markup as? CodeBlock {
            CodeBlockView(code: codeBlock.code, language: codeBlock.language)
        } else if let table = markup as? Markdown.Table {
            MarkdownTableView(table: table, baseColor: baseColor, fontSize: fontSize)
        } else {
            // Unknown block type: best-effort attributed render so nothing
            // gets silently dropped.
            let pieces = AttributedMarkdownBuilder(baseColor: baseColor, fontSize: fontSize)
                .build(blocks: [markup])
            MarkdownPiecesText(pieces: pieces)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Attributed Markdown Builder

/// Inline traits accumulate as we recurse through nested inline markup
/// (e.g. **bold with `code`**). Each leaf Text/InlineCode realizes the
/// final font + color from whatever traits its ancestors set.
private struct InlineTraits {
    var fontSize: CGFloat
    var foregroundColor: Color
    var bold: Bool = false
    var italic: Bool = false
    var monospace: Bool = false
    var strikethrough: Bool = false
    var underline: Bool = false
    var linkURL: String? = nil
    /// When non-nil, paint a subtle filled chip behind the run.
    /// Used by inline `code` spans so they read as discrete tokens
    /// instead of blending into surrounding prose.
    var backgroundColor: Color? = nil
}

private struct MarkdownFontIntent: Hashable, Codable, Sendable {
    let fontSize: Double
    let bold: Bool
    let italic: Bool
    let monospace: Bool

    init(traits: InlineTraits) {
        self.fontSize = Double(traits.fontSize)
        self.bold = traits.bold
        self.italic = traits.italic
        self.monospace = traits.monospace
    }
}

private enum MarkdownFontIntentAttribute: Foundation.AttributedStringKey {
    typealias Value = MarkdownFontIntent
    static let name = AppBranding.loggerSubsystem + ".markdown.fontIntent"
}

@MainActor
private enum MarkdownFontFactory {
    static func makeNSFont(intent: MarkdownFontIntent) -> NSFont {
        let size = CGFloat(intent.fontSize)
        let base: NSFont
        if intent.monospace {
            base = NSFont.monospacedSystemFont(
                ofSize: size,
                weight: intent.bold ? .semibold : .regular
            )
        } else {
            base = NSFont.systemFont(
                ofSize: size,
                weight: intent.bold ? .semibold : .regular
            )
        }
        if intent.italic {
            let manager = NSFontManager.shared
            return manager.convert(base, toHaveTrait: .italicFontMask)
        }
        return base
    }
}

/// Inline render output piece. Most pieces are `.text` (plain attributed
/// strings, joined trivially with `+`); math segments emit `.image`
/// pieces because SwiftUI's `Text(AttributedString)` doesn't render
/// `NSTextAttachment` images. The view layer folds piece lists into a
/// SwiftUI `Text` chain via the `Text + Text` operator, which DOES
/// support `Text(Image(...))` for inline images.
@MainActor
enum MarkdownInlinePiece {
    case text(AttributedString)
    case image(NSImage)

    /// AppKit-keyed projection of `.text(AttributedString)` for use
    /// in NSTextView-backed renderers. Translates SwiftUI's
    /// `foregroundColor: Color` and `font: Font` into AppKit's
    /// `NSColor` / `NSFont` keys; otherwise NSTextView ignores them
    /// (default system black, default 13pt). For `.image` pieces,
    /// returns an NSAttributedString containing an NSTextAttachment.
    var asNSAttributedString: NSAttributedString {
        switch self {
        case .text(let attr):
            return MarkdownInlinePiece.translateToAppKit(attr)
        case .image(let img):
            let attachment = NSTextAttachment()
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: img)
            return NSAttributedString(attachment: attachment)
        }
    }

    private static func translateToAppKit(_ attr: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in attr.runs {
            let substr = String(attr[run.range].characters)
            var ns: [NSAttributedString.Key: Any] = [:]
            if let color = run.foregroundColor {
                ns[.foregroundColor] = NSColor(color)
            }
            if let bg = run.backgroundColor {
                ns[.backgroundColor] = NSColor(bg)
            }
            if let fontIntent = run[MarkdownFontIntentAttribute.self] {
                ns[.font] = MarkdownFontFactory.makeNSFont(intent: fontIntent)
            } else {
                ns[.font] = NSFont.systemFont(ofSize: 13)
            }
            if run.appKit.underlineStyle == .single {
                ns[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.appKit.strikethroughStyle == .single {
                ns[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                ns[.link] = link
            }
            result.append(NSAttributedString(string: substr, attributes: ns))
        }
        return result
    }
}

extension Array where Element == MarkdownInlinePiece {
    /// Append text to the trailing piece if it's text too, otherwise
    /// add a new text piece. Keeps the piece count low so the eventual
    /// `Text + Text` fold isn't longer than necessary.
    mutating func appendText(_ s: AttributedString) {
        if case .text(var last)? = self.last {
            last += s
            self[self.count - 1] = .text(last)
        } else {
            append(.text(s))
        }
    }
}

@MainActor
private struct AttributedMarkdownBuilder {
    let baseColor: Color
    let fontSize: CGFloat

    private var defaultTraits: InlineTraits {
        InlineTraits(fontSize: fontSize, foregroundColor: baseColor)
    }

    func build(blocks: [Markup]) -> [MarkdownInlinePiece] {
        var result: [MarkdownInlinePiece] = []
        for (i, block) in blocks.enumerated() {
            if i > 0 {
                // Inter-block separator. The full `"\n\n"` reads as a
                // double blank line (~38pt at 13pt body, .lineSpacing(4)).
                // A bare `"\n"` collapses too far — headings butt into the
                // following paragraph. Compromise: one full line break,
                // then a second empty line at ~half the body font so it
                // adds visual breathing without doubling the gap.
                var spacerTraits = defaultTraits
                spacerTraits.fontSize = max(6, fontSize * 0.5)
                result.appendText(plain("\n", traits: defaultTraits))
                result.appendText(plain("\n", traits: spacerTraits))
            }
            result.append(contentsOf: renderBlock(block))
        }
        return result
    }

    private func renderBlock(_ block: Markup) -> [MarkdownInlinePiece] {
        if let para = block as? Paragraph {
            return renderInlines(Array(para.inlineChildren), traits: defaultTraits)
        }
        if let heading = block as? Heading {
            return renderHeading(heading)
        }
        if let list = block as? UnorderedList {
            return renderUnorderedList(list)
        }
        if let list = block as? OrderedList {
            return renderOrderedList(list)
        }
        if let quote = block as? BlockQuote {
            return renderBlockQuote(quote)
        }
        if block is ThematicBreak {
            // Render dividers as a row of box-drawing characters so they're
            // selectable and don't break the surrounding flat run.
            var traits = defaultTraits
            traits.foregroundColor = baseColor.opacity(0.3)
            return [.text(plain(String(repeating: "─", count: 32), traits: traits))]
        }
        // Last-resort fallback: plain markdown source, dimmed.
        var traits = defaultTraits
        traits.foregroundColor = baseColor.opacity(0.7)
        return [.text(plain(block.format(), traits: traits))]
    }

    private func renderHeading(_ heading: Heading) -> [MarkdownInlinePiece] {
        var traits = defaultTraits
        traits.bold = true
        traits.foregroundColor = ChatTheme.heading
        switch heading.level {
        case 1:
            traits.fontSize = fontSize + 4
            traits.italic = true
            traits.underline = true
        case 2:
            traits.fontSize = fontSize + 2
        default:
            traits.foregroundColor = ChatTheme.heading.opacity(0.85)
        }
        // No trailing spacer — `build(blocks:)` inserts one full +
        // one half-size line break BETWEEN every block pair, which
        // is enough breathing room after a heading. Adding another
        // half-line here was producing a ~38pt+ visual gap between
        // every heading and its first paragraph (reported as a
        // persistent layout bug).
        return renderInlines(Array(heading.inlineChildren), traits: traits)
    }

    private func renderUnorderedList(_ list: UnorderedList) -> [MarkdownInlinePiece] {
        var result: [MarkdownInlinePiece] = []
        let items = Array(list.listItems)
        var bulletTraits = defaultTraits
        bulletTraits.foregroundColor = ChatTheme.bullet
        for (i, item) in items.enumerated() {
            if i > 0 { result.appendText(plain("\n", traits: defaultTraits)) }
            result.appendText(plain("•  ", traits: bulletTraits))
            result.append(contentsOf: renderListItem(item))
        }
        return result
    }

    private func renderOrderedList(_ list: OrderedList) -> [MarkdownInlinePiece] {
        var result: [MarkdownInlinePiece] = []
        let items = Array(list.listItems)
        var prefixTraits = defaultTraits
        prefixTraits.foregroundColor = ChatTheme.bullet
        for (i, item) in items.enumerated() {
            if i > 0 { result.appendText(plain("\n", traits: defaultTraits)) }
            result.appendText(plain("\(i + 1).  ", traits: prefixTraits))
            result.append(contentsOf: renderListItem(item))
        }
        return result
    }

    private func renderListItem(_ item: ListItem) -> [MarkdownInlinePiece] {
        var result: [MarkdownInlinePiece] = []
        let children = Array(item.children)
        for (i, child) in children.enumerated() {
            if i > 0 { result.appendText(plain("\n   ", traits: defaultTraits)) }
            if let para = child as? Paragraph {
                result.append(contentsOf: renderInlines(Array(para.inlineChildren), traits: defaultTraits))
            } else {
                result.append(contentsOf: renderBlock(child))
            }
        }
        return result
    }

    private func renderBlockQuote(_ quote: BlockQuote) -> [MarkdownInlinePiece] {
        var traits = defaultTraits
        traits.italic = true
        traits.foregroundColor = baseColor.opacity(0.7)
        var result: [MarkdownInlinePiece] = []
        let children = Array(quote.children)
        for (i, child) in children.enumerated() {
            if i > 0 { result.appendText(plain("\n", traits: traits)) }
            if let para = child as? Paragraph {
                result.append(contentsOf: renderInlines(Array(para.inlineChildren), traits: traits))
            } else {
                result.append(contentsOf: renderBlock(child))
            }
        }
        return result
    }

    fileprivate func renderInlines(_ inlines: [InlineMarkup], traits: InlineTraits) -> [MarkdownInlinePiece] {
        var result: [MarkdownInlinePiece] = []
        for inline in inlines {
            result.append(contentsOf: renderInline(inline, traits: traits))
        }
        return result
    }

    private func renderInline(_ inline: InlineMarkup, traits: InlineTraits) -> [MarkdownInlinePiece] {
        if let text = inline as? Markdown.Text {
            return renderTextWithLaTeX(text.string, traits: traits)
        }
        if let strong = inline as? Strong {
            var nested = traits
            nested.bold = true
            return renderInlines(Array(strong.inlineChildren), traits: nested)
        }
        if let emphasis = inline as? Emphasis {
            var nested = traits
            nested.italic = true
            return renderInlines(Array(emphasis.inlineChildren), traits: nested)
        }
        if let code = inline as? InlineCode {
            var nested = traits
            nested.monospace = true
            nested.foregroundColor = ChatTheme.inlineCode
            return [.text(plain(code.code, traits: nested))]
        }
        if let link = inline as? Markdown.Link {
            var nested = traits
            nested.foregroundColor = Catppuccin.sapphire
            nested.underline = true
            nested.linkURL = link.destination
            return renderInlines(Array(link.inlineChildren), traits: nested)
        }
        if let strike = inline as? Strikethrough {
            var nested = traits
            nested.strikethrough = true
            return renderInlines(Array(strike.inlineChildren), traits: nested)
        }
        if inline is SoftBreak {
            return [.text(plain(" ", traits: traits))]
        }
        if inline is LineBreak {
            return [.text(plain("\n", traits: traits))]
        }
        return [.text(plain(inline.plainText, traits: traits))]
    }

    /// Apply `LaTeXRangeExtractor` to a literal text run, replacing
    /// `$..$` and `$$..$$` spans with `.image` pieces backed by
    /// SwiftMath-rendered NSImages. Falls back to plain text if
    /// SwiftMath rejects the formula. The fast path (no math) emits
    /// a single `.text` piece.
    private func renderTextWithLaTeX(_ string: String, traits: InlineTraits) -> [MarkdownInlinePiece] {
        let segments = LaTeXRangeExtractor.segments(in: string)
        if segments.count == 1, case .text(let only) = segments[0] {
            return [.text(plain(only, traits: traits))]
        }
        var result: [MarkdownInlinePiece] = []
        for segment in segments {
            switch segment {
            case .text(let s):
                result.appendText(plain(s, traits: traits))
            case .inlineMath(let latex):
                appendMath(into: &result, latex: latex, traits: traits, mode: .inline, fallbackSource: "$\(latex)$")
            case .displayMath(let latex):
                appendMath(into: &result, latex: latex, traits: traits, mode: .display, fallbackSource: "$$\(latex)$$")
            }
        }
        return result
    }

    /// Render a math segment via SwiftMath, append as an `.image`
    /// piece. Falls back to a literal `.text` piece when SwiftMath
    /// rejects the source so the user still sees what they wrote.
    private func appendMath(
        into result: inout [MarkdownInlinePiece],
        latex: String,
        traits: InlineTraits,
        mode: LaTeXRenderer.Mode,
        fallbackSource: String
    ) {
        let nsColor = NSColor(traits.foregroundColor)
        let scaled: CGFloat = (mode == .display) ? traits.fontSize * 1.4 : traits.fontSize
        guard let image = LaTeXRenderer.image(
            latex: latex,
            fontSize: scaled,
            color: nsColor,
            mode: mode
        ) else {
            result.appendText(plain(fallbackSource, traits: traits))
            return
        }
        result.append(.image(image))
    }

    fileprivate func plain(_ string: String, traits: InlineTraits) -> AttributedString {
        var s = AttributedString(string)
        // SwiftUI scope (used by SwiftUI Text(AttributedString)
        // rendering path).
        s.foregroundColor = traits.foregroundColor
        s.font = makeFont(traits: traits)
        if traits.strikethrough { s.strikethroughStyle = .single }
        if traits.underline { s.underlineStyle = .single }
        if let bg = traits.backgroundColor { s.backgroundColor = bg }
        if let urlString = traits.linkURL, let url = URL(string: urlString) {
            s.link = url
        }
        // AppKit scope — duplicate of the same color/style intent, keyed
        // under AppKit attribute keys so the NSTextView-backed renderer
        // (`SelectableMarkdownText`) can read them. Font uses a custom
        // Sendable intent attribute and is materialized as NSFont only
        // during AppKit translation.
        s.appKit.foregroundColor = NSColor(traits.foregroundColor)
        s[MarkdownFontIntentAttribute.self] = MarkdownFontIntent(traits: traits)
        if traits.strikethrough { s.appKit.strikethroughStyle = .single }
        if traits.underline { s.appKit.underlineStyle = .single }
        if let bg = traits.backgroundColor { s.appKit.backgroundColor = NSColor(bg) }
        return s
    }

    private func makeFont(traits: InlineTraits) -> Font {
        var font: Font = .system(
            size: traits.fontSize,
            design: traits.monospace ? .monospaced : .default
        )
        if traits.bold { font = font.bold() }
        if traits.italic { font = font.italic() }
        return font
    }

}

// MARK: - Pieces View

/// Folds a `[MarkdownInlinePiece]` into a single SwiftUI `Text` via
/// `+` concatenation. `Text + Text(Image(nsImage:))` is the only
/// SwiftUI idiom that places a real raster image inline in a wrapping
/// text run — `Text(AttributedString)` doesn't handle
/// `NSTextAttachment` images, which is why we restructured the
/// pipeline to emit pieces instead of a single AttributedString.
struct MarkdownPiecesText: View {
    let pieces: [MarkdownInlinePiece]

    var body: some View {
        // Reverted from `SelectableMarkdownText` (NSTextView-backed)
        // back to a SwiftUI `Text + Text` chain. The NSTextView
        // approach LOOKED right architecturally — selection at
        // AppKit layer, no SelectionOverlay cascade — but in
        // practice SwiftUI's LazyVStack maintains DisplayList.Item /
        // Update.Action arrays per realized NSViewRepresentable
        // child, and reallocates them on every layout pass. With
        // 100 NSTextViews in the chat, every graph tick (window
        // resize, sidebar drag, scroll, streamTick, anything)
        // triggered a `_ArrayBuffer._consumeAndCreateNew` storm in
        // `LazyLayoutViewCache.updatePrefetchPhases` — sample-
        // confirmed 99% CPU pin in `flushObservers` running graph
        // updates outside any mouse event. Fixing one cascade kept
        // surfacing another underneath. NSViewRepresentable inside
        // a long LazyVStack is fundamentally too expensive for
        // SwiftUI's update model on this scale.
        // Trade-off accepted: chat text is no longer selectable in
        // window mode. Stability over selection until we either
        // (a) move to a single NSTextView for the entire chat
        // (Slack pattern), or (b) ship per-bubble selection only
        // on click (focus-driven mount, bounded blast radius).
        // See [[feedback-nstextview-chat-selection]] for the full
        // post-mortem.
        var chain = SwiftUI.Text("")
        for piece in pieces {
            switch piece {
            case .text(let attr):
                chain = chain + SwiftUI.Text(attr)
            case .image(let img):
                chain = chain + SwiftUI.Text(Image(nsImage: img))
            }
        }
        return chain
    }
}

// MARK: - Table View

private struct MarkdownTableView: View {
    let table: Markdown.Table
    let baseColor: Color
    let fontSize: CGFloat

    var body: some View {
        let alignments = table.columnAlignments
        HorizontalScrollPassthrough {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.head.cells.enumerated()), id: \.offset) { colIdx, cell in
                        cellView(cell, colIdx: colIdx, alignments: alignments, isHeader: true)
                    }
                }
                ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { colIdx, cell in
                            cellView(cell, colIdx: colIdx, alignments: alignments, isHeader: false)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cellView(
        _ cell: Markdown.Table.Cell,
        colIdx: Int,
        alignments: [Markdown.Table.ColumnAlignment?],
        isHeader: Bool
    ) -> some View {
        let align: HorizontalAlignment = {
            guard colIdx < alignments.count, let a = alignments[colIdx] else { return .leading }
            switch a {
            case .left: return .leading
            case .center: return .center
            case .right: return .trailing
            }
        }()

        let traits: InlineTraits = {
            var t = InlineTraits(fontSize: fontSize, foregroundColor: baseColor)
            if isHeader { t.bold = true }
            return t
        }()
        let pieces = AttributedMarkdownBuilder(baseColor: baseColor, fontSize: fontSize)
            .renderInlines(Array(cell.inlineChildren), traits: traits)

        return MarkdownPiecesText(pieces: pieces)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: align, vertical: .center))
            .overlay(
                Rectangle()
                    .stroke(baseColor.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Syntax Highlighter Cache

/// Map a file path's extension to the Highlightr language id. Returns nil
/// for paths we don't have explicit support for so the diff renderer falls
/// back to plain monospace (Highlightr's auto-detect mis-classifies prose).
func syntaxLanguage(for filePath: String?) -> String? {
    guard let filePath, !filePath.isEmpty else { return nil }
    let ext = (filePath as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "ts", "tsx": return "typescript"
    case "js", "jsx", "mjs", "cjs": return "javascript"
    case "py": return "python"
    case "rb": return "ruby"
    case "go": return "go"
    case "rs": return "rust"
    case "java": return "java"
    case "kt", "kts": return "kotlin"
    case "c", "h": return "c"
    case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return "cpp"
    case "m", "mm": return "objectivec"
    case "sh", "bash", "zsh": return "bash"
    case "json": return "json"
    case "yml", "yaml": return "yaml"
    case "toml": return "toml"
    case "xml", "html", "htm": return "xml"
    case "css", "scss", "sass": return "css"
    case "md", "markdown": return "markdown"
    case "sql": return "sql"
    default: return nil
    }
}

/// Internal access (was private) so other render paths — currently the
/// per-line diff view in `ToolResultViews.swift` — can reuse the same
/// Highlightr instance + Catppuccin remap rather than spinning up their own.
final class SyntaxHighlighterCache: @unchecked Sendable {
    static let shared = SyntaxHighlighterCache()
    private let highlightr: Highlightr?
    private var cache: [String: NSAttributedString] = [:]
    private let lock = NSLock()
    private let maxSize = 50

    private init() {
        let h = Highlightr()
        // atom-one-dark gives us a clean, well-defined token palette that we
        // remap to Catppuccin Mocha below. Highlightr's Theme initializer is
        // `internal`, so we can't supply a Catppuccin CSS string directly —
        // post-processing per-token foregrounds is the cleanest path.
        h?.setTheme(to: "atom-one-dark")
        h?.theme.setCodeFont(.monospacedSystemFont(ofSize: 11, weight: .regular))
        highlightr = h
    }

    func highlight(code: String, language: String?) -> NSAttributedString? {
        // No language hint → bail out so CodeBlockView renders plain
        // monospace. Highlightr's auto-detect mis-classifies prose
        // (e.g. a triage paragraph wrapped in bare ``` fences) as a
        // programming language and colors random words as keywords.
        guard let language = language, !language.isEmpty else { return nil }

        // Cache key includes the active flavor so Mocha and Latte
        // entries never collide. Belt-and-suspenders alongside
        // `invalidate()` on toggle: if the toggle ever misses (e.g.
        // someone writes `AppSettings.appearance` directly without
        // going through `AppearanceSelector.setMode`), the keyed
        // entries still ensure each flavor reads its own colors.
        let key = "\(AppSettings.appearance.resolved.rawValue):\(language):\(code)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let h = highlightr else { return nil }
        guard let raw = h.highlight(code, as: language) else { return nil }

        let result = NSMutableAttributedString(attributedString: raw)
        result.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: result.length))
        Self.remapToCatppuccin(result)
        // Bash grammar in highlight.js is conservative: it only colors
        // strings, variables, comments, and a handful of keywords. Real
        // bash commands are mostly commands, flags, paths, and operators
        // — none of which the grammar tokenizes. Sweep the post-remap
        // result with a regex pass that paints those classes so a
        // typical command lights up like a terminal IDE instead of
        // staying mostly Catppuccin text.
        if language == "bash" {
            Self.enrichBashHighlighting(result)
        }
        let frozen = NSAttributedString(attributedString: result)

        lock.lock()
        if cache.count >= maxSize { cache.removeAll() }
        cache[key] = frozen
        lock.unlock()

        return frozen
    }

    /// Drop every cached attributed string. Call when the active palette
    /// changes (Light/Dark toggle), since cached strings have the old
    /// flavor's NSColors baked in.
    func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Each entry maps an atom-one-dark hex foreground to the closest
    /// Catppuccin role from the *active* palette. Recomputed on every
    /// remap call so flavor swaps take effect immediately. The dict
    /// holds 10 entries; the alloc cost is negligible compared to the
    /// surrounding tokenize step.
    private static var catppuccinRecolor: [UInt32: NSColor] {
        let p = CatppuccinPalette.active
        return [
            0xc678dd: NSColor(p.mauve),    // keywords, control flow
            0x98c379: NSColor(p.green),    // strings
            0xd19a66: NSColor(p.peach),    // numbers, literals
            0x61afef: NSColor(p.blue),     // functions, sections
            0xe5c07b: NSColor(p.yellow),   // types, classes, attrs
            0x56b6c2: NSColor(p.sky),      // built-ins, operators
            0xe06c75: NSColor(p.red),      // variables, tags
            0xabb2bf: NSColor(p.text),     // default text
            // Style guide says Comments → Overlay 2. In Mocha overlay2
            // (#9399b2) is *brighter* than overlay1, in Latte overlay2
            // (#7c7f93) is *darker* than overlay1 — both directions
            // improve comment legibility relative to body text on each
            // bg. The previous `overlay` (overlay1) was off-spec and
            // washed out comments in Latte specifically.
            0x5c6370: NSColor(p.overlay2), // comments
            0xbe5046: NSColor(p.red),      // less-common red variant
        ]
    }

    private static func remapToCatppuccin(_ result: NSMutableAttributedString) {
        let recolor = catppuccinRecolor
        let fullRange = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let original = value as? NSColor else { return }
            let hex = rgbHex(from: original)
            if let mapped = recolor[hex] {
                result.addAttribute(.foregroundColor, value: mapped, range: range)
            }
        }
    }

    /// Hex of `Catppuccin.text` for the active flavor. Runs ending up at
    /// this color after the atom-one-dark → Catppuccin remap are the
    /// parts the grammar didn't tokenize — fair game for the bash regex
    /// sweep. Computed each call so it tracks Light/Dark.
    private static var bashDefaultTextHex: UInt32 {
        rgbHex(from: NSColor(CatppuccinPalette.active.text))
    }

    /// Roles assigned to a bash regex match. Resolved to a concrete
    /// NSColor from the active palette inside `enrichBashHighlighting`,
    /// so the regex array stays compiled-once while the colors stay
    /// flavor-aware.
    ///
    /// Color mapping follows the Catppuccin style guide's
    /// "Code Editors / Language Defaults" table (Operators → Sky,
    /// Methods/Functions → Blue, Constants/Numbers → Peach). The
    /// command/path pair is the critical one: Latte's sapphire
    /// (#209fb5) and teal (#179299) sit in nearly the same hue range,
    /// so using sapphire for commands made commands and paths visually
    /// merge in a typical `command /some/path` pipeline. Switching
    /// commands to blue (#1e66f5 in Latte, vivid blue) restores the
    /// per-token contrast that Mocha got for free from its better-
    /// spread blue family.
    private enum BashTokenRole {
        case number, path, flag, shellOp, command
        func nsColor(palette p: CatppuccinPalette) -> NSColor {
            switch self {
            case .number:  return NSColor(p.peach)    // Constants, Numbers → Peach
            case .path:    return NSColor(p.teal)     // No spec; teal differentiates from blue/sky
            // Spec puts Attributes at Yellow, but Latte yellow (#df8e1d)
            // on mantle (#e6e9ef) has a contrast ratio of ~2.2:1 (fails
            // WCAG AA) — flags become near-invisible on light bg. Mauve
            // gets ~5.6:1 in Latte (and ~8:1 in Mocha), reads cleanly
            // in both modes. Bash flags are control modifiers more than
            // XML-style attributes, and mauve is canonically used for
            // modifiers as a secondary role anyway.
            case .flag:    return NSColor(p.mauve)
            case .shellOp: return NSColor(p.sky)      // Operators → Sky
            case .command: return NSColor(p.blue)     // Methods, Functions → Blue
            }
        }
    }

    /// How a bash enrichment regex applies its color.
    ///
    /// `.defaultOnly` paints only chars that the grammar left at default
    /// text color (the safe-by-construction path used by general patterns
    /// like numbers/paths/flags/commands).
    ///
    /// `.overrideOps` is for operator-shaped regexes (`2>&1`, `&&`, `|`,
    /// `;`, `<`, `>`) that need to paint *across* runs the grammar
    /// already tagged. Highlight.js's bash grammar paints `2` and `1`
    /// inside `2>&1` as numbers (peach), splitting the original default
    /// run into peach/default/default/peach — which means a regex
    /// confined to default-only subruns can never match the full
    /// `2>&1`. `.overrideOps` searches the full string, then for each
    /// match repaints only chars whose current color is "overridable"
    /// (default text, number peach, or keyword mauve). Strings (green)
    /// and comments (overlay2) are preserved.
    private enum BashApplyMode {
        case defaultOnly
        case overrideOps
    }

    /// Ordered list of (regex, role, mode). Later entries win on
    /// overlap, so commands (last) override any earlier classification
    /// at pipeline-segment starts.
    private static let bashEnrichmentSpecs: [(NSRegularExpression?, BashTokenRole, BashApplyMode)] = {
        let specs: [(String, BashTokenRole, BashApplyMode)] = [
            // Standalone digits → peach. Numbers stay rare on a typical
            // command line, so peach only shows up sparsely.
            (#"\b\d+\b"#, .number, .defaultOnly),
            // Paths: anything containing at least one slash. Teal keeps
            // them distinct from the blue-colored commands below.
            (#"(?:[\w.~-]*/)+[\w.~-]*"#, .path, .defaultOnly),
            // Long and short flags → mauve. Must use `.overrideOps` because
            // highlight.js's bash grammar pre-classifies `-foo` patterns
            // as `.hljs-symbol`, which atom-one-dark colors `#d19a66`,
            // which my recolor maps to peach. With `.defaultOnly` the
            // flag regex would never fire on actual flags (they're not
            // at default-text color by the time enrichment runs), and
            // they'd render in low-contrast Latte peach. `.overrideOps`
            // lets the flag color win over peach + mauve + default.
            (#"(?<=^|\s)-{1,2}[a-zA-Z_][\w-]*"#, .flag, .overrideOps),
            // Compound stderr→stdout redirect. Needs `.overrideOps` so
            // the leading `2` and trailing `1` (which the grammar paints
            // peach) get re-painted along with the redirect glyph.
            (#"2>&1"#, .shellOp, .overrideOps),
            // Logical and grouping operators. Grammar may tag `&&`/`||`
            // as keywords (mauve); override that too.
            (#"&&|\|\|"#, .shellOp, .overrideOps),
            // Pipe / sequence / background.
            (#"[|;&]"#, .shellOp, .overrideOps),
            // Standalone redirect chars. Run after path matching so the
            // adjacent path stays teal and only the `>` flips.
            (#"[<>]"#, .shellOp, .overrideOps),
            // First identifier of a pipeline segment (start of string,
            // or after `;`, `|`, `&` followed by whitespace) → blue.
            // Style guide's Methods/Functions hue. Args after a command
            // stay default text since they don't sit at a segment
            // boundary.
            (#"(?:^|(?<=[;|&]\s))[a-zA-Z_][\w-]*"#, .command, .defaultOnly),
        ]
        return specs.map { (try? NSRegularExpression(pattern: $0.0), $0.1, $0.2) }
    }()

    private static func enrichBashHighlighting(_ result: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: result.length)
        let palette = CatppuccinPalette.active
        let defaultHex = bashDefaultTextHex
        // Hexes the operator regexes are allowed to repaint over. Numbers
        // (peach) cover the digit-run-split case for `2>&1` and similar.
        // Keyword mauve covers grammar-tagged `&&`/`||`. Strings (green)
        // and comments (overlay2) are NOT in this set — operator chars
        // inside a quoted string or a comment stay with their grammar
        // color.
        let opOverridableHexes: Set<UInt32> = [
            defaultHex,
            rgbHex(from: NSColor(palette.peach)),
            rgbHex(from: NSColor(palette.mauve)),
        ]

        // Collect runs that the grammar left as plain text (or never
        // attributed) — those are eligible for the regex sweep. Strings,
        // variables, comments, and keywords already have meaningful
        // colors and stay untouched.
        var defaultRuns: [NSRange] = []
        result.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            let isDefault: Bool = {
                guard let color = value as? NSColor else { return true }
                return rgbHex(from: color) == defaultHex
            }()
            if isDefault {
                defaultRuns.append(range)
            }
        }

        for (regex, role, mode) in bashEnrichmentSpecs {
            guard let regex else { continue }
            let color = role.nsColor(palette: palette)
            switch mode {
            case .defaultOnly:
                // Confined to runs the grammar left at default text color.
                // Strings/comments/keywords are protected.
                for runRange in defaultRuns {
                    regex.enumerateMatches(in: result.string, range: runRange) { match, _, _ in
                        guard let match else { return }
                        result.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            case .overrideOps:
                // Search the entire string. For each match, repaint only
                // characters whose current color is in the override set
                // (default text, number peach, keyword mauve). Strings and
                // comments stay intact because their colors aren't in the
                // override set. This is what fixes the `2>&1` split-run
                // bug where the grammar pre-tags `2` and `1` as numbers
                // and would otherwise leave them peach.
                regex.enumerateMatches(in: result.string, range: fullRange) { match, _, _ in
                    guard let match else { return }
                    result.enumerateAttribute(.foregroundColor, in: match.range, options: []) { value, charRange, _ in
                        let currentHex: UInt32 = {
                            guard let c = value as? NSColor else { return defaultHex }
                            return rgbHex(from: c)
                        }()
                        if opOverridableHexes.contains(currentHex) {
                            result.addAttribute(.foregroundColor, value: color, range: charRange)
                        }
                    }
                }
            }
        }
    }

    private static func rgbHex(from color: NSColor) -> UInt32 {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = UInt32((rgb.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((rgb.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((rgb.blueComponent * 255).rounded()) & 0xFF
        return (r << 16) | (g << 8) | b
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let code: String
    let language: String?

    /// Scale prose fallback / monospace fonts and rewrite the embedded font
    /// runs in Highlightr's NSAttributedString. SwiftUI's `.font()` modifier
    /// only sets a *default* — per-run fonts in an AttributedString win, so
    /// we rebuild the attribute when scale != 1.0.
    @Environment(\.chatFontScale) private var chatFontScale

    init(code: String, language: String? = nil) {
        self.code = code
        self.language = language
    }

    /// Heuristic: bare ``` fences (no language hint) often wrap English
    /// prose — a "draft summary" or "5-sentence triage" block — not code.
    /// Rendering prose in a monospace code box is readable but jarring.
    /// When the content has multiple sentences, length comparable to a
    /// paragraph, and few code-syntax characters, switch to a proportional
    /// font so the block reads as a callout instead of a code listing.
    /// The dark background stays — it preserves the assistant's intent of
    /// visually setting the block apart.
    private var isProseLikeBareFence: Bool {
        guard language == nil || language?.isEmpty == true else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 100 else { return false }

        // Bail out if the content has any line-level markdown structure
        // (headings, bullets, ordered list items, block quotes). Reflow
        // would collapse `## Heading\nNext line` into one flowed paragraph
        // and `- a\n- b\n- c` into "- a - b - c", destroying the shape the
        // assistant intended. The TUI preserves this and so should we.
        // CommonMark says code-block content is literal anyway — the
        // reflow heuristic is a deliberate divergence for prose-shaped
        // callouts, but it should not fire on visibly-structured content.
        if Self.hasMarkdownStructure(code) { return false }

        let chars = Array(trimmed)
        var sentenceCount = 0
        for i in 0..<(chars.count - 2) where chars[i] == "." {
            if chars[i + 1].isWhitespace && chars[i + 2].isUppercase {
                sentenceCount += 1
            }
        }
        guard sentenceCount >= 2 else { return false }

        let codeChars: Set<Character> = ["{", "}", ";", "$", "|", "&", "\\", "<", ">"]
        let codeCharCount = trimmed.reduce(0) { $0 + (codeChars.contains($1) ? 1 : 0) }
        let density = Double(codeCharCount) / Double(trimmed.count)
        return density < 0.015
    }

    /// True when any line starts with a markdown block marker that would
    /// be flattened by paragraph reflow.
    private static func hasMarkdownStructure(_ code: String) -> Bool {
        for raw in code.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // ATX headings: 1–6 `#` followed by a space.
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
                || line.hasPrefix("#### ") || line.hasPrefix("##### ") || line.hasPrefix("###### ") {
                return true
            }
            // Unordered list items.
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                return true
            }
            // Block quote.
            if line.hasPrefix("> ") { return true }
            // Ordered list item: digits then `. ` (e.g. `1. `, `12. `).
            var i = line.startIndex
            while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
            if i > line.startIndex, i < line.endIndex, line[i] == ".",
               line.index(after: i) < line.endIndex, line[line.index(after: i)] == " " {
                return true
            }
        }
        return false
    }

    /// Reflow a prose paragraph by treating single newlines as soft wraps
    /// (replaced with spaces) and keeping blank lines as paragraph breaks.
    /// Without this, the assistant's source-side word wrapping (~70 chars
    /// per line) becomes hard line breaks that leave the right side of
    /// the container empty.
    private var reflowedProse: String {
        let paragraphs = code.components(separatedBy: "\n\n")
        return paragraphs
            .map { para in
                para
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var body: some View {
        if isProseLikeBareFence {
            SwiftUI.Text(reflowedProse)
                .font(.system(size: 13 * chatFontScale))
                .foregroundColor(ChatTheme.primary)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(ChatTheme.codeBlockBg)
                .cornerRadius(6)
        } else {
            // HorizontalScrollPassthrough (not SwiftUI's ScrollView) so a
            // pure-vertical wheel/trackpad scroll while the pointer is
            // inside the code block forwards up to the chat list instead
            // of being swallowed. SwiftUI's ScrollView(.horizontal) eats
            // every wheel event that hits it — the long-standing "chat
            // won't scroll when hovering a code block" bug. Same fix the
            // markdown table already uses.
            HorizontalScrollPassthrough {
                if let highlighted = SyntaxHighlighterCache.shared.highlight(code: code, language: language),
                   let swiftUIAttr = try? AttributedString(scaledFontAttributedString(highlighted, scale: chatFontScale), including: \.appKit) {
                    SwiftUI.Text(swiftUIAttr)
                        .font(.system(size: 11 * chatFontScale, design: .monospaced))
                        .padding(10)
                } else {
                    SwiftUI.Text(code)
                        .font(.system(size: 11 * chatFontScale, design: .monospaced))
                        .foregroundColor(ChatTheme.primary)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatTheme.codeBlockBg)
            .cornerRadius(6)
        }
    }
}

/// Walk every `.font` run and replace it with the same descriptor at a
/// scaled point size. Used by `CodeBlockView` because Highlightr bakes
/// 11pt monospaced fonts into the attributed string and SwiftUI's
/// `.font()` modifier only sets the *default* — per-run fonts override.
private func scaledFontAttributedString(_ source: NSAttributedString, scale: CGFloat) -> NSAttributedString {
    guard scale != 1.0 else { return source }
    let mut = NSMutableAttributedString(attributedString: source)
    let fullRange = NSRange(location: 0, length: mut.length)
    mut.enumerateAttribute(.font, in: fullRange) { value, range, _ in
        guard let font = value as? NSFont else { return }
        let newSize = font.pointSize * scale
        let scaled = NSFont(descriptor: font.fontDescriptor, size: newSize)
            ?? NSFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        mut.addAttribute(.font, value: scaled, range: range)
    }
    return mut
}
