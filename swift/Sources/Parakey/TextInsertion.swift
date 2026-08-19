// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor.
//

import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import parakeet_cpp
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Text insertion
//
// Default path: write to general pasteboard, post Cmd+V. If that setup
// fails, fall back to direct Unicode events so a pasteboard problem
// does not automatically lose the transcript. After a successful paste
// event, restore the previous clipboard if it is still at our temporary
// write, so dictation doesn't replace what the user had copied before
// speaking.

func pastedText(from correctedTranscript: String, suffix: PasteSuffix) -> String {
    switch suffix {
    case .appendSpace:
        return correctedTranscript + " "
    case .none:
        return correctedTranscript
    case .appendNewline:
        return correctedTranscript + "\n"
    }
}

/// `fractionCompleted` is the Parakeet model download's overall progress in
/// `0...1`, as reported by `SpeechModelDownloadProgressHandler`. Unlike the
/// previous CoreML ASR stack's multi-file, multi-phase download (list →
/// download N files → compile), parakeet.cpp downloads and verifies a single
/// pinned `.gguf` file, so there is only one phase to describe: 0 means the
/// download hasn't started yet (or the cached file is being checked), values
/// strictly between 0 and 1 mean bytes are actively arriving, and 1 means
/// the file is present and being handed to parakeet.cpp for loading.
func speechModelStartupStatusTitle(_ fractionCompleted: Double) -> String {
    if fractionCompleted <= 0 {
        return "Checking speech model files…"
    } else if fractionCompleted < 1 {
        let percent = min(100, max(0, Int((fractionCompleted * 100).rounded())))
        return "Downloading speech model… \(percent)%"
    } else {
        return "Preparing speech model…"
    }
}

func speechModelStartupProgressValue(_ fractionCompleted: Double) -> Double? {
    guard fractionCompleted > 0, fractionCompleted < 1 else { return nil }
    return (fractionCompleted * 100).rounded() / 100.0   // round to 1%
}

/// Thread-safe throttle that drops duplicate percent values
/// before they hit @MainActor, preventing main-thread flooding.
final class ProgressThrottler: @unchecked Sendable {
    private var lastTitle: String = ""
    private var lastFraction: Double? = nil
    private let lock = NSLock()

    /// Returns true when the progress actually changed and should be dispatched.
    func shouldDispatch(_ title: String, _ fraction: Double?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard title != lastTitle || fraction != lastFraction else { return false }
        lastTitle = title
        lastFraction = fraction
        return true
    }
}

enum TextInsertionStrategy: String {
    case clipboardPaste
    case directUnicode

    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard paste"
        case .directUnicode: return "Direct Unicode typing"
        }
    }
}

struct InsertionTargetScreenGeometry: Sendable {
    let frame: NSRect
    let visibleFrame: NSRect
}

struct InsertionTargetQueryContext: Sendable {
    let applicationPID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let screens: [InsertionTargetScreenGeometry]
    let coordinateReferenceMaxY: CGFloat
    let lastClickPoint: NSPoint?
}

struct FocusedInsertionTargetIdentity: Equatable, Sendable {
    let applicationPID: pid_t
    let windowToken: UInt
    let elementToken: UInt
}

struct FocusedInsertionTargetFrame: Sendable {
    let frame: NSRect
    let visualFrame: NSRect
    let resolutionKind: String
    let identity: FocusedInsertionTargetIdentity
}

struct FocusedInsertionTargetQueryResult: Sendable {
    let applicationPID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let focusedWindowFrame: NSRect?
    let focusedWindowToken: UInt
    let target: FocusedInsertionTargetFrame?
    let diagnostic: String
}

enum RecordingHUDTargetDecision {
    case none
    case update(FocusedInsertionTargetFrame)
    case switchTarget(FocusedInsertionTargetFrame)
}

/// Holds the `FocusedTextTarget` resolved at hotkey-press time for exactly
/// one dictation session. `consume()` clears it as a side effect so a
/// resolved target is used at most once and never leaks into the next
/// dictation — a stale AX reference from a previous session must not be
/// reused if the resolver failed (or hadn't finished) for the current one.
struct PendingTextInsertionTargetStore {
    private(set) var target: FocusedTextTarget?

    mutating func capture(_ target: FocusedTextTarget?) {
        self.target = target
    }

    mutating func consume() -> FocusedTextTarget? {
        defer { target = nil }
        return target
    }
}

/// Which of the three outcomes handleRelease() should take after trying
/// `TextInsertionService` against a resolved `FocusedTextTarget`.
enum TextInsertionRoute: Equatable {
    case usedFocusedTarget
    case fallBackToGlobalInsertion
    case abortToClipboard
}

/// `targetElementStillValid` is what actually distinguishes "the popover
/// closed and the AX element is gone" (abort — falling back to the global
/// mechanism would silently insert into whatever app is now frontmost,
/// exactly what the bug report forbids) from "the element is still there
/// but none of TextInsertionService's three tiers could write to it" (e.g.
/// a read-only field — the global fallback is still the right call there).
/// This can't be inferred from `TextInsertionResult` alone:
/// `TextInsertionService.isProcessAlive` only checks whether the target's
/// *process* is still running, and in the motivating SwiftBar case the
/// process (SwiftBar itself) stays alive after its popover closes — only
/// the AX *element* dies, which surfaces as every tier failing with
/// `.noSupportedInsertionMethod`, not `.targetNoLongerValid`. See
/// `isAXElementStillValid(_:)` for how the caller computes this.
func textInsertionRoute(for result: TextInsertionResult?, targetElementStillValid: Bool) -> TextInsertionRoute {
    guard let result else { return .fallBackToGlobalInsertion }
    switch result {
    case .insertedUsingSelectedText, .insertedUsingValueAndRange, .insertedUsingKeyboardEvents:
        return .usedFocusedTarget
    case .failed(.targetNoLongerValid):
        return .abortToClipboard
    case .failed:
        return targetElementStillValid ? .fallBackToGlobalInsertion : .abortToClipboard
    }
}

/// Probes whether an `AXUIElement` still refers to a live UI element by
/// reading an attribute every element is expected to have. `.success` and
/// most error cases (e.g. `.attributeUnsupported`) mean the element itself
/// is still there, just perhaps not settable/text-bearing; only
/// `.invalidUIElement`/`.cannotComplete` mean the element — and likely the
/// window/popover it belonged to — is actually gone.
func isAXElementStillValid(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
    switch result {
    case .invalidUIElement, .cannotComplete:
        return false
    default:
        return true
    }
}

struct RecordingHUDTargetStabilizer {
    private(set) var initialApplicationPID: pid_t?
    private(set) var confirmedIdentity: FocusedInsertionTargetIdentity?
    private var pendingIdentity: FocusedInsertionTargetIdentity?
    private var pendingCount = 0

    mutating func reset(initialApplicationPID: pid_t?) {
        self.initialApplicationPID = initialApplicationPID
        confirmedIdentity = nil
        pendingIdentity = nil
        pendingCount = 0
    }

    mutating func observe(_ target: FocusedInsertionTargetFrame?) -> RecordingHUDTargetDecision {
        guard let target else {
            pendingIdentity = nil
            pendingCount = 0
            return .none
        }

        if confirmedIdentity == target.identity {
            pendingIdentity = nil
            pendingCount = 0
            return .update(target)
        }

        let requiredCount: Int
        if let confirmedIdentity {
            requiredCount = confirmedIdentity.applicationPID == target.identity.applicationPID ? 2 : 3
        } else {
            requiredCount = initialApplicationPID == target.identity.applicationPID ? 1 : 3
        }

        if pendingIdentity == target.identity {
            pendingCount += 1
        } else {
            pendingIdentity = target.identity
            pendingCount = 1
        }

        guard pendingCount >= requiredCount else { return .none }
        confirmedIdentity = target.identity
        pendingIdentity = nil
        pendingCount = 0
        return .switchTarget(target)
    }
}

/// Requires the same value to be observed `requiredConsecutiveMatches`
/// times in a row before confirming it, resetting on any mismatch or nil.
/// Mirrors `RecordingHUDTargetStabilizer.observe`'s existing "don't act on
/// a single observation" shape elsewhere in this file, generalized to a
/// plain pid rather than a `FocusedInsertionTargetIdentity`. Used by
/// `FocusedInsertionTargetTracker` to avoid reacting to a one-off,
/// transient AX focus blip (Spotlight, Notification Center, another
/// menu-bar extra momentarily owning system-wide AX focus, a race during a
/// real app switch) as if it were a genuine, sustained focus change.
struct PIDDebouncer {
    private var pendingPID: pid_t?
    private var pendingCount = 0
    private let requiredConsecutiveMatches: Int

    init(requiredConsecutiveMatches: Int) {
        self.requiredConsecutiveMatches = requiredConsecutiveMatches
    }

    mutating func observe(_ pid: pid_t?) -> pid_t? {
        guard let pid else {
            pendingPID = nil
            pendingCount = 0
            return nil
        }
        if pendingPID == pid {
            pendingCount += 1
        } else {
            pendingPID = pid
            pendingCount = 1
        }
        guard pendingCount >= requiredConsecutiveMatches else { return nil }
        return pid
    }

    mutating func reset() {
        pendingPID = nil
        pendingCount = 0
    }
}

actor FocusedInsertionTargetTracker {
    // `NSWorkspace.frontmostApplication` (how `context` was built, on the
    // main actor) disagrees with the real AX focus for WKWebView-hosted
    // popovers -- SwiftBar's menu-bar popover is the motivating case
    // (FocusedTextTarget.swift): the popover owns AX focus while
    // `frontmostApplication` still reports whatever app was frontmost
    // before the popover opened. `FocusedInsertionTargetLocator.query`
    // itself is correct once given the right pid; it just needs it.
    // Resolving that here (an actor method, off the main actor) rather
    // than in `insertionTargetQueryContext()` matters because this is a
    // real AX round-trip that can stall -- doing it on the main actor
    // would risk freezing menu-bar UI, exactly what
    // `FocusedTextTargetResolver`'s own doc comment warns callers about.
    private let axAppResolver = FocusedTextTargetResolver()

    // This query runs every `RECORDING_HUD_TARGET_REFRESH_INTERVAL`
    // (~160ms) for a recording's full duration, not once at acquisition --
    // so a diverging pid must be seen on 2 consecutive polls before the
    // override actually applies, or a single transient blip could yank the
    // HUD away from an already-correct target mid-recording. A real
    // popover focus change (SwiftBar opening and staying focused) keeps
    // reporting the same pid on every subsequent poll, so this only costs
    // one extra poll (~160ms) of latency for the case it targets.
    private var overrideDebouncer = PIDDebouncer(requiredConsecutiveMatches: 2)

    func query(context: InsertionTargetQueryContext) -> FocusedInsertionTargetQueryResult {
        // `resolveFocusedApplicationPID()` -- not the heavier
        // `captureTarget()` -- deliberately: this runs on the same ~160ms
        // hot-path poll for a recording's full duration, and
        // `captureTarget()`'s retry loop over the focused UI element plus
        // its unconditional `logCapture()` (several extra AX round-trips
        // and a log write) are appropriate for a once-per-dictation-press
        // call, not one repeated this often.
        let resolved = try? axAppResolver.resolveFocusedApplicationPID()
        let divergingPID = resolved.flatMap { $0.pid != context.applicationPID ? $0.pid : nil }
        let confirmedPID = overrideDebouncer.observe(divergingPID)
        let debouncedResolution = confirmedPID.map { pid -> (pid: pid_t, name: String?, bundleIdentifier: String?) in
            (pid, resolved?.name, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        }
        let effectiveContext = insertionTargetQueryContext(overriding: context, withAXFocusedApplication: debouncedResolution)
        return FocusedInsertionTargetLocator.query(context: effectiveContext)
    }

    /// Called at the start of each new recording so a lingering debounce
    /// count from a previous session's transient blip can never
    /// short-circuit the debounce for a new one.
    func resetOverrideDebounce() {
        overrideDebouncer.reset()
    }
}

/// Overrides `context`'s NSWorkspace-derived application identity with the
/// real AX-focused application when `resolved` disagrees with it -- e.g. a
/// SwiftBar popover, where `NSWorkspace.frontmostApplication` (how
/// `context` was built) still reports whatever app was frontmost before
/// the popover opened, while `resolved` (the real AX focus chain) correctly
/// points at the popover. Falls back to `context` unchanged if `resolved`
/// is nil (AX resolution failed -- no accessibility permission, no focused
/// element, etc.) or agrees with it (the common case, no popover
/// involved), so this can only ever fix a mismatch, never break an
/// already-correct query. `lastClickPoint` is dropped when overriding: it
/// was cached against the NSWorkspace-derived pid, which is now known
/// wrong for this query, so reusing it would hit-test against the wrong
/// application's window. The locator's other resolution tiers (direct
/// focused element, focused-subtree scan, window scan) don't depend on it.
/// A free function taking already-extracted, plain `Sendable` values
/// (rather than an actor method calling `FocusedTextTargetResolver`
/// directly) so this merge decision is unit-testable without needing real
/// Accessibility permission or a live focus-divergent target.
func insertionTargetQueryContext(overriding context: InsertionTargetQueryContext,
                                 withAXFocusedApplication resolved: (pid: pid_t, name: String?, bundleIdentifier: String?)?) -> InsertionTargetQueryContext {
    guard let resolved, resolved.pid != context.applicationPID else { return context }
    return InsertionTargetQueryContext(
        applicationPID: resolved.pid,
        applicationName: resolved.name ?? context.applicationName,
        bundleIdentifier: resolved.bundleIdentifier ?? context.bundleIdentifier,
        screens: context.screens,
        coordinateReferenceMaxY: context.coordinateReferenceMaxY,
        lastClickPoint: nil
    )
}

enum FocusedInsertionTargetLocator {
    private static let editableAttributeName = "AXEditable"
    private static let frameAttributeName = "AXFrame"
    private static let selectedTextMarkerRangeAttributeName = "AXSelectedTextMarkerRange"
    private static let boundsForTextMarkerRangeAttributeName = "AXBoundsForTextMarkerRange"
    private static let textElementRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
    ]
    private static let textElementSubroles: Set<String> = [
        "AXSearchField",
    ]
    private static let queryBudget: TimeInterval = 0.28
    private static let messagingTimeout: Float = 0.16
    private static let maximumScannedElements = 900
    private static let maximumScanDepth = 20

    private struct SearchNode {
        let element: AXUIElement
        let depth: Int
        let assumeFocused: Bool
    }

    static func query(context: InsertionTargetQueryContext) -> FocusedInsertionTargetQueryResult {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + queryBudget
        guard AXIsProcessTrusted() else {
            return result(context: context,
                          focusedWindowFrame: nil,
                          focusedWindowToken: 0,
                          target: nil,
                          detail: "accessibility permission unavailable",
                          startedAt: startedAt)
        }

        let app = AXUIElementCreateApplication(context.applicationPID)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        let focusedResult = copyAttribute(app, kAXFocusedUIElementAttribute as CFString)
        let focused = axElement(from: focusedResult.value)
        let focusedRole = focused.flatMap {
            stringAttribute($0, attribute: kAXRoleAttribute as CFString)
        } ?? "none"

        let focusedWindow = focused.flatMap(windowElement(for:))
            ?? elementAttribute(app, kAXFocusedWindowAttribute as CFString)
            ?? elementAttribute(app, kAXMainWindowAttribute as CFString)
        if let focusedWindow {
            AXUIElementSetMessagingTimeout(focusedWindow, messagingTimeout)
        }
        let focusedWindowFrame = focusedWindow.flatMap {
            elementFrame($0, context: context)
        }
        let focusedWindowToken = focusedWindow.map(CFHash) ?? 0

        if let focused {
            AXUIElementSetMessagingTimeout(focused, messagingTimeout)
            if let target = directTargetFrame(in: focused,
                                              assumeFocused: true,
                                              allowUnfocusedTextElement: false,
                                              resolutionPrefix: "focused",
                                              windowToken: focusedWindowToken,
                                              context: context) {
                return result(context: context,
                              focusedWindowFrame: focusedWindowFrame,
                              focusedWindowToken: focusedWindowToken,
                              target: target,
                              detail: "focused=\(focusedRole), direct",
                              startedAt: startedAt)
            }
        }

        if let clickPoint = context.lastClickPoint,
           focusedWindowFrame?.insetBy(dx: -8, dy: -8).contains(clickPoint) != false,
           let target = targetAtLastClick(clickPoint,
                                          app: app,
                                          windowToken: focusedWindowToken,
                                          context: context) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), click hit-test",
                          startedAt: startedAt)
        }

        var scannedCount = 0
        if let focused,
           let target = findFocusedTextTarget(in: focused,
                                              rootAssumeFocused: true,
                                              windowToken: focusedWindowToken,
                                              context: context,
                                              deadline: deadline,
                                              scannedCount: &scannedCount) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), focused subtree, scanned=\(scannedCount)",
                          startedAt: startedAt)
        }

        if let focusedWindow,
           ProcessInfo.processInfo.systemUptime < deadline,
           let target = findFocusedTextTarget(in: focusedWindow,
                                              rootAssumeFocused: false,
                                              windowToken: focusedWindowToken,
                                              context: context,
                                              deadline: deadline,
                                              scannedCount: &scannedCount) {
            return result(context: context,
                          focusedWindowFrame: focusedWindowFrame,
                          focusedWindowToken: focusedWindowToken,
                          target: target,
                          detail: "focused=\(focusedRole), window scan, scanned=\(scannedCount)",
                          startedAt: startedAt)
        }

        let budgetExpired = ProcessInfo.processInfo.systemUptime >= deadline
        return result(context: context,
                      focusedWindowFrame: focusedWindowFrame,
                      focusedWindowToken: focusedWindowToken,
                      target: nil,
                      detail: "focusedError=\(focusedResult.error.rawValue), focused=\(focusedRole), scanned=\(scannedCount), budgetExpired=\(budgetExpired)",
                      startedAt: startedAt)
    }

    private static func result(context: InsertionTargetQueryContext,
                               focusedWindowFrame: NSRect?,
                               focusedWindowToken: UInt,
                               target: FocusedInsertionTargetFrame?,
                               detail: String,
                               startedAt: TimeInterval) -> FocusedInsertionTargetQueryResult {
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        return FocusedInsertionTargetQueryResult(
            applicationPID: context.applicationPID,
            applicationName: context.applicationName,
            bundleIdentifier: context.bundleIdentifier,
            focusedWindowFrame: focusedWindowFrame,
            focusedWindowToken: focusedWindowToken,
            target: target,
            diagnostic: "\(detail), \(String(format: "%.1f", elapsedMilliseconds)) ms"
        )
    }

    private static func findFocusedTextTarget(in root: AXUIElement,
                                              rootAssumeFocused: Bool,
                                              windowToken: UInt,
                                              context: InsertionTargetQueryContext,
                                              deadline: TimeInterval,
                                              scannedCount: inout Int) -> FocusedInsertionTargetFrame? {
        var queue = [SearchNode(element: root, depth: 0, assumeFocused: rootAssumeFocused)]
        var queueIndex = 0
        var visited: Set<UInt> = []

        while queueIndex < queue.count,
              scannedCount < maximumScannedElements,
              ProcessInfo.processInfo.systemUptime < deadline {
            let node = queue[queueIndex]
            queueIndex += 1
            let token = CFHash(node.element)
            guard visited.insert(token).inserted else { continue }
            scannedCount += 1
            AXUIElementSetMessagingTimeout(node.element, messagingTimeout)

            let reportsFocus = boolAttribute(node.element,
                                             attribute: kAXFocusedAttribute as CFString) == true
            if node.assumeFocused || reportsFocus,
               let target = directTargetFrame(in: node.element,
                                              assumeFocused: true,
                                              allowUnfocusedTextElement: false,
                                              resolutionPrefix: node.depth == 0 ? "focused" : "window scan",
                                              windowToken: windowToken,
                                              context: context) {
                return target
            }

            guard node.depth < maximumScanDepth else { continue }
            if let nestedFocused = elementAttribute(node.element,
                                                    kAXFocusedUIElementAttribute as CFString),
               !CFEqual(nestedFocused, node.element) {
                queue.append(SearchNode(element: nestedFocused,
                                        depth: node.depth + 1,
                                        assumeFocused: true))
            }
            for selected in elementArrayAttribute(node.element,
                                                  kAXSelectedChildrenAttribute as CFString) {
                queue.append(SearchNode(element: selected,
                                        depth: node.depth + 1,
                                        assumeFocused: false))
            }
            for child in elementArrayAttribute(node.element, kAXChildrenAttribute as CFString) {
                queue.append(SearchNode(element: child,
                                        depth: node.depth + 1,
                                        assumeFocused: false))
            }
        }
        return nil
    }

    private static func targetAtLastClick(_ point: NSPoint,
                                          app: AXUIElement,
                                          windowToken: UInt,
                                          context: InsertionTargetQueryContext) -> FocusedInsertionTargetFrame? {
        let axPoint = NSPoint(x: point.x,
                              y: context.coordinateReferenceMaxY - point.y)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app,
                                              Float(axPoint.x),
                                              Float(axPoint.y),
                                              &hit) == .success,
              var current = hit else {
            return nil
        }

        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(current, messagingTimeout)
            if let target = directTargetFrame(in: current,
                                              assumeFocused: false,
                                              allowUnfocusedTextElement: true,
                                              resolutionPrefix: "click",
                                              windowToken: windowToken,
                                              context: context) {
                return target
            }
            guard let parent = elementAttribute(current, kAXParentAttribute as CFString),
                  !CFEqual(parent, current) else {
                break
            }
            current = parent
        }
        return nil
    }

    private static func directTargetFrame(in element: AXUIElement,
                                          assumeFocused: Bool,
                                          allowUnfocusedTextElement: Bool,
                                          resolutionPrefix: String,
                                          windowToken: UInt,
                                          context: InsertionTargetQueryContext) -> FocusedInsertionTargetFrame? {
        let reportsFocus = boolAttribute(element,
                                         attribute: kAXFocusedAttribute as CFString) == true
        let isTextInputElement = isTextInputElement(element)
        guard assumeFocused || reportsFocus || (allowUnfocusedTextElement && isTextInputElement) else {
            return nil
        }

        let identity = FocusedInsertionTargetIdentity(
            applicationPID: context.applicationPID,
            windowToken: windowToken,
            elementToken: CFHash(element)
        )
        let elementFrame = elementFrame(element, context: context)
        if isTextInputElement,
           let caret = caretFrame(in: element, context: context) {
            let visualFrame: NSRect
            if let elementFrame,
               isTextInputElement,
               isReasonableTextInputFrame(elementFrame, near: caret.frame, context: context) {
                visualFrame = visualTargetFrame(elementFrame: elementFrame,
                                                caretFrame: caret.frame,
                                                context: context)
            } else {
                visualFrame = caret.frame
            }
            return FocusedInsertionTargetFrame(
                frame: caret.frame,
                visualFrame: visualFrame,
                resolutionKind: "\(resolutionPrefix) \(caret.resolutionKind)",
                identity: identity
            )
        }

        guard isTextInputElement,
              let elementFrame,
              isReasonableTextInputFrame(elementFrame, near: elementFrame, context: context) else {
            return nil
        }
        return FocusedInsertionTargetFrame(
            frame: elementFrame,
            visualFrame: elementFrame,
            resolutionKind: "\(resolutionPrefix) text element",
            identity: identity
        )
    }

    static func visualTargetFrame(elementFrame: NSRect,
                                  caretFrame: NSRect,
                                  context: InsertionTargetQueryContext) -> NSRect {
        guard let visible = visibleFrame(containing: NSPoint(x: caretFrame.midX,
                                                             y: caretFrame.midY),
                                         context: context),
              elementFrame.height > max(220, visible.height * 0.34) else {
            return elementFrame
        }

        // A native document editor often exposes its entire page as one
        // AXTextArea. Keep the block's left edge, but anchor vertically to
        // the current line instead of placing the HUD above the whole page.
        return NSRect(x: elementFrame.minX,
                      y: caretFrame.minY,
                      width: elementFrame.width,
                      height: caretFrame.height)
    }

    private static func isTextInputElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, attribute: kAXSubroleAttribute as CFString) ?? ""
        if textElementRoles.contains(role) || textElementSubroles.contains(subrole) {
            return true
        }
        if boolAttribute(element, attribute: editableAttributeName as CFString) == true {
            return true
        }
        let hasSelectedRange = copyAttribute(element,
                                             kAXSelectedTextRangeAttribute as CFString).error == .success
        return hasSelectedRange
            && (isAttributeSettable(element, kAXValueAttribute as CFString)
                || isAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString))
    }

    private static func caretFrame(in element: AXUIElement,
                                   context: InsertionTargetQueryContext) -> (frame: NSRect, resolutionKind: String)? {
        let markerRange = copyAttribute(element, selectedTextMarkerRangeAttributeName as CFString)
        if markerRange.error == .success,
           let markerRangeValue = markerRange.value {
            var boundsRaw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element,
                                                          boundsForTextMarkerRangeAttributeName as CFString,
                                                          markerRangeValue,
                                                          &boundsRaw) == .success,
               let rect = cgRect(from: boundsRaw),
               let caret = normalizedCaretRect(rect) {
                return (appKitRect(fromAXRect: caret, context: context), "caret marker")
            }
        }

        let rangeResult = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard rangeResult.error == .success,
              let rangeRaw = rangeResult.value,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        let candidates = [range, CFRange(location: range.location, length: max(range.length, 1))]
        for candidate in candidates {
            var candidateRange = candidate
            guard let candidateValue = AXValueCreate(.cfRange, &candidateRange) else { continue }
            var boundsRaw: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                candidateValue,
                &boundsRaw
            ) == .success,
            let rect = cgRect(from: boundsRaw),
            let caret = normalizedCaretRect(rect) else {
                continue
            }
            return (appKitRect(fromAXRect: caret, context: context), "caret range")
        }
        return nil
    }

    private static func normalizedCaretRect(_ rect: CGRect) -> CGRect? {
        guard rect.minX.isFinite,
              rect.minY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width >= 0,
              rect.height > 0,
              rect.height <= 120,
              rect.width <= max(12, rect.height * 1.5) else {
            return nil
        }
        return rect.width > 0
            ? rect
            : CGRect(x: rect.origin.x, y: rect.origin.y, width: 2, height: rect.height)
    }

    private static func elementFrame(_ element: AXUIElement,
                                     context: InsertionTargetQueryContext) -> NSRect? {
        let directFrame = copyAttribute(element, frameAttributeName as CFString)
        if directFrame.error == .success,
           let rect = cgRect(from: directFrame.value),
           rect.width > 0,
           rect.height > 0 {
            return appKitRect(fromAXRect: rect, context: context)
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard axPoint(element, attribute: kAXPositionAttribute as CFString, value: &position),
              axSize(element, attribute: kAXSizeAttribute as CFString, value: &size),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return appKitRect(fromAXRect: CGRect(origin: position, size: size), context: context)
    }

    private static func isReasonableTextInputFrame(_ frame: NSRect,
                                                   near anchor: NSRect,
                                                   context: InsertionTargetQueryContext) -> Bool {
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }
        guard frame.insetBy(dx: -8, dy: -8).contains(NSPoint(x: anchor.midX, y: anchor.midY)) else {
            return false
        }
        guard let visible = visibleFrame(containing: NSPoint(x: anchor.midX, y: anchor.midY),
                                         context: context) else {
            return false
        }
        if frame.width > visible.width * 0.92,
           frame.height > visible.height * 0.55 {
            return false
        }
        return frame.height <= visible.height * 0.82
    }

    private static func visibleFrame(containing point: NSPoint,
                                     context: InsertionTargetQueryContext) -> NSRect? {
        if let screen = context.screens.first(where: { $0.frame.contains(point) }) {
            return screen.visibleFrame
        }
        return context.screens.first?.visibleFrame
    }

    private static func windowElement(for element: AXUIElement) -> AXUIElement? {
        elementAttribute(element, kAXWindowAttribute as CFString)
            ?? elementAttribute(element, kAXTopLevelUIElementAttribute as CFString)
    }

    private static func copyAttribute(_ element: AXUIElement,
                                      _ attribute: CFString) -> (error: AXError, value: CFTypeRef?) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        return (error, raw)
    }

    private static func axElement(from raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func elementAttribute(_ element: AXUIElement,
                                         _ attribute: CFString) -> AXUIElement? {
        axElement(from: copyAttribute(element, attribute).value)
    }

    private static func elementArrayAttribute(_ element: AXUIElement,
                                              _ attribute: CFString) -> [AXUIElement] {
        let result = copyAttribute(element, attribute)
        guard result.error == .success, let raw = result.value else { return [] }
        if let single = axElement(from: raw) { return [single] }
        return raw as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ element: AXUIElement,
                                        attribute: CFString) -> String? {
        let result = copyAttribute(element, attribute)
        guard result.error == .success else { return nil }
        return result.value as? String
    }

    private static func boolAttribute(_ element: AXUIElement,
                                      attribute: CFString) -> Bool? {
        let result = copyAttribute(element, attribute)
        guard result.error == .success else { return nil }
        return result.value as? Bool
    }

    private static func isAttributeSettable(_ element: AXUIElement,
                                            _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private static func cgRect(from raw: CFTypeRef?) -> CGRect? {
        guard let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    private static func axPoint(_ element: AXUIElement,
                                attribute: CFString,
                                value: inout CGPoint) -> Bool {
        let result = copyAttribute(element, attribute)
        guard result.error == .success,
              let raw = result.value,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(axValue) == .cgPoint
            && AXValueGetValue(axValue, .cgPoint, &value)
    }

    private static func axSize(_ element: AXUIElement,
                               attribute: CFString,
                               value: inout CGSize) -> Bool {
        let result = copyAttribute(element, attribute)
        guard result.error == .success,
              let raw = result.value,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return false
        }
        let axValue = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(axValue) == .cgSize
            && AXValueGetValue(axValue, .cgSize, &value)
    }

    private static func appKitRect(fromAXRect rect: CGRect,
                                   context: InsertionTargetQueryContext) -> NSRect {
        NSRect(x: rect.origin.x,
               y: context.coordinateReferenceMaxY - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }
}

func textInsertionStrategyChain(primary: TextInsertionStrategy) -> [TextInsertionStrategy] {
    switch primary {
    case .clipboardPaste:
        return [.clipboardPaste, .directUnicode]
    case .directUnicode:
        return [.directUnicode]
    }
}

func textInsertionStrategyDescription(primary: TextInsertionStrategy) -> String {
    let strategies = textInsertionStrategyChain(primary: primary).map(\.displayName)
    guard let first = strategies.first else { return "Unavailable" }
    guard strategies.count > 1 else { return first }
    return "\(first) with \(strategies.dropFirst().joined(separator: ", ")) fallback"
}

func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []

    for character in text {
        let units = Array(String(character).utf16)
        if units.count > maxUnits {
            if !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            chunks.append(units)
            continue
        }
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }
        current.append(contentsOf: units)
    }

    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

struct KeyboardEventStep: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

func clipboardPasteKeyboardEventSteps(commandKey: CGKeyCode,
                                              pasteKey: CGKeyCode) -> [KeyboardEventStep] {
    [
        KeyboardEventStep(virtualKey: commandKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: false, flags: .maskCommand),
        KeyboardEventStep(virtualKey: commandKey, keyDown: false, flags: []),
    ]
}

private func postKeyboardEventSteps(_ steps: [KeyboardEventStep]) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let events = steps.compactMap { step -> CGEvent? in
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: step.virtualKey,
                                  keyDown: step.keyDown) else {
            return nil
        }
        event.flags = step.flags
        return event
    }
    guard events.count == steps.count else { return false }

    for event in events {
        event.post(tap: .cghidEventTap)
    }
    return true
}

@MainActor
enum KeyboardShortcutPoster {
    @discardableResult
    static func postReturn() -> Bool {
        postKeyboardEventSteps([
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: true, flags: []),
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: false, flags: []),
        ])
    }
}

@MainActor
enum TextInserter {
    nonisolated static let defaultStrategy = TextInsertionStrategy.clipboardPaste

    nonisolated static var defaultStrategyDescription: String {
        textInsertionStrategyDescription(primary: defaultStrategy)
    }

    @discardableResult
    static func insert(_ text: String, strategy: TextInsertionStrategy = defaultStrategy) -> Bool {
        for candidate in textInsertionStrategyChain(primary: strategy) {
            if insert(text, using: candidate) {
                if candidate != strategy {
                    log("text insertion fallback succeeded: \(candidate.displayName)")
                }
                return true
            }
            log("text insertion attempt failed: \(candidate.displayName)")
        }
        return false
    }

    private static func insert(_ text: String, using strategy: TextInsertionStrategy) -> Bool {
        switch strategy {
        case .clipboardPaste:
            return ClipboardPasteInserter.insert(text)
        case .directUnicode:
            return DirectUnicodeInserter.insert(text)
        }
    }
}

// NSPasteboard isn't marked Sendable by AppKit, but ClipboardPasteInserter's
// restorePasteboard(_:...) needs to hand one across a
// DispatchQueue.global(qos:).async / DispatchQueue.main.async boundary (to
// let PasteConfirmationPoller's wait happen off the main actor per the
// threading note below) while a completion callback that always signals
// via `@unchecked Sendable`-boxed test state observes the result. Every
// actual read/write of the pasteboard here is confined to the main queue
// (see `DispatchQueue.main.async` below) — the background queue only ever
// holds the reference, never touches it — so this conformance describes
// how this file uses NSPasteboard, not a claim that NSPasteboard is safe
// for arbitrary concurrent access in general.
extension NSPasteboard: @retroactive @unchecked Sendable {}

@MainActor
enum ClipboardPasteInserter {
    private static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    private static let confirmationPollInterval: TimeInterval = 0.05
    private static let confirmationTimeout: TimeInterval = 2.0
    private static let confirmationUnreadableBailout: TimeInterval = 0.35

    // The nspasteboard.org convention (honored by clipboard-history tools —
    // Alfred, Paste, Maccy, Raycast — and the closest public signal for
    // "this write isn't a real user copy, don't treat it as one") for a
    // pasteboard item that exists only to be immediately consumed and then
    // reverted, same as a password manager's one-shot paste-and-forget.
    // See docs/superpowers/specs/2026-08-20-universal-clipboard-
    // interference-design.md.
    private static let transientMarkerType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `transient` marks the write as ephemeral (about to be immediately
    /// consumed by a synthetic paste, then reverted) so external observers
    /// — clipboard-history tools, and best-effort Continuity/Universal
    /// Clipboard — don't mistake it for a real user copy. Defaults to
    /// `false`: the two other call sites (ParakeyApp.swift's "save
    /// transcript to clipboard after target disappeared" safety net, and
    /// SelfTest.swift's pasteboard probe) write content meant to be pasted
    /// manually, possibly much later, and must not be marked transient.
    static func write(_ text: String, to pb: NSPasteboard, transient: Bool = false) -> Bool {
        pb.clearContents()
        guard transient, let stringData = text.data(using: .utf8) else {
            return pb.setString(text, forType: .string)
        }
        let item = NSPasteboardItem()
        item.setData(stringData, forType: .string)
        item.setData(Data(), forType: transientMarkerType)
        return pb.writeObjects([item])
    }

    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        guard write(text, to: pasteboard, transient: true) else {
            log("pasteboard write failed")
            return false
        }
        log("clipboard: wrote transient dictation text (org.nspasteboard.TransientType)")
        let transientChangeCount = pasteboard.changeCount

        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps) else {
            log("paste event creation failed")
            previous.restore(to: pasteboard)
            return false
        }
        restorePasteboard(previous,
                          ifStillTemporaryText: text,
                          changeCount: transientChangeCount,
                          pasteboard: pasteboard,
                          valueReader: PasteConfirmationPoller.currentFocusedElementValueReader(),
                          confirm: PasteConfirmationPoller.waitForPasteConfirmation)
        return true
    }

    // Waits (on a background queue, never the main actor — see the plan's
    // threading note) for the target app's focused element to actually
    // contain the pasted text before restoring the user's previous
    // clipboard contents, instead of guessing a fixed delay. On slow/laggy
    // target apps a fixed delay could fire before the paste lands, clobbering
    // the dictated text with the restored clipboard; on fast apps it wasted
    // up to 0.35s doing nothing. If confirmation never arrives within
    // confirmationTimeout, this still restores anyway (better to eventually
    // give the clipboard back than leave the user's previous clipboard
    // contents lost forever).
    //
    // `completion` is a test-only seam (always nil in production, called
    // from `insert(_:)` above with the default): it lets self-tests observe
    // when the guarded main-queue restore-or-skip decision has actually run,
    // without duplicating this function's guard logic in a second,
    // hand-copied implementation. Not private (fileprivate, i.e. visible
    // anywhere in this file) for exactly that reason — ParakeySelfTest lives
    // in this same file and calls this real function directly.
    static func restorePasteboard(_ snapshot: PasteboardSnapshot,
                                              ifStillTemporaryText text: String,
                                              changeCount: Int,
                                              pasteboard: NSPasteboard,
                                              valueReader: @escaping @Sendable () -> String?,
                                              confirm: @escaping @Sendable (String, String?, TimeInterval, TimeInterval, TimeInterval, @escaping @Sendable () -> String?) -> Bool,
                                              completion: (@Sendable () -> Void)? = nil) {
        // Read these @MainActor-isolated static constants into plain local
        // values HERE, while still on the main actor, before constructing
        // the DispatchQueue.global(qos:).async closure below. A Docker
        // swift:6.0-jammy repro of this exact isolation shape confirmed
        // referencing them directly from inside that closure is a real
        // compile error ("main actor-isolated static property ... can not
        // be referenced from a Sendable closure") -- capturing plain
        // TimeInterval locals instead sidesteps that entirely, since a
        // Double has no actor affiliation to strip away.
        let pollInterval = confirmationPollInterval
        let timeout = confirmationTimeout
        let unreadableBailout = confirmationUnreadableBailout
        DispatchQueue.global(qos: .userInitiated).async {
            // Baseline is captured here (on the background queue, as the
            // very first thing this async work does — effectively
            // "immediately after" the Cmd+V keystroke was posted on the
            // main actor moments ago) rather than inside `confirm`, so a
            // field that already happens to contain `text` before this
            // paste completes doesn't cause an immediate false-positive
            // confirmation. See PasteConfirmationPoller's doc comment for
            // the full rationale.
            let baselineValue = valueReader()
            _ = confirm(text, baselineValue, pollInterval, timeout, unreadableBailout, valueReader)
            DispatchQueue.main.async {
                guard pasteboard.changeCount == changeCount,
                      pasteboard.string(forType: .string) == text else {
                    // Something else took ownership of the pasteboard while
                    // this was waiting — could be the user copying something
                    // new on this Mac, or an incoming Universal Clipboard
                    // write. Logged so a future Universal Clipboard report
                    // can be correlated against this timeline.
                    log("clipboard: restore skipped, pasteboard changed during paste wait")
                    completion?()
                    return
                }
                snapshot.restore(to: pasteboard)
                log("clipboard: restored previous contents")
                completion?()
            }
        }
    }

    private static func post(_ steps: [KeyboardEventStep]) -> Bool {
        // Post Command as real key events instead of only tagging the V
        // events with .maskCommand. Sleep/wake can leave session modifier
        // state unreliable for flag-only synthetic shortcuts.
        return postKeyboardEventSteps(steps)
    }
}

@MainActor
struct PasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for value in item.values {
                restored.setData(value.data, forType: value.type)
            }
            return restored
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}

@MainActor
enum DirectUnicodeInserter {
    private static let maxUTF16UnitsPerEvent = 20

    static func insert(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true

        for chunk in unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent) {
            didPostAll = post(chunk, source: source) && didPostAll
        }
        return didPostAll
    }

    private static func post(_ units: [UInt16], source: CGEventSource?) -> Bool {
        // Each chunk posts a keyDown AND a matching keyUp carrying the
        // same unicode payload — standard CGEvent unicode-typing
        // practice. A keyDown-only stream leaves apps that track key
        // state believing a key is still held.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        for event in [down, up] {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

