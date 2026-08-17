// SuperDictate — automatic vocabulary learning from post-insertion edits.
// See docs/superpowers/specs/2026-08-11-vocabulary-learning-design.md.

import Foundation
import AppKit
import ApplicationServices

struct LearnCandidate: Equatable {
    let source: String
    let replacement: String
}

/// Pure word-level diff: given the text SuperDictate inserted and the text
/// now sitting in that same region after the user edited it, decides
/// whether the edit looks like a vocabulary correction (a short,
/// contiguous word/phrase swap) as opposed to a general prose edit.
enum LearnCandidateDetector {
    static let maxSpanWords = 3

    static func candidate(insertedText: String, editedText: String) -> LearnCandidate? {
        let insertedWords = words(in: insertedText)
        let editedWords = words(in: editedText)
        guard !insertedWords.isEmpty, !editedWords.isEmpty else { return nil }

        let commonPrefix = commonPrefixCount(insertedWords, editedWords)
        let commonSuffix = commonSuffixCount(
            insertedWords, editedWords,
            skippingPrefix: commonPrefix
        )

        let oldSpan = Array(insertedWords[commonPrefix..<(insertedWords.count - commonSuffix)])
        let newSpan = Array(editedWords[commonPrefix..<(editedWords.count - commonSuffix)])

        guard !oldSpan.isEmpty, !newSpan.isEmpty else { return nil }
        guard oldSpan.count <= maxSpanWords, newSpan.count <= maxSpanWords else { return nil }

        let source = oldSpan.joined(separator: " ")
        let replacement = newSpan.joined(separator: " ")
        guard source != replacement else { return nil }

        // A pure deletion teaches nothing. Two deletion-only shapes reach
        // this point with a non-empty newSpan and must be rejected:
        //  - intra-word trimming: "инглиш" cut back to "глиш" (newSpan is
        //    a fragment of the old span), and
        //  - non-contiguous word removal: "очень длинное слово" reduced to
        //    "длинное" (the surviving word is a subset of the old span).
        // Without this guard, a user who deletes a word and then pauses to
        // think (longer than debounce + confirm) gets the half-finished
        // deletion learned as a "correction" — and a toast for it.
        // Rule: if the edited span adds no text that wasn't already in the
        // original span, there is nothing to remember. Case-insensitive so
        // a casing-only touch-up ("Инглиш" → "инглиш") is not learned
        // either — it teaches the model no new vocabulary.
        guard !normalizedSpan(source).contains(normalizedSpan(replacement)) else { return nil }

        return LearnCandidate(source: source, replacement: replacement)
    }

    /// Canonical form used by the deletion check: lowercase, internal
    /// whitespace collapsed — same normalization family as
    /// `normalizedTranscriptCorrectionSource`, applied to a joined span.
    private static func normalizedSpan(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count, lhs[count] == rhs[count] {
            count += 1
        }
        return count
    }

    private static func commonSuffixCount(_ lhs: [String], _ rhs: [String], skippingPrefix prefix: Int) -> Int {
        var count = 0
        while count < (lhs.count - prefix),
              count < (rhs.count - prefix),
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }
        return count
    }
}

func testLearnCandidateDetector() throws {
    // Single-word transliteration fix: the motivating case.
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши мне на инглиш пожалуйста",
        editedText: "напиши мне на English пожалуйста"
    ) == LearnCandidate(source: "инглиш", replacement: "English") else {
        throw VocabularyLearningTestFailure("single-word transliteration edit not detected")
    }

    // Two-word phrase swap.
    guard LearnCandidateDetector.candidate(
        insertedText: "открой файл сейчас",
        editedText: "открой этот документ сейчас"
    ) == LearnCandidate(source: "файл", replacement: "этот документ") else {
        throw VocabularyLearningTestFailure("phrase-length edit not detected")
    }

    // No edit at all.
    guard LearnCandidateDetector.candidate(
        insertedText: "привет мир",
        editedText: "привет мир"
    ) == nil else {
        throw VocabularyLearningTestFailure("identical text should not produce a candidate")
    }

    // Full undo back to the original text.
    guard LearnCandidateDetector.candidate(
        insertedText: "тестовое сообщение",
        editedText: "тестовое сообщение"
    ) == nil else {
        throw VocabularyLearningTestFailure("undo back to original should not produce a candidate")
    }

    // Too-long edit (more than 3 words changed) is prose editing, not vocabulary.
    guard LearnCandidateDetector.candidate(
        insertedText: "это был очень длинный оригинальный текст",
        editedText: "это был совершенно другой полностью переписанный текст"
    ) == nil else {
        throw VocabularyLearningTestFailure("edits longer than maxSpanWords should not produce a candidate")
    }

    // Pure insertion (nothing removed) is not a vocabulary correction —
    // there is nothing to teach the model to say differently next time.
    guard LearnCandidateDetector.candidate(
        insertedText: "встреча завтра",
        editedText: "встреча ровно завтра"
    ) == nil else {
        throw VocabularyLearningTestFailure("pure insertion (no removed span) should not produce a candidate")
    }

    // Intra-word trimming is a deletion in progress, not a correction:
    // the user cut "инглиш" back to "глиш" and paused before typing the
    // replacement. Nothing new was typed, so nothing may be learned.
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши на инглиш пожалуйста",
        editedText: "напиши на глиш пожалуйста"
    ) == nil else {
        throw VocabularyLearningTestFailure("intra-word trimming (deleted, no replacement typed yet) should not produce a candidate")
    }

    // Non-contiguous word removal: "очень" and "слово" deleted, middle
    // word "длинное" survives. Still a deletion — no new text.
    guard LearnCandidateDetector.candidate(
        insertedText: "очень длинное слово",
        editedText: "длинное"
    ) == nil else {
        throw VocabularyLearningTestFailure("non-contiguous word deletion should not produce a candidate")
    }

    // Deleting the whole span down to a leftover fragment of another word
    // is still deletion-only.
    guard LearnCandidateDetector.candidate(
        insertedText: "поправь инглиш тут",
        editedText: "поправь иш тут"
    ) == nil else {
        throw VocabularyLearningTestFailure("partial fragment deletion should not produce a candidate")
    }

    // A casing-only touch-up is not vocabulary learning either.
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши инглиш",
        editedText: "напиши Инглиш"
    ) == nil else {
        throw VocabularyLearningTestFailure("casing-only edit should not produce a candidate")
    }

    // Sanity: the motivating real correction still works after the
    // deletion guard.
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши на инглиш пожалуйста",
        editedText: "напиши на English пожалуйста"
    ) == LearnCandidate(source: "инглиш", replacement: "English") else {
        throw VocabularyLearningTestFailure("real replacement must still produce a candidate after the deletion guard")
    }

    // Rebasing after a committed correction must make a later correction in
    // the same dictated region independently learnable. This mirrors the
    // watcher's post-commit baseline update: first fix the transliteration,
    // then fix a second word without losing either correction.
    let firstCorrection = "напиши на English пожалуйста"
    guard LearnCandidateDetector.candidate(
        insertedText: "напиши на инглиш пожалуйста",
        editedText: firstCorrection
    ) == LearnCandidate(source: "инглиш", replacement: "English") else {
        throw VocabularyLearningTestFailure("first correction in a multi-correction region was not detected")
    }
    guard LearnCandidateDetector.candidate(
        insertedText: firstCorrection,
        editedText: "напиши на English please"
    ) == LearnCandidate(source: "пожалуйста", replacement: "please") else {
        throw VocabularyLearningTestFailure("second correction after rebasing was not detected")
    }
}

struct VocabularyLearningTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Watches the field SuperDictate just inserted text into for a short
/// window, and if the user immediately hand-corrects a short span of it,
/// reports a learn candidate. See docs/superpowers/specs/2026-08-11-vocabulary-learning-design.md
/// for the anchoring strategy this implements.
@MainActor
final class PostInsertionEditWatcher {
    static let watchWindowSeconds: TimeInterval = 45
    static let debounceSeconds: TimeInterval = 0.35
    /// Second-stage "confirm" delay: once a debounce cycle finds a valid
    /// learn candidate, we don't commit it immediately — we wait this much
    /// longer, uninterrupted, before actually saving. Any further edit
    /// during this window cancels the confirm and restarts the normal
    /// debounce → evaluate cycle, so a user who is still mid-correction
    /// (edit, pause, edit again) keeps resetting the clock instead of
    /// having a half-finished correction learned.
    ///
    /// Kept short deliberately: the toast's own dismiss window (see
    /// VocabularyLearnedToastController.autoDismissSeconds, 7s) is where the
    /// user actually gets time to review/undo a learned correction, so this
    /// stage only needs to rule out "still mid-correction," not also serve
    /// as review time.
    static let confirmSeconds: TimeInterval = 0.5
    private static let secureSubroles: Set<String> = ["AXSecureTextField"]

    private let store: VocabularyStore
    private let onLearned: (VocabularyRecord, NSRect?) -> Void

    private var observer: AXObserver?
    private var observedElement: AXUIElement?
    private var observedApplication: AXUIElement?
    private var insertedText: String = ""
    private var anchorPrefix: String = ""
    private var anchorSuffix: String = ""
    private var debounceTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var pendingCandidate: LearnCandidate?
    private var watchGeneration: Int = 0

    init(store: VocabularyStore, onLearned: @escaping (VocabularyRecord, NSRect?) -> Void) {
        self.store = store
        self.onLearned = onLearned
    }

    func beginWatching(insertedText: String, target: FocusedTextTarget) {
        stopWatching()
        watchGeneration += 1
        let generation = watchGeneration
        log("PostInsertionEditWatcher: beginWatching app=\(target.applicationName ?? "?") role=\(target.role ?? "?") subrole=\(target.subrole ?? "nil") insertedLength=\(insertedText.count)")
        guard !insertedText.isEmpty else {
            log("PostInsertionEditWatcher: aborted — inserted text was empty")
            return
        }
        guard !Self.secureSubroles.contains(target.subrole ?? "") else {
            log("PostInsertionEditWatcher: aborted — secure text field")
            return
        }
        guard let anchor = computeAnchor(insertedText: insertedText, element: target.element) else {
            log("PostInsertionEditWatcher: aborted — could not compute a trustworthy anchor (see computeAnchor log line above)")
            return
        }

        var createdObserver: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<PostInsertionEditWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let notificationName = notification as String
            Task { @MainActor in
                watcher.handleNotification(notificationName, element: element)
            }
        }
        let createStatus = AXObserverCreate(target.elementPID, callback, &createdObserver)
        guard createStatus == .success, let observer = createdObserver else {
            log("PostInsertionEditWatcher: aborted — AXObserverCreate failed (\(createStatus.rawValue))")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let valueResult = AXObserverAddNotification(observer, target.element, kAXValueChangedNotification as CFString, refcon)
        guard valueResult == .success else {
            log("PostInsertionEditWatcher: aborted — AXObserverAddNotification for kAXValueChangedNotification failed (\(valueResult.rawValue)); this app/element may not support AX value-change notifications at all")
            return
        }
        let focusResult = AXObserverAddNotification(observer, target.application, kAXFocusedUIElementChangedNotification as CFString, refcon)
        if focusResult != .success {
            log("PostInsertionEditWatcher: failed to register focus-change notification (\(focusResult.rawValue)); relying on \(Int(Self.watchWindowSeconds))s timeout only")
        }

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.observer = observer
        self.observedElement = target.element
        self.observedApplication = target.application
        self.insertedText = insertedText
        self.anchorPrefix = anchor.prefix
        self.anchorSuffix = anchor.suffix
        log("PostInsertionEditWatcher: armed (generation=\(generation)), watching up to \(Int(Self.watchWindowSeconds))s")

        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.watchWindowSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.watchGeneration == generation else { return }
            self.stopWatching()
        }
    }

    func stopWatching() {
        expiryTask?.cancel()
        expiryTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        confirmTask?.cancel()
        confirmTask = nil
        pendingCandidate = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedElement = nil
        observedApplication = nil
        insertedText = ""
        anchorPrefix = ""
        anchorSuffix = ""
    }

    /// Reads the field's value and cursor position immediately after
    /// insertion to compute the exact region that was just inserted,
    /// expressed as the surrounding text that must stay unchanged for a
    /// later diff to be trusted. Returns nil if the field's attributes
    /// aren't readable or the math doesn't add up (never guess).
    private func computeAnchor(insertedText: String, element: AXUIElement) -> (prefix: String, suffix: String)? {
        guard let fieldValue = stringAttribute(element, kAXValueAttribute as CFString) else {
            log("PostInsertionEditWatcher: computeAnchor — kAXValueAttribute not readable on this element")
            return nil
        }
        guard let cursorRange = rangeAttribute(element, kAXSelectedTextRangeAttribute as CFString) else {
            log("PostInsertionEditWatcher: computeAnchor — kAXSelectedTextRangeAttribute not readable on this element")
            return nil
        }

        let fieldNSString = fieldValue as NSString
        let insertedLength = (insertedText as NSString).length
        let insertionEnd = cursorRange.location
        let insertionStart = insertionEnd - insertedLength
        guard insertionStart >= 0, insertionEnd <= fieldNSString.length else {
            log("PostInsertionEditWatcher: computeAnchor — cursor range (\(cursorRange.location),\(cursorRange.length)) doesn't fit insertedLength=\(insertedLength) within fieldLength=\(fieldNSString.length)")
            return nil
        }

        let insertedRange = NSRange(location: insertionStart, length: insertedLength)
        guard fieldNSString.substring(with: insertedRange) == insertedText else {
            // The selection/cursor position doesn't actually bracket the
            // text we just inserted (e.g. a stale kAXSelectedTextRangeAttribute
            // left over from before insertion) — don't guess at the anchor.
            log("PostInsertionEditWatcher: computeAnchor — text at the cursor-derived range doesn't match what was inserted; refusing to guess")
            return nil
        }

        let prefix = fieldNSString.substring(to: insertionStart)
        let suffix = fieldNSString.substring(from: insertionEnd)
        return (prefix, suffix)
    }

    private func handleNotification(_ notification: String, element: AXUIElement) {
        guard observer != nil else {
            log("PostInsertionEditWatcher: notification '\(notification)' received but no watch is active — ignoring")
            return
        }
        log("PostInsertionEditWatcher: notification received: \(notification)")
        if notification == (kAXFocusedUIElementChangedNotification as String) {
            log("PostInsertionEditWatcher: focus changed — stopping watch")
            stopWatching()
            return
        }
        guard notification == (kAXValueChangedNotification as String) else { return }

        // A new edit arrived — even if a candidate from a previous debounce
        // cycle was sitting in the confirm stage waiting to be committed,
        // the user is clearly still correcting, so that pending candidate
        // is stale. Cancel it and restart the debounce → evaluate cycle
        // fresh, exactly as if this were the first edit.
        confirmTask?.cancel()
        confirmTask = nil
        pendingCandidate = nil

        let generation = watchGeneration
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.watchGeneration == generation else { return }
            self.evaluateEdit()
        }
    }

    private func evaluateEdit() {
        guard let observedElement else {
            log("PostInsertionEditWatcher: evaluateEdit — no observedElement, nothing to do")
            return
        }

        guard let currentValue = stringAttribute(observedElement, kAXValueAttribute as CFString) else {
            log("PostInsertionEditWatcher: evaluateEdit — kAXValueAttribute not readable after the edit")
            return
        }
        guard currentValue.hasPrefix(anchorPrefix), currentValue.hasSuffix(anchorSuffix) else {
            // The user edited outside the region SuperDictate inserted,
            // or the field's surrounding structure changed — can't
            // safely isolate what changed, so don't guess. The region is
            // no longer trustworthy, so stop watching entirely.
            log("PostInsertionEditWatcher: evaluateEdit — current field value no longer has the expected prefix/suffix; stopping (anchor no longer trustworthy)")
            stopWatching()
            return
        }

        let currentNSString = currentValue as NSString
        let prefixLength = (anchorPrefix as NSString).length
        let suffixLength = (anchorSuffix as NSString).length
        guard currentNSString.length >= prefixLength + suffixLength else {
            log("PostInsertionEditWatcher: evaluateEdit — field shrank below prefix+suffix length; stopping")
            stopWatching()
            return
        }
        let middleRange = NSRange(location: prefixLength, length: currentNSString.length - prefixLength - suffixLength)
        let currentInsertedRegion = currentNSString.substring(with: middleRange)

        guard let candidate = LearnCandidateDetector.candidate(insertedText: insertedText, editedText: currentInsertedRegion) else {
            // No learnable candidate yet (or a spurious no-op notification) —
            // the anchor region is still valid, so keep watching for a
            // subsequent edit within the remaining window.
            log("PostInsertionEditWatcher: evaluateEdit — inserted region is now \"\(currentInsertedRegion)\" (was \"\(insertedText)\"), no ≤3-word learn candidate; continuing to watch")
            return
        }
        log("PostInsertionEditWatcher: evaluateEdit — learn candidate found: \"\(candidate.source)\" → \"\(candidate.replacement)\"; starting \(Int(Self.confirmSeconds))s confirm stage before saving")
        // A candidate was found, but don't commit it yet — the user may
        // still be mid-correction. Start (or restart) a second, longer
        // timer; only if it fires uninterrupted (no further edits, which
        // would cancel it via handleNotification) do we actually save.
        pendingCandidate = candidate
        let generation = watchGeneration
        confirmTask?.cancel()
        confirmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.confirmSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.watchGeneration == generation else { return }
            self.commitPendingCandidate()
        }
    }

    /// Reads the current anchored middle region. Keeping this separate lets
    /// the watcher rebase after each committed correction instead of ending
    /// the whole watch after the first one.
    private func currentInsertedRegion() -> String? {
        guard let observedElement,
              let currentValue = stringAttribute(observedElement, kAXValueAttribute as CFString),
              currentValue.hasPrefix(anchorPrefix),
              currentValue.hasSuffix(anchorSuffix) else {
            return nil
        }

        let currentNSString = currentValue as NSString
        let prefixLength = (anchorPrefix as NSString).length
        let suffixLength = (anchorSuffix as NSString).length
        guard currentNSString.length >= prefixLength + suffixLength else { return nil }

        let middleRange = NSRange(
            location: prefixLength,
            length: currentNSString.length - prefixLength - suffixLength
        )
        return currentNSString.substring(with: middleRange)
    }

    /// Called only after the confirm-stage timer fires uninterrupted.
    /// Actually persists the candidate found by evaluateEdit() and reports
    /// it, using the observed element's on-screen frame (if resolvable) so
    /// the toast can be positioned near the field the correction happened in.
    private func commitPendingCandidate() {
        guard let candidate = pendingCandidate else {
            log("PostInsertionEditWatcher: commitPendingCandidate — no pending candidate, nothing to do")
            return
        }
        // A learn candidate was found. Keep watching this insertion after
        // the commit and rebase the baseline
        // to the text that is now in the anchored region, so a later edit to
        // another word is detected as a fresh correction instead of being
        // compared against the original full transcript (which would often
        // produce one oversized diff or no candidate at all).
        let regionAfterEdit = currentInsertedRegion()
        if let record = store.recordLearned(source: candidate.source, replacement: candidate.replacement) {
            log("PostInsertionEditWatcher: recorded new correction id=\(record.id)")
            let frame = observedElement.flatMap(resolveElementFrame)
            onLearned(record, frame)
        } else {
            // The store declined: already known, cap reached, or an
            // actual SQLite failure — the store logs the real reason
            // itself (see VocabularyStore.recordLearned).
            log("PostInsertionEditWatcher: recordLearned declined (already known, cap reached, or insert failed — see store log)")
        }

        pendingCandidate = nil
        confirmTask = nil
        debounceTask?.cancel()
        debounceTask = nil

        guard let regionAfterEdit, !regionAfterEdit.isEmpty else {
            log("PostInsertionEditWatcher: committed correction but could not rebase the anchored region; stopping")
            stopWatching()
            return
        }
        insertedText = regionAfterEdit
        log("PostInsertionEditWatcher: rebased after correction; continuing to watch for additional edits")
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func rangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }
}

/// Best-effort conversion of an AXUIElement's on-screen frame
/// (`kAXPositionAttribute`/`kAXSizeAttribute`, which AX reports in a
/// top-left-origin/flipped-Y space) into an AppKit `NSRect`
/// (bottom-left-origin). Returns nil if the attributes aren't readable —
/// never guess. This intentionally doesn't attempt the full
/// multi-screen-aware rigor of `FocusedInsertionTargetLocator`'s
/// `elementFrame`/`appKitRect(fromAXRect:context:)` in TextInsertion.swift
/// (tuned for the demanding text-insertion-anchor use case); it uses the
/// primary screen's height as the flip reference, which is correct for the
/// common single/primary-screen case and a reasonable approximation
/// otherwise — good enough for "place a toast near this field."
@MainActor
func resolveElementFrame(_ element: AXUIElement) -> NSRect? {
    var positionRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
          let positionRef,
          CFGetTypeID(positionRef) == AXValueGetTypeID() else {
        return nil
    }
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let sizeRef,
          CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
        return nil
    }

    let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
    let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)
    guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
        return nil
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &point),
          AXValueGetValue(sizeValue, .cgSize, &size),
          size.width.isFinite, size.height.isFinite,
          size.width > 0, size.height > 0,
          point.x.isFinite, point.y.isFinite else {
        return nil
    }

    let referenceMaxY = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    return NSRect(x: point.x,
                  y: referenceMaxY - point.y - size.height,
                  width: size.width,
                  height: size.height)
}
