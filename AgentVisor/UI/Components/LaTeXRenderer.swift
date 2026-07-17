//
//  LaTeXRenderer.swift
//  AgentVisor
//
//  Renders a LaTeX source string into an NSImage suitable for embedding
//  as an inline attachment in a markdown AttributedString. Backed by
//  SwiftMath (CoreText-based, MathJax-compatible subset). Cached so
//  re-rendered messages — common because SwiftUI rebuilds AttributedStrings
//  on font-scale changes and DocumentCache misses — don't pay the layout
//  cost twice.
//

import AppKit
import AgentVisorCore
import SwiftMath
import os.log

/// Logger; exposed so callers can flip the log level if a problematic
/// formula needs investigating.
private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "LaTeXRenderer")

enum LaTeXRenderer {

    enum Mode {
        /// Inline math (single `$..$`). Smaller font, baseline-aligned
        /// for embedding mid-sentence.
        case inline
        /// Display math (`$$..$$`). Larger font, intended to live in
        /// its own block (centered).
        case display
    }

    /// Render `latex` to an NSImage at the given font size + color.
    /// Returns nil if SwiftMath rejects the source — in that case the
    /// caller should fall back to rendering the raw `$..$` text.
    static func image(
        latex: String,
        fontSize: CGFloat,
        color: NSColor,
        mode: Mode = .inline
    ) -> NSImage? {
        let cacheKey = CacheKey(latex: latex, fontSize: fontSize, color: color, mode: mode)
        if let cached = cache.value(forKey: cacheKey) {
            return cached
        }

        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = color
        label.labelMode = (mode == .display) ? .display : .text
        label.textAlignment = .left
        label.font = MTFontManager().defaultFont?.copy(withSize: fontSize)

        // SwiftMath surfaces parse errors via `.error` after assigning
        // `.latex`. Treat any error as a render failure so the caller
        // can show the raw source instead of a blank image.
        if let parseError = label.error {
            logger.notice("SwiftMath rejected formula \(latex, privacy: .public): \(parseError.localizedDescription, privacy: .public)")
            return nil
        }

        // SwiftMath's `intrinsicContentSize` only returns a real value
        // on iOS; on macOS the equivalent API is `fittingSize`, which
        // routes through the same `_sizeThatFits` calculator. Using
        // `intrinsicContentSize` here returned `(-1, -1)` (the NSView
        // default), which we'd then reject as zero-sized.
        let intrinsic = label.fittingSize
        guard intrinsic.width > 0, intrinsic.height > 0 else {
            logger.notice("SwiftMath returned zero size for \(latex, privacy: .public): w=\(intrinsic.width) h=\(intrinsic.height)")
            return nil
        }

        // Add a small horizontal pad so adjacent letters in the
        // surrounding sentence don't sit flush against the formula's
        // bounding glyphs.
        let pad: CGFloat = 2
        let pixelSize = NSSize(width: ceil(intrinsic.width) + pad * 2,
                               height: ceil(intrinsic.height))
        label.frame = NSRect(origin: .zero, size: pixelSize)
        // NSView needs an explicit layer for `.layer?.render(in:)` —
        // without `wantsLayer = true` the layer property stays nil and
        // we'd render a blank image.
        label.wantsLayer = true
        label.layoutSubtreeIfNeeded()

        let image = NSImage(size: pixelSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext,
                  let layer = label.layer else { return false }
            ctx.translateBy(x: pad, y: 0)
            layer.render(in: ctx)
            return true
        }

        cache.set(value: image, forKey: cacheKey)
        return image
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let latex: String
        let fontSize: CGFloat
        // NSColor isn't Hashable in a stable way (calibration changes the
        // hash). Project to its sRGB components so identical visual
        // colors hit the same cache entry across refreshes.
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let a: CGFloat
        let mode: Mode

        init(latex: String, fontSize: CGFloat, color: NSColor, mode: Mode) {
            self.latex = latex
            self.fontSize = fontSize
            self.mode = mode
            let resolved = color.usingColorSpace(.sRGB) ?? color
            self.r = resolved.redComponent
            self.g = resolved.greenComponent
            self.b = resolved.blueComponent
            self.a = resolved.alphaComponent
        }
    }

    private static let cache = LaTeXImageCache()
}

extension LaTeXRenderer.Mode: Hashable {}

/// Bounded NSImage cache (LRU-ish; capped at 256 entries — enough for
/// long math-heavy threads without growing without bound).
private final class LaTeXImageCache {
    private var entries: [AnyHashable: NSImage] = [:]
    private var order: [AnyHashable] = []
    private let lock = NSLock()
    private let maxEntries = 256

    func value(forKey key: AnyHashable) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func set(value: NSImage, forKey key: AnyHashable) {
        lock.lock(); defer { lock.unlock() }
        if entries[key] == nil {
            order.append(key)
        }
        entries[key] = value
        // Evict oldest until under the cap.
        while entries.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
