import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Inserts transcription text into whatever text field is focused, live, as
/// **append-only chunks** — it never rewrites, re-selects, or re-reads text it
/// already wrote, so it cannot overwrite or remove earlier transcript output.
///
/// Why append-only: the rewrite-in-place design (anchor a tracked range via AX,
/// replace the volatile tail on every tick) was fragile in the field — AX writes
/// silently evaporate in non-native text fields (web content, Electron, browsers),
/// anchor bookkeeping could clobber already-inserted transcript text, and every
/// tick paid several AX round-trips. Real dictation apps (superwhisper et al.)
/// instead append only newly-committed words; the still-volatile tail is never
/// put into the field at all — it decodes once at stop and lands as one chunk.
///
/// Delivery is plain-text ⌘V paste — it works in every editable field (native,
/// web, Electron, Terminal) and needs no accessibility trust of the TARGET app.
/// The user's clipboard contents are snapshotted and restored around each paste.
///
/// Callers pass CUMULATIVE text that is prefix-stable: each call's text must
/// extend what the previous call provided (committed words only ever grow; the
/// final transcript is built to carry the committed prefix verbatim). The
/// inserter appends `text.minus(what it already wrote)` — a single paste.
///
/// Threading: call all methods from one serial context (the app funnels them
/// through a dedicated serial DispatchQueue — never main, so a hung pasteboard
/// or a slow target app can never stall the hotkey's event tap).
public final class ChunkInserter {

    /// How the text reached the target field.
    public enum DeliveryMode {
        /// Everything pending was appended via paste.
        case paste
        /// There was nothing to write (empty transcript / nothing new).
        case nothing
    }

    /// Cumulative EMITTED text so far this session — verbatim, never including
    /// synthetic separators we add for the field. This is the marker callers'
    /// prefix-stable text is diffed against; it must equal the last `text`
    /// passed to appendDelta or every later call full-appends (the synthetic
    /// leading space used to break the prefix on its second emit).
    public private(set) var insertedText = ""

    /// Last character actually pasted into the field (may be a separator we
    /// synthesized) — spacing decisions compare against what the field really
    /// ends with, not the transcript marker.
    private var lastPastedChar: Character?

    /// One optional, bounded probe of the focused field's caret on the FIRST
    /// append of a session — decides whether a separating space is needed
    /// against adjacent existing text. Failure (no AX trust, non-AX field)
    /// just falls back to a conservative default; insertion itself never
    /// depends on AX at all.
    private var probedCaret = false
    private var probeHadTextBeforeCaret = false
    private var probeHadTextAfterCaret = false

    public init() {}

    /// Reset per-session state. Call when a new dictation starts.
    public func begin() {
        insertedText = ""
        lastPastedChar = nil
        probedCaret = false
        probeHadTextBeforeCaret = false
        probeHadTextAfterCaret = false
    }

    /// Append whatever part of `text` hasn't been written yet. `text` is the
    /// cumulative transcript so far — prefix-stable relative to prior calls.
    public func appendDelta(_ text: String) {
        guard text != insertedText else { return }
        var delta: String
        if text.hasPrefix(insertedText) {
            delta = String(text.dropFirst(insertedText.count))
        } else {
            // Contract violated (shouldn't happen — the caller keeps committed
            // text verbatim). Deliver the freshest text from the first
            // divergence instead of skipping: a bounded duplication beats a
            // silently truncated transcript in the field.
            let lcp = insertedText.commonPrefix(with: text).count
            print("[insert] final text diverged from inserted prefix at \(lcp) chars — appending from divergence")
            delta = String(text.dropFirst(lcp))
        }
        guard !delta.isEmpty else { return }

        var chunk = delta
        if insertedText.isEmpty && !probedCaret {
            // First write of the session — probe the caret once so mid-text
            // dictation gets separating spaces ("foo|bar" → "foo text bar").
            probeCaret()
            if probeHadTextBeforeCaret { chunk = " " + chunk }
            if probeHadTextAfterCaret { chunk += " " }
        } else if let last = lastPastedChar, let first = chunk.first,
                  needsSpace(last, first) {
            chunk = " " + chunk
        }
        print("[insert] append +\(chunk.count) chars (total \(text.count))")
        paste(chunk)
        lastPastedChar = chunk.last
        insertedText = text
    }

    /// Final write for the session: appends the remainder of `text`.
    @discardableResult
    public func finish(_ text: String) -> DeliveryMode {
        appendDelta(text)
        return insertedText.isEmpty ? .nothing : .paste
    }

    /// Post a plain ⌘V keypress to the frontmost app.
    public static func pasteClipboard() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - private

    private func needsSpace(_ a: Character, _ b: Character) -> Bool {
        !a.isWhitespace && !b.isWhitespace
    }

    /// Paste `s` as plain text while preserving the user's clipboard: snapshot
    /// every item/type first, write our string, post ⌘V, give the target's
    /// runloop time to read the pasteboard, then restore.
    private func paste(_ s: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = pb.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let data = item.data(forType: t) { copy.setData(data, forType: t) }
            }
            return copy
        } ?? []
        pb.clearContents()
        pb.setString(s, forType: .string)
        Self.pasteClipboard()
        // The target reads the pasteboard asynchronously on its own runloop —
        // restoring immediately would race it and re-paste the OLD clipboard.
        usleep(90_000)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }

    /// Read the focused element's caret surroundings — ONE bounded AX exchange,
    /// first append only, hard-failing fast (0.5s messaging bound) so a hung
    /// target can't stall the insert queue.
    private func probeCaret() {
        probedCaret = true
        // On ANY failure (no AX trust, non-AX field, hung target) default to a
        // leading space: a stray leading space in an empty field is cosmetic,
        // while cramming into adjacent mid-text ("fooHello") reads as breakage.
        func failed() { probeHadTextBeforeCaret = true }
        guard AXIsProcessTrusted() else { failed(); return }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { failed(); return }
        let el = boundTimeout(focusedRef as! AXUIElement)
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &selRef) == .success,
              let selRef else { failed(); return }
        var range = CFRange()
        guard AXValueGetValue(selRef as! AXValue, .cfRange, &range) else { failed(); return }
        if range.location > 0,
           let prev = stringForRange(el, CFRange(location: range.location - 1, length: 1)),
           let c = prev.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(c) {
            probeHadTextBeforeCaret = true
        }
        if let next = stringForRange(el, CFRange(location: range.location + range.length, length: 1)),
           let c = next.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(c) {
            probeHadTextAfterCaret = true
        }
    }

    private func boundTimeout(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private func stringForRange(_ element: AXUIElement, _ range: CFRange) -> String? {
        var ref: CFTypeRef?
        guard let v = AXValueCreate(.cfRange, [range]),
              AXUIElementCopyParameterizedAttributeValue(
                  element, kAXStringForRangeParameterizedAttribute as CFString, v, &ref) == .success,
              let s = ref as? String else { return nil }
        return s
    }
}
