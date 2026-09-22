import AppKit
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
    /// Insertion state saved per adopted element: when focus leaves a field
    /// mid-session and comes back, we resume tracked editing of the stale span
    /// we left there instead of appending a second copy of the transcript.
    private struct ElementAnchor {
        var start: Int
        var len: Int
        var text: String
        var appendOnly: Bool
    }
    private var anchors: [(element: AXUIElement, anchor: ElementAnchor)] = []
    /// The next tracked write must rewrite the whole anchored span: a resumed
    /// anchor's `lastInserted` is a stale partial that may have diverged from
    /// the current transcript since the keep-prefix region.
    private var resumedAnchor = false

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
        anchors.removeAll()
        resumedAnchor = false
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

        // Resolve the write target. Prefer the focused element; when it can't take
        // text (no focus, desktop, or a non-text element like Finder's file list),
        // keep delivering to the field already holding our partial text — a doc
        // that received partials should still get the rest of the transcript.
        var el: AXUIElement
        if let f = focusedElement(), !(unwriteable.map { CFEqual($0, f) } ?? false) {
            if let prev = element, anchorStart != nil, CFEqual(prev, f) {
                // Same element we already adopted — known text-settable; don't
                // re-ask (AXUIElementIsAttributeSettable can transiently fail
                // while the target app's AX server is busy, which would stall
                // every subsequent tick).
                el = f
            } else {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(f, kAXSelectedTextAttribute as CFString, &settable) == .success,
                   settable.boolValue {
                    el = f
                } else if let prev = element, anchorStart != nil {
                    el = prev
                } else if let alt = menuBarOwnerElement(), !CFEqual(alt, f) {
                    // Transient focus (notification banner, floating panel) is
                    // not a text target — the menu-bar owner is the app the
                    // user actually perceives as frontmost; try its field.
                    var settable2 = DarwinBoolean(false)
                    guard AXUIElementIsAttributeSettable(alt, kAXSelectedTextAttribute as CFString, &settable2) == .success,
                          settable2.boolValue else {
                        insertionSupported = false
                        print("[insert] focused element not text-settable and no anchor — update dropped")
                        return
                    }
                    el = alt
                } else {
                    insertionSupported = false
                    print("[insert] focused element not text-settable and no anchor — update dropped")
                    return
                }
            }
        } else if let prev = element, anchorStart != nil {
            el = prev
        } else {
            insertionSupported = false
            print("[insert] no focused element and no anchor — update dropped")
            return
        }
        if let bad = unwriteable, CFEqual(bad, el) {
            insertionSupported = false
            print("[insert] target element is unwriteable — update dropped")
            return
        }
        insertionSupported = true

        if element == nil || !CFEqual(element!, el) {
            // Focus moved (or first element): stash the old field's anchor so a
            // later return rewrites its stale span rather than appending a copy.
            if let prev = element, let start = anchorStart {
                let a = ElementAnchor(start: start, len: insertedLen, text: lastInserted, appendOnly: appendOnly)
                if let i = anchors.firstIndex(where: { CFEqual($0.element, prev) }) {
                    anchors[i].anchor = a
                } else {
                    anchors.append((prev, a))
                }
            }
            element = el
            resetTracking()
            var resumed = false
            if let a = anchors.first(where: { CFEqual($0.element, el) })?.anchor {
                anchorStart = a.start
                insertedLen = a.len
                lastInserted = a.text
                appendOnly = a.appendOnly
                resumedAnchor = true
                resumed = true
            }
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            print("[insert] focused el role=\(roleRef as? String ?? "?") app=\(owner)\(resumed ? " (resumed)" : "")")
        }

        if appendOnly {
            appendDelta(el, text: text)
            return
        }

        if let start = anchorStart {
            // Only replace the tail after the committed prefix; the prefix must never move.
            // On a resumed anchor the keep region can't be trusted — the stale
            // partial we left may diverge from `text` before keepPrefix — so the
            // first write after a focus return rewrites the whole span.
            let keep = resumedAnchor ? 0 : min(keepPrefix, insertedLen, text.utf16.count)
            resumedAnchor = false
            let tracked = CFRange(location: start + keep, length: insertedLen - keep)
            let oldSuffix = String(decoding: lastInserted.utf16.dropFirst(keep), as: UTF16.self)
            let newSuffix = String(decoding: text.utf16.dropFirst(keep), as: UTF16.self)
            let docLenBefore = characterCount(el)
            if stringForRange(el, tracked) == oldSuffix,
               setSelectedRange(el, tracked),
               selectionIs(el, tracked),
               setSelectedText(el, newSuffix) {
                // Post-verify: the doc must now contain `text` at our anchor and have
                // grown by exactly (newSuffix - oldSuffix). Some apps apply the
                // selection set asynchronously, so the write can land as an append
                // at a stale caret — that leaves a stray copy and keeps our old
                // text; repair it instead of trusting the write.
                if let before = docLenBefore,
                   let docLenAfter = characterCount(el),
                   docLenAfter == before - tracked.length + newSuffix.utf16.count,
                   stringForRange(el, CFRange(location: start, length: text.utf16.count)) == text {
                    insertedLen = text.utf16.count
                    lastInserted = text
                    deliveredViaAX = true
                } else if let before = docLenBefore,
                          repairMisplacedWrite(el, start: start, docLenBefore: before, oldLen: insertedLen, text: text, strayText: newSuffix) {
                    insertedLen = text.utf16.count
                    lastInserted = text
                    deliveredViaAX = true
                } else {
                    print("[insert] tracked write misplaced and not repairable at \(start) — degrade")
                    appendOnly = true
                    appendDelta(el, text: text)
                }
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
            if writeLanded(el, at: caret, wrote: wrote) {
                anchorStart = caret + prefix.utf16.count
                insertedLen = text.utf16.count
                lastInserted = text
                deliveredViaAX = true
            }
        }
    }

    /// Final update for the session. Returns how text was delivered so the caller can
    /// decide whether a paste fallback is needed. `keepPrefix` works like in ``update``.
    @discardableResult
    public func finish(_ text: String, keepPrefix: Int = 0) -> DeliveryMode {
        update(text, keepPrefix: keepPrefix)
        // If the final text never landed (an update bailed mid-session, or an AX
        // write silently failed after the last successful one), the document is
        // guaranteed incomplete — report pasteFallback so the caller drops the
        // full transcript in via the clipboard instead of leaving a truncated tail.
        if deliveredViaAX, lastInserted != text {
            print("[insert] final text not delivered via AX (have \(lastInserted.utf16.count) of \(text.utf16.count) chars) — pasteFallback")
            return .pasteFallback
        }
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
    ///
    /// Before appending we check where our previous text actually is in the field:
    /// - If it's still the contiguous tail, we can replace it in place — revisions
    ///   stay clean even in degraded mode.
    /// - If it's gone entirely (user undid/deleted our text), appending only the
    ///   delta would silently lose the earlier transcript — re-append the whole
    ///   current text at the caret so nothing is dropped.
    private func appendDelta(_ el: AXUIElement, text: String) {
        let ourLen = lastInserted.utf16.count
        let docLen = characterCount(el) ?? 0
        let lcp = commonPrefixLength(lastInserted, text)

        // How much of our last write still ends the field? 0 = our text isn't at the
        // tail (deleted/undone, or the user typed after it).
        var kept = 0
        let tailLen = min(ourLen, docLen)
        if tailLen > 0,
           let tail = stringForRange(el, CFRange(location: docLen - tailLen, length: tailLen)) {
            let tU = Array(tail.utf16)
            let lU = Array(lastInserted.utf16)
            var p = min(tU.count, lU.count)
            while p > 0 && !(Array(tU[(tU.count - p)...]) == Array(lU[0..<p])) {
                p -= 1
            }
            kept = p
        }

        // Tail fully intact → replace our whole contribution in place so tail
        // revisions stay clean even in degraded mode.
        if kept == ourLen, ourLen > 0 {
            let tailRange = CFRange(location: docLen - ourLen, length: ourLen)
            if setSelectedRange(el, tailRange), setSelectedText(el, text),
               writeLanded(el, at: docLen - ourLen, wrote: text) {
                lastInserted = text
                deliveredViaAX = true
                return
            }
        }

        // Partial tail survives (e.g. undo of just our last write): complete it so
        // the field still ends with the full transcript.
        if kept > 0 {
            if kept <= lcp {
                // Surviving tail is also a prefix of the new text — append the rest.
                let suffix = String(decoding: text.utf16.dropFirst(kept), as: UTF16.self)
                if setSelectedRange(el, CFRange(location: docLen, length: 0)),
                   setSelectedText(el, suffix),
                   writeLanded(el, at: docLen, wrote: suffix) {
                    lastInserted = text
                    deliveredViaAX = true
                    return
                }
            } else {
                // Tail includes text the model revised away — replace just the
                // divergent chunk at the field end.
                let divLen = kept - lcp
                let repl = String(decoding: text.utf16.dropFirst(lcp), as: UTF16.self)
                if setSelectedRange(el, CFRange(location: docLen - divLen, length: divLen)),
                   setSelectedText(el, repl),
                   writeLanded(el, at: docLen - divLen, wrote: repl) {
                    lastInserted = text
                    deliveredViaAX = true
                    return
                }
            }
        }

        // Undo/⌘Z mid-dictation can leave an EARLIER revision of our text at the
        // anchor — the surviving span shares a long prefix with `text` (diverging
        // where the model has since revised). Replace the span wholesale so the
        // field ends exactly with the transcript instead of carrying the stale
        // prefix plus a re-appended copy.
        if let start = anchorStart, start <= docLen, ourLen > 0,
           let seg = stringForRange(el, CFRange(location: start, length: docLen - start)),
           !seg.isEmpty,
           !seg.hasPrefix(lastInserted) {
            // (seg starting with lastInserted = our full text plus a user tail —
            // that case belongs to the delta-append path below, not a rewrite.)
            let prefixMatch = commonPrefixLength(seg, text)
            if prefixMatch >= 8 || (!seg.isEmpty && prefixMatch == seg.utf16.count) {
                let span = CFRange(location: start, length: docLen - start)
                if setSelectedRange(el, span),
                   selectionIs(el, span),
                   setSelectedText(el, text),
                   stringForRange(el, CFRange(location: start, length: text.utf16.count)) == text {
                    print("[insert] replaced stale earlier-revision span at \(start)")
                    lastInserted = text
                    deliveredViaAX = true
                    return
                }
            }
        }

        // Our text isn't at the tail at all.
        if ourLen == 0 || fieldStillContainsOurText(el, docLen: docLen) {
            // It's intact mid-field (user typed after it, or caret sits elsewhere) —
            // append only the delta at the caret like the classic path.
            if lcp == lastInserted.utf16.count {
                // decoding (not init) so a split surrogate pair can't fail the whole write
                let suffix = String(decoding: text.utf16.dropFirst(lcp), as: UTF16.self)
                if suffix.isEmpty {
                    lastInserted = text
                    return
                }
                let caret = selectedRange(el)?.location ?? docLen
                if setSelectedText(el, suffix),
                   writeLanded(el, at: caret, wrote: suffix) {
                    lastInserted = text
                    deliveredViaAX = true
                }
                // On failure lastInserted stays stale — finish() detects the gap
                // and falls back to paste so the transcript isn't truncated.
            } else {
                // The tail revision changed already-delivered text mid-field —
                // we can't safely rewrite there, but the field still holds a
                // complete earlier transcript state; keep lastInserted honest.
            }
            return
        }

        // Deleted/undone entirely — re-append the whole current transcript at the
        // field end so nothing is silently dropped.
        print("[insert] our text no longer in field — re-appending full transcript")
        var prefix = ""
        if docLen > 0,
           let prev = stringForRange(el, CFRange(location: docLen - 1, length: 1)),
           let c = prev.unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(c) {
            prefix = " "
        }
        let wrote = prefix + text
        if setSelectedRange(el, CFRange(location: docLen, length: 0)),
           setSelectedText(el, wrote),
           writeLanded(el, at: docLen, wrote: wrote) {
            lastInserted = text
            deliveredViaAX = true
        }
    }

    /// True if `lastInserted` still appears within the last ~`lastInserted+512` chars
    /// of the element — distinguishes "user typed after our text" from "our text was
    /// deleted/undone" when it isn't the field tail.
    private func fieldStillContainsOurText(_ el: AXUIElement, docLen: Int) -> Bool {
        let ourLen = lastInserted.utf16.count
        guard ourLen > 0, docLen > 0 else { return false }
        let w = CFRange(location: max(0, docLen - ourLen - 512), length: min(docLen, ourLen + 512))
        return stringForRange(el, w)?.contains(lastInserted) ?? false
    }

    /// True if the element's current selection is exactly `r` — used after
    /// `AXSelectedTextRange` writes, since some apps apply them asynchronously and
    /// a following `AXSelectedText` write would land at the stale caret.
    private func selectionIs(_ el: AXUIElement, _ r: CFRange) -> Bool {
        guard let sel = selectedRange(el) else { return false }
        return sel.location == r.location && sel.length == r.length
    }

    /// Repair after a tracked write landed somewhere other than its range (e.g.
    /// appended at the doc tail at a stale caret): delete the stray tail copy,
    /// rewrite our whole tracked span with `text`, then verify.
    private func repairMisplacedWrite(_ el: AXUIElement, start: Int, docLenBefore: Int, oldLen: Int, text: String, strayText: String) -> Bool {
        guard let docLen = characterCount(el) else { return false }
        // Stray append at doc tail: [docLenBefore, docLen) is text the misplaced
        // write added — remove it before rewriting our span. Only delete when it
        // exactly matches what we wrote; anything else may be user content.
        if docLen > docLenBefore {
            let stray = CFRange(location: docLenBefore, length: docLen - docLenBefore)
            guard stringForRange(el, stray) == strayText,
                  setSelectedRange(el, stray),
                  selectionIs(el, stray),
                  setSelectedText(el, "") else { return false }
        }
        // Our span [start, start+oldLen) still holds the previous text — it was
        // verified to be ours before the write — replace it wholesale.
        let span = CFRange(location: start, length: oldLen)
        guard let docLen2 = characterCount(el), docLen2 >= start + oldLen,
              setSelectedRange(el, span),
              selectionIs(el, span),
              setSelectedText(el, text) else { return false }
        return stringForRange(el, CFRange(location: start, length: text.utf16.count)) == text
    }

    /// Verify a write actually reached the element: the range now contains what we
    /// wrote, or the caret advanced past it. Some fields accept AX writes that
    /// silently evaporate — those get marked unwriteable so delivery degrades to paste.
    private func writeLanded(_ el: AXUIElement, at loc: Int, wrote: String) -> Bool {
        if stringForRange(el, CFRange(location: loc, length: wrote.utf16.count)) == wrote { return true }
        if selectedRange(el)?.location == loc + wrote.utf16.count { return true }
        print("[insert] write evaporated — element not AX-writeable")
        insertionSupported = false
        unwriteable = el
        return false
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
            let el = ref as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if pid != getpid() { return el }
            // The focused element is ours — the overlay panel can hold key status
            // briefly at launch while the user perceives another app as frontmost.
            // Use the menu-bar owner, which tracks the user's real front app.
            return menuBarOwnerElement()
        }
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &ref) == .success {
            let app = ref as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            if pid == getpid() { return nil }
            var el: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &el) == .success {
                return (el as! AXUIElement)
            }
        }
        return nil
    }

    /// Focused element of the app that owns the menu bar — the user's perceived
    /// frontmost app even when a panel or banner of ours/another app holds key.
    private func menuBarOwnerElement() -> AXUIElement? {
        guard let owner = NSWorkspace.shared.menuBarOwningApplication,
              owner.processIdentifier != getpid() else { return nil }
        let app = AXUIElementCreateApplication(owner.processIdentifier)
        var el: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &el) == .success else { return nil }
        return (el as! AXUIElement)
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
