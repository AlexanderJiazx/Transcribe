import ApplicationServices
import CoreGraphics
import Foundation

/// Inserts transcription text into whatever text field is focused in the frontmost app,
/// live, using the macOS Accessibility API — no synthetic ⌘V needed for the normal path.
///
/// Usage pattern for dictation-style streaming:
///
/// ```swift
/// let inserter = LiveTextInserter()
/// inserter.begin()                    // start of a recording session
/// inserter.update("Hello")            // partial results, cumulative text (not deltas)
/// inserter.update("Hello world")
/// let mode = inserter.finish("Hello world.")  // final text; also fixes the last partial
/// ```
///
/// How it works: the first ``update`` reads the focused element's caret
/// (`AXSelectedTextRange`) and inserts via `AXSelectedText`. Later updates re-select the
/// range we previously inserted and overwrite it with the newer cumulative text, so text
/// the model revises mid-stream is corrected in place. Before each replace, the tracked
/// range is read back (`AXStringForRange`) and compared to what we last inserted — if the
/// user edited inside our text we stop replacing and degrade to append-only diffs at the
/// caret, so user input is never clobbered.
///
/// If the focused element doesn't expose a settable `AXSelectedText` (secure fields,
/// Terminal, non-text controls), updates no-op and ``finish(_:)`` reports
/// ``DeliveryMode/pasteFallback`` so the caller can drop to a paste.
///
/// Threading: call all methods from the same serial context (the app uses the main
/// queue). AX IPC happens on the calling thread.
public final class LiveTextInserter {

    /// How the text reached the target field.
    public enum DeliveryMode {
        /// Text was written through the Accessibility API.
        case accessibility
        /// Nothing was written via AX; caller should deliver via paste.
        case pasteFallback
    }

    /// Whether at least one update was written via AX this session.
    public private(set) var deliveredViaAX = false

    /// False once we've seen a focused element whose AXSelectedText isn't settable —
    /// surfaced so the caller can warn once instead of discovering the fallback at end.
    public private(set) var insertionSupported = true

    private var element: AXUIElement?
    /// Character offset (AX units ≈ UTF-16) where our inserted text starts.
    private var anchorStart: Int?
    /// Length of `lastInserted` in the same units.
    private var insertedLen = 0
    /// The cumulative text currently shown in the field by us.
    private var lastInserted = ""
    /// True once content verification failed — remaining updates append diffs at the caret.
    private var appendOnly = false
    /// Element whose writes evaporated (fake-success AX writes on e.g. web text
    /// fields). Once marked, we stop attempting writes to it for this session.
    private var unwriteable: AXUIElement?

    /// The text currently occupying our tracked range in the field (what ``update`` last
    /// wrote). Callers use it to compute keep-prefixes that match reality — the shown
    /// transcript can be one tick ahead of what was actually delivered.
    public var currentText: String { lastInserted }

    public init() {}

    /// Reset per-session state. Call when a new dictation starts.
    public func begin() {
        deliveredViaAX = false
        insertionSupported = true
        element = nil
        unwriteable = nil
        resetTracking()
    }

    private func resetTracking() {
        anchorStart = nil
        insertedLen = 0
        lastInserted = ""
        appendOnly = false
    }

    /// Write (or revise) the cumulative transcription `text` in the focused field.
    ///
    /// `keepPrefix` is the number of UTF-16 units from the start of `text` (and of what
    /// we previously wrote) that are stable/committed: that prefix is never re-selected
    /// or rewritten — only the volatile tail after it is replaced in place. Passing the
    /// committed-text length each update makes long dictations update cheaply and keeps
    /// already-written text visually stable instead of flickering on every revision.
    public func update(_ text: String, keepPrefix: Int = 0) {
        guard text != lastInserted else { return }
        guard let el = focusedElement() else { return }
        if let bad = unwriteable, CFEqual(bad, el) { return }

        if element == nil || !CFEqual(element!, el) {
            // First element seen this session, or focus moved mid-session: anchor at the
            // new element's caret (any stale text we left in the old field stays put).
            element = el
            resetTracking()
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            print("[insert] focused el role=\(roleRef as? String ?? "?")")
        }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            insertionSupported = false
            return
        }
        insertionSupported = true

        if appendOnly {
            appendDelta(el, text: text)
            return
        }

        if let start = anchorStart {
            // Only replace the tail after the committed prefix; the prefix must never move.
            let keep = min(keepPrefix, insertedLen, text.utf16.count)
            let tracked = CFRange(location: start + keep, length: insertedLen - keep)
            let oldSuffix = String(decoding: lastInserted.utf16.dropFirst(keep), as: UTF16.self)
            let newSuffix = String(decoding: text.utf16.dropFirst(keep), as: UTF16.self)
            if stringForRange(el, tracked) == oldSuffix,
               setSelectedRange(el, tracked),
               setSelectedText(el, newSuffix) {
                insertedLen = text.utf16.count
                lastInserted = text
                deliveredViaAX = true
            } else {
                print("[insert] tracked-range verify/write failed at \(tracked.location)+\(tracked.length)")
                // User edited inside (or the range can't be read): never overwrite
                // unknown content — degrade to caret-appends from here on.
                appendOnly = true
                appendDelta(el, text: text)
            }
            return
        }

        // First write into this element: insert at caret, remember where it began.
        let sel = selectedRange(el)
        let caret = sel?.location ?? characterCount(el) ?? 0
        print("[insert] first write: sel=\(sel.map { "\($0.location)+\($0.length)" } ?? "nil") caret=\(caret)")
        // Dictation convention: separate our text from adjacent existing text with a
        // space when the caret/selection sits right against a non-space character.
        var prefix = ""
        var suffix = ""
        let selStart = sel?.location ?? caret
        let selEnd = selStart + (sel?.length ?? 0)
        if selStart > 0,
           let prev = stringForRange(el, CFRange(location: selStart - 1, length: 1)),
           let c = prev.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(c) {
            prefix = " "
        }
        if let next = stringForRange(el, CFRange(location: selEnd, length: 1)),
           let c = next.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(c) {
            suffix = " "
        }
        if setSelectedText(el, prefix + text + suffix) {
            // Some elements (e.g. web text fields) accept AXSelectedText writes that
            // never reach their content — verify the write landed before trusting
            // this element for the session, else degrade to the paste fallback.
            let wrote = prefix + text + suffix
            let wRange = CFRange(location: caret, length: wrote.utf16.count)
            let landed = stringForRange(el, wRange) == wrote
                || selectedRange(el)?.location == caret + wrote.utf16.count
            if landed {
                anchorStart = caret + prefix.utf16.count
                insertedLen = text.utf16.count
                lastInserted = text
                deliveredViaAX = true
            } else {
                print("[insert] write evaporated — element not AX-writeable")
                insertionSupported = false
                unwriteable = el
            }
        }
    }

    /// Final update for the session. Returns how text was delivered so the caller can
    /// decide whether a paste fallback is needed. `keepPrefix` works like in ``update``.
    @discardableResult
    public func finish(_ text: String, keepPrefix: Int = 0) -> DeliveryMode {
        update(text, keepPrefix: keepPrefix)
        return deliveredViaAX ? .accessibility : .pasteFallback
    }

    /// Send ⌘V to the frontmost app (the pre-AX delivery mechanism; used only when the
    /// focused element refuses AX writes).
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

    // MARK: - append-only diff mode

    /// Insert only the part of `text` beyond the longest common prefix with what we last
    /// wrote. Revisions inside already-written text are skipped — without a tracked range
    /// we can't remove them without risking user text.
    private func appendDelta(_ el: AXUIElement, text: String) {
        let lcp = commonPrefixLength(lastInserted, text)
        if lcp == lastInserted.utf16.count {
            // decoding (not init) so a split surrogate pair can't fail the whole write
            let suffix = String(decoding: text.utf16.dropFirst(lcp), as: UTF16.self)
            let caretBefore = selectedRange(el)?.location
            if !suffix.isEmpty, setSelectedText(el, suffix) {
                // Same evaporation check as the first write — claim delivery only if
                // the caret actually advanced past the appended text.
                if let c = caretBefore, selectedRange(el)?.location == c + suffix.utf16.count {
                    deliveredViaAX = true
                } else {
                    print("[insert] append evaporated — element not AX-writeable")
                    insertionSupported = false
                }
            }
        }
        lastInserted = text
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var i = a.utf16.startIndex, j = b.utf16.startIndex, n = 0
        while i != a.utf16.endIndex, j != b.utf16.endIndex, a.utf16[i] == b.utf16[j] {
            i = a.utf16.index(after: i); j = b.utf16.index(after: j); n += 1
        }
        return n
    }

    // MARK: - AX primitives

    private func focusedElement() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &ref) == .success {
            return (ref as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &ref) == .success {
            let app = ref as! AXUIElement
            var el: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &el) == .success {
                return (el as! AXUIElement)
            }
        }
        return nil
    }

    private func selectedRange(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let axv = v else { return nil }
        var r = CFRange()
        guard AXValueGetValue((axv as! AXValue), .cfRange, &r) else { return nil }
        return r
    }

    private func setSelectedRange(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var range = r
        guard let v = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    private func stringForRange(_ el: AXUIElement, _ r: CFRange) -> String? {
        var range = r
        guard let v = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            el, kAXStringForRangeParameterizedAttribute as CFString, v, &out) == .success else { return nil }
        return out as? String
    }

    private func characterCount(_ el: AXUIElement) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &v) == .success,
              let n = v as? Int else { return nil }
        return n
    }

    private func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
