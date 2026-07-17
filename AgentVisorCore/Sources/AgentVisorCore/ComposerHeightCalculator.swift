//
//  ComposerHeightCalculator.swift
//  AgentVisorCore
//
//  Pure-logic computation of the composer's text height. Lives here
//  (not in the app target) so we can unit-test the height formula
//  end-to-end against a real NSLayoutManager — three rounds of bugs
//  in the in-line implementation taught us we need the empirical
//  truth-table written down as tests, not as ad-hoc reasoning at the
//  call site.
//
//  Why we call NSLayoutManager directly instead of counting lines:
//  three earlier strategies were each wrong for at least one input
//  shape:
//
//   1. `text.count(of: "\n") + 1`  — missed soft-wrapped lines.
//   2. Per-glyph `lineFragmentRect` enumeration — sometimes counted
//      the trailing-`\n` glyph as its own fragment, double-counting.
//   3. `usedRect.height + extraLineFragmentRect.height` — DOUBLE-
//      COUNTED the caret line: empirical probe (see
//      ComposerHeightCalculatorTests) shows that for `"a\n"`,
//      `usedRect.height = 32` already includes the 16pt extra-line
//      fragment, AND `extra.height = 16` adds another 16. Total
//      reported height = 48 for what's visually 32pt of content.
//
//  Correct shape: just use `usedRect.height`. NSLayoutManager already
//  reserves the trailing-newline caret line in `usedRect` — the
//  separate `extraLineFragmentRect` is the SAME geometry exposed
//  for callers (e.g. cursor positioning) that need to know where
//  the caret is, NOT extra height beyond `usedRect`.
//

import AppKit

public enum ComposerHeightCalculator {
    /// Inputs the calculator needs to compute the composer's text
    /// area height for a given string. All values are immediately
    /// derivable from the live NSTextView; passing them as a struct
    /// makes the pure function trivially testable.
    public struct Input: Equatable, Sendable {
        public let text: String
        public let containerWidth: CGFloat
        public let fontSize: CGFloat
        public let lineFragmentPadding: CGFloat

        public init(
            text: String,
            containerWidth: CGFloat,
            fontSize: CGFloat = 13,
            lineFragmentPadding: CGFloat = 0
        ) {
            self.text = text
            self.containerWidth = containerWidth
            self.fontSize = fontSize
            self.lineFragmentPadding = lineFragmentPadding
        }
    }

    /// Geometry the calculator measures back. `lineHeight` is the
    /// per-line height the typesetter uses; the composer caps the
    /// box at `8 * lineHeight`. `textHeight` is what the rendered
    /// text actually consumes — caller frames the box at this value
    /// (or the cap, whichever is smaller).
    public struct Output: Equatable, Sendable {
        public let textHeight: CGFloat
        public let lineHeight: CGFloat

        public init(textHeight: CGFloat, lineHeight: CGFloat) {
            self.textHeight = textHeight
            self.lineHeight = lineHeight
        }
    }

    /// Build a fresh NSLayoutManager + NSTextStorage stack, lay out
    /// the input string, and read the text height directly off the
    /// layout manager. Pure function (no shared state, no callbacks).
    /// Driven by tests.
    public static func measure(_ input: Input) -> Output {
        let font = NSFont.systemFont(ofSize: input.fontSize)
        let storage = NSTextStorage(string: input.text)
        storage.addAttribute(
            .font,
            value: font,
            range: NSRange(location: 0, length: storage.length)
        )
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(
                width: max(0, input.containerWidth),
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = input.lineFragmentPadding
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
        // `usedRect` already includes the trailing-newline caret line
        // (verified empirically). Don't add `extraLineFragmentRect`;
        // that's the same geometry exposed for cursor positioning,
        // NOT additional height.
        let used = layoutManager.usedRect(for: container).height
        // Floor at one line so an empty input still has visible
        // height (NSLayoutManager reports `usedRect.height = 14` for
        // empty content, which is `lineHeight - 2`; the visible
        // composer would slightly under-size).
        let textHeight = max(lineHeight, ceil(used))
        return Output(textHeight: textHeight, lineHeight: lineHeight)
    }
}
