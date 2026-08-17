// SuperDictate — small auto-dismissing HUD toast shown right after
// PostInsertionEditWatcher learns a new correction, with an "Undo" button
// that deletes the just-learned row within a short window.

import AppKit
import CoreGraphics
import Foundation

@MainActor
final class VocabularyLearnedToastController {
    private static let autoDismissSeconds: TimeInterval = 7
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    // Restyle state for dismiss(confirmed:), captured from makeContentView's
    // return value at show()-time so dismiss can restyle the label in place
    // (strikethrough + recolor the arrow) without walking the view hierarchy.
    private weak var label: NSTextField?
    private var arrowRange: NSRange?
    private var accentColor: NSColor?
    private var textColor: NSColor?

    // Global Escape interception (Task 1): a CGEventTap scoped to Escape
    // only and to this toast's lifetime, mirroring HotkeyListener's tap in
    // Hotkeys.swift so Escape reaches the toast even when the frontmost app
    // — not this nonactivating panel — is key. `pendingUndo` is whatever
    // show() currently wants Escape to trigger; the tap callback is a free
    // C function and can't capture per-toast state directly, so it reaches
    // back into this instance via userInfo instead.
    private var escapeTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?
    private var suppressEscapeKeyUp = false
    private var pendingUndo: (() -> Void)?

    // Supplied by ParakeyApp at construction time, reading the same
    // recording-active state HotkeyListener.isRecordingActive already
    // exposes (Hotkeys.swift). HotkeyListener has its own long-lived
    // Escape tap that cancels an active recording; because this toast's
    // tap is created later (when the toast shows), it runs ahead of
    // HotkeyListener's tap in the .headInsertEventTap chain and would
    // otherwise swallow Escape before HotkeyListener ever saw it. When
    // this returns true, the toast's tap must not swallow Escape at all —
    // it defers to HotkeyListener's own cancel-recording handling.
    var isRecordingActive: (() -> Bool)?

    func show(_ record: VocabularyRecord, store: VocabularyStore, targetFrame: NSRect? = nil) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        teardownEscapeTap()

        let panel = Self.makePanel()
        let lightBackground = Self.shouldUseLightBackground()
        let accentColor = Settings.shared.recordingHUDRecordingColor.resolvedColor(lightBackground: lightBackground)
        self.accentColor = accentColor

        // Single shared undo action, guarded by its own one-shot flag so it
        // is idempotent no matter which of the three triggers (Escape via
        // the global tap, Escape via the local button keyEquivalent
        // fallback, or a click on the pill) fires first — the rest become
        // no-ops.
        var didUndo = false
        let undo: () -> Void = { [weak self] in
            guard !didUndo else { return }
            didUndo = true
            store.delete(id: record.id)
            self?.dismiss(confirmed: false)
        }
        pendingUndo = undo

        let content = Self.makeContentView(
            record: record,
            lightBackground: lightBackground,
            accentColor: accentColor,
            onUndo: undo
        )
        self.label = content.label
        self.arrowRange = content.arrowRange
        self.textColor = content.textColor
        // Resize the panel to the content's already-computed size *before*
        // assigning it as contentView — setting `panel.contentView` resets
        // the view's frame to fill the panel's *existing* content rect, so
        // resizing after assignment would silently discard the measured
        // width (every toast would render at minPillWidth instead of fitting
        // its text). Positioning below reads panel.frame.size, so this must
        // happen first.
        panel.setContentSize(content.view.frame.size)
        panel.contentView = content.view
        if let targetFrame, let screen = Self.screenFor(point: NSPoint(x: targetFrame.midX, y: targetFrame.midY)) {
            Self.positionAboveTarget(panel, targetFrame: targetFrame, screen: screen)
        } else {
            Self.positionBottomRight(panel)
        }

        // Anchor the content view's scale at its own center (rather than
        // the default bottom-left corner) so the grow-in/shrink-out below
        // scales symmetrically outward from/inward to the pill's center,
        // not from a corner. Changing anchorPoint shifts `position` (it's
        // expressed in the same coordinate space as the layer's bounds
        // scaled by the anchor), so `position` is recomputed to compensate
        // and keep the layer's on-screen frame exactly where
        // positionAboveTarget/positionBottomRight already placed it.
        if let layer = content.view.layer {
            let bounds = layer.bounds
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        // Animate in: start scaled-down + transparent, grow/fade to full
        // size/opacity. Mirrors the visual effect of RecordingHUDView's
        // reveal animation, implemented here with plain Core
        // Animation/NSAnimationContext since this toast is a one-shot
        // show/hide rather than a continuously-live, per-frame-driven view.
        panel.alphaValue = 0
        content.view.layer?.setAffineTransform(CGAffineTransform(scaleX: Self.entryExitScale, y: Self.entryExitScale))
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // Remove any exit animation left over from a dismiss() that was
        // still in flight when this new show() started reusing the same
        // key — without this, scaleOut (added under a different key by a
        // near-simultaneous dismiss) can stay attached to this content
        // view's layer and race with scaleIn on the same "transform"
        // keyPath, leaving Core Animation's multi-animation resolution to
        // decide the presented value instead of this code.
        content.view.layer?.removeAnimation(forKey: "toastScaleOut")
        let scaleIn = CABasicAnimation(keyPath: "transform")
        scaleIn.fromValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
        scaleIn.toValue = CATransform3DIdentity
        scaleIn.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
        scaleIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scaleIn.fillMode = .forwards
        scaleIn.isRemovedOnCompletion = false
        content.view.layer?.add(scaleIn, forKey: "toastScaleIn")
        content.view.layer?.setAffineTransform(.identity)

        installEscapeTap()

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(confirmed: true)
        }
    }

    // MARK: - Global Escape interception (Task 1)

    /// Installs a CGEventTap scoped to Escape (virtual keycode 53) only,
    /// mirroring HotkeyListener.start()'s tap in Hotkeys.swift (same
    /// `.cgSessionEventTap`/`.headInsertEventTap` options, run loop source
    /// registration, and mach port lifecycle) so this toast's Undo works
    /// even when the frontmost app — not this nonactivating panel — has
    /// keyboard focus. Scoped independently of HotkeyListener's own tap;
    /// the two don't interact.
    private func installEscapeTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<VocabularyLearnedToastController>.fromOpaque(userInfo).takeUnretainedValue()
                // tapDisabledByTimeout/tapDisabledByUserInput mean the OS
                // disabled the tap itself (e.g. this callback ran too
                // slowly once) — re-enable it, mirroring HotkeyListener's
                // own tap (Hotkeys.swift:830-837). Without this, a tap
                // disabled between a swallowed Escape keyDown and its
                // matching keyUp never reactivates, so the keyUp reaches
                // the frontmost app unbalanced — the same keyUp-leak class
                // fixed elsewhere in this file, via a different path.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let escapeTap = controller.escapeTap {
                            CGEvent.tapEnable(tap: escapeTap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                // Anything else outside our mask carries no keycode worth
                // reading — pass it through untouched.
                guard type == .keyDown || type == .keyUp,
                      CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == ESCAPE_KEYCODE
                else {
                    return Unmanaged.passUnretained(event)
                }
                let suppress = MainActor.assumeIsolated {
                    controller.handleEscapeTapEvent(isKeyDown: type == .keyDown, flags: event.flags)
                }
                return suppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            // No Input Monitoring permission (or tap creation otherwise
            // failed) — fall back silently to the local NSButton
            // keyEquivalent. In practice this fallback only fires when the
            // panel itself is key (the panel is non-activating and shown
            // via orderFrontRegardless(), so that's rare — mostly after a
            // click, which already triggers undo directly via the click
            // handler anyway), so Escape mostly won't reach undo without
            // the tap; the click-anywhere-on-the-toast affordance still
            // works regardless.
            log("VocabularyLearnedToastController: escape tap create failed — falling back to local keyEquivalent")
            return
        }

        escapeTap = tap
        escapeRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), escapeRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns whether the event should be swallowed (return nil from the
    /// tap callback). Mirrors the shape of
    /// HotkeyTransitionState.transitionEscape's suppressEscapeKeyUp
    /// handling in Hotkeys.swift (not an exact match — that function also
    /// handles autorepeat, this one doesn't): arm the flag
    /// on keyDown and only clear it when the matching keyUp itself is
    /// swallowed — never as a side effect of anything else (in particular,
    /// dismiss(confirmed:)'s teardown must not clear it before the keyUp
    /// has arrived, or the keyUp leaks through to the frontmost app while
    /// the keyDown was swallowed).
    ///
    /// Also defers to an active recording: HotkeyListener (Hotkeys.swift)
    /// has its own long-lived Escape tap that cancels an active recording,
    /// and it runs *after* this tap in the tap chain (this one is created
    /// later, when the toast shows, so it sits ahead of HotkeyListener's
    /// under .headInsertEventTap). If a recording is active, Escape must
    /// keep meaning "cancel the recording", not "undo the vocabulary
    /// learn" — pass the event through untouched so HotkeyListener's tap
    /// still gets to see and handle it, and don't arm/clear our own
    /// suppression state for it at all (that keyDown/keyUp pair is
    /// HotkeyListener's to manage, not ours).
    private func handleEscapeTapEvent(isKeyDown: Bool, flags: CGEventFlags) -> Bool {
        if isKeyDown {
            // Modified Escape (e.g. Cmd+Opt+Escape / Force Quit) is a
            // different gesture entirely, not "undo the correction" — only
            // bare Escape should be swallowed. Without this check, Force
            // Quit (and any other modified-Escape combo) would get eaten by
            // this tap for up to 7 seconds after every auto-learned
            // correction.
            guard flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else { return false }
            guard isRecordingActive?() != true, pendingUndo != nil else { return false }
            suppressEscapeKeyUp = true
            pendingUndo?()
            return true
        }
        guard suppressEscapeKeyUp else { return false }
        suppressEscapeKeyUp = false
        return true
    }

    /// Invalidates the tap and removes its run loop source. Safe to call
    /// even when no tap is installed (tap creation can fail).
    private func teardownEscapeTap() {
        if let escapeTap {
            CGEvent.tapEnable(tap: escapeTap, enable: false)
            CFMachPortInvalidate(escapeTap)
        }
        if let escapeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeRunLoopSource, .commonModes)
        }
        escapeTap = nil
        escapeRunLoopSource = nil
        suppressEscapeKeyUp = false
        pendingUndo = nil
    }

    /// Scale the toast animates from (on appear) / to (on dismiss). Applied
    /// to the content view's layer, which has its anchorPoint recentered in
    /// `show(_:store:targetFrame:)` so scaling grows from/shrinks toward
    /// the pill's own center rather than a corner.
    private static let entryExitScale: CGFloat = 0.85

    /// Hold time for the "rejected" restyle (strikethrough + dim + recolored
    /// arrow) before the normal exit animation plays, long enough to read as
    /// a deliberate beat rather than a flicker.
    private static let rejectRestyleHoldSeconds: TimeInterval = 0.25
    /// Duration of the "accepted" glow/scale-bump pulse.
    private static let confirmGlowSeconds: TimeInterval = 0.35
    /// Hold time for the "confirmed" glow pulse before the normal exit
    /// animation plays. Shorter than rejectRestyleHoldSeconds (this path is
    /// non-interactive/automatic, so it shouldn't make the user wait as
    /// long as the reject path does) but long enough that the glow is
    /// actually visible before the fade-out starts covering it — a zero
    /// hold made the glow play almost entirely underneath the simultaneous
    /// fade, effectively invisible.
    private static let confirmGlowHoldSeconds: TimeInterval = 0.2

    /// `confirmed` distinguishes why the toast is going away: `true` for
    /// the 7s auto-dismiss timer (the correction was accepted/kept — plays
    /// a brief accent-colored glow pulse), `false` for Escape/click-to-undo
    /// (the correction was rejected — restyles the label with strikethrough
    /// before fading out). No default: every call site must say which.
    private func dismiss(confirmed: Bool) {
        // Guard against double-invocation (e.g. the 7s auto-timer firing
        // just as the user clicks/Escapes the toast): once `panel` is nil'd
        // out below, a second call here is a no-op instead of
        // animating/ordering-out an already-gone panel. This happens
        // synchronously, before the confirmed==false path's restyle hold,
        // so a second dismiss() arriving during that hold is still caught.
        guard let panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        self.panel = nil
        let label = self.label
        let arrowRange = self.arrowRange
        let accentColor = self.accentColor
        let textColor = self.textColor
        self.label = nil
        self.arrowRange = nil
        self.accentColor = nil
        self.textColor = nil
        // Tear down the tap here rather than inside the Escape keyDown
        // handler that may have triggered this dismiss: the matching keyUp
        // (see handleEscapeTapEvent's suppressEscapeKeyUp) needs the tap
        // still alive to be swallowed. Tearing down at the end of the exit
        // animation, once the toast is actually gone, keeps that window
        // open. Capture locally rather than reading the instance vars
        // inside the completion handler — a fresh show() may have installed
        // its own tap by the time this one's animation finishes.
        let capturedTap = escapeTap
        let capturedRunLoopSource = escapeRunLoopSource
        escapeTap = nil
        escapeRunLoopSource = nil
        // Deliberately NOT clearing suppressEscapeKeyUp here: when this
        // dismiss was itself triggered by an Escape keyDown (via
        // pendingUndo), that keyDown just armed suppressEscapeKeyUp and the
        // matching keyUp hasn't arrived yet. Clearing it synchronously here
        // — before the keyUp is swallowed — was the exact bug: the keyDown
        // gets swallowed (undo runs) but the keyUp then sees
        // suppressEscapeKeyUp already false and leaks through to the
        // frontmost app. Only handleEscapeTapEvent's own keyUp branch (or a
        // later teardownEscapeTap() call, once this tap is actually torn
        // down) may clear it.
        pendingUndo = nil

        let content = panel.contentView

        func playExitAnimation() {
            panel.invalidateShadow()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if let capturedTap {
                    CGEvent.tapEnable(tap: capturedTap, enable: false)
                    CFMachPortInvalidate(capturedTap)
                }
                if let capturedRunLoopSource {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), capturedRunLoopSource, .commonModes)
                }
            })
            // See the matching removeAnimation(forKey:) in show(): the same
            // race can happen in reverse if dismiss() is somehow reached
            // again while an entry animation is still attached.
            content?.layer?.removeAnimation(forKey: "toastScaleIn")
            let scaleOut = CABasicAnimation(keyPath: "transform")
            scaleOut.fromValue = CATransform3DIdentity
            scaleOut.toValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
            scaleOut.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
            scaleOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scaleOut.fillMode = .forwards
            scaleOut.isRemovedOnCompletion = false
            content?.layer?.add(scaleOut, forKey: "toastScaleOut")
            // Match show()'s pattern: the model layer holds the true final
            // value directly, with the CABasicAnimation above only
            // animating the *presentation* toward it — consistent even if
            // this layer were ever kept alive past this call instead of
            // being discarded with the panel right after orderOut(nil).
            content?.layer?.setAffineTransform(CGAffineTransform(scaleX: Self.entryExitScale, y: Self.entryExitScale))
        }

        if confirmed {
            // Accepted: a brief accent-colored border pulse plus a small
            // scale bump, layered on top of (not replacing) the exit
            // animation above. A CALayer *shadow* (shadowOpacity/
            // shadowRadius) was tried first but renders entirely outside
            // the layer's own bounds — panel.setContentSize sizes the
            // panel's content rect to exactly match this container with
            // zero margin, so a shadow radius of any visible size would be
            // clipped away at the window edge and never actually render.
            // borderWidth/borderColor instead draw along the layer's own
            // bounds edge, staying fully within the visible pill, so the
            // pulse reads as a brightened stroke rather than an external
            // glow.
            if let layer = content?.layer, let accentColor {
                // The container's resting stroke is set once in
                // makeContentView and never changed elsewhere, so it's
                // safe to read back here as the "return to" value — unlike
                // the shadow properties this replaces, borderColor/
                // borderWidth already have real resting values on this
                // layer.
                let restingBorderColor = layer.borderColor
                let restingBorderWidth = layer.borderWidth

                let fillPulse = CABasicAnimation(keyPath: "backgroundColor")
                fillPulse.fromValue = accentColor.withAlphaComponent(0.9).cgColor
                fillPulse.toValue = layer.backgroundColor
                fillPulse.duration = Self.confirmGlowSeconds
                fillPulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fillPulse, forKey: "toastConfirmFill")

                let borderColorPulse = CABasicAnimation(keyPath: "borderColor")
                borderColorPulse.fromValue = accentColor.cgColor
                borderColorPulse.toValue = restingBorderColor
                borderColorPulse.duration = Self.confirmGlowSeconds
                borderColorPulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(borderColorPulse, forKey: "toastConfirmBorderColor")

                let borderWidthPulse = CABasicAnimation(keyPath: "borderWidth")
                borderWidthPulse.fromValue = CGFloat(3)
                borderWidthPulse.toValue = restingBorderWidth
                borderWidthPulse.duration = Self.confirmGlowSeconds
                borderWidthPulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(borderWidthPulse, forKey: "toastConfirmBorderWidth")

                // Additive keyframe animation on "transform.scale" so the
                // ~1.0 → 1.03 → 1.0 bump composes on top of scaleOut's own
                // "transform" animation above instead of racing it — the
                // same class of conflict the toastScaleIn/toastScaleOut
                // removeAnimation(forKey:) calls elsewhere in this file
                // guard against, just two animations on the same layer at
                // once here rather than sequential reuse. Left at defaults
                // (.removed / isRemovedOnCompletion = true) so it vanishes
                // on its own once done, leaving scaleOut's own transform
                // animation as the sole surviving one.
                let bump = CAKeyframeAnimation(keyPath: "transform.scale")
                bump.values = ([0, 0.03, 0] as [Double]).map { NSNumber(value: $0) }
                bump.keyTimes = ([0, 0.5, 1] as [Double]).map { NSNumber(value: $0) }
                bump.duration = Self.confirmGlowSeconds
                bump.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bump.isAdditive = true
                layer.add(bump, forKey: "toastConfirmScaleBump")
            }
            // Hold briefly so the glow pulse actually reads before the
            // fade-out starts covering it — mirrors the reject path's own
            // hold-before-fade structure just below, with a shorter delay.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.confirmGlowHoldSeconds * 1_000_000_000))
                playExitAnimation()
            }
        } else {
            // Rejected: strike through the whole label, dim both words, and
            // recolor the arrow away from accentColor to a neutral gray —
            // then hold briefly so the restyle actually reads before the
            // normal fade+shrink-out plays.
            if let label,
               let textColor,
               let attributed = label.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
                let fullRange = NSRange(location: 0, length: attributed.length)
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
                // Direct, unconditional writes rather than enumerating
                // existing .foregroundColor runs and conditionally
                // patching them: enumerate-and-patch degenerates if
                // accentColor ever equals textColor (all three text
                // segments would already share one run, and "the run that
                // intersects arrowRange" would then be the *entire* label
                // — recoloring it gray instead of just the arrow). Dim the
                // whole label first to the captured resting textColor
                // (makeContentView's textColor, not whatever run happens to
                // be captured), then unconditionally overwrite exactly
                // arrowRange to gray — this can't degenerate regardless of
                // what accentColor/textColor resolve to.
                attributed.addAttribute(.foregroundColor, value: textColor.withAlphaComponent(textColor.alphaComponent * 0.4), range: fullRange)
                if let arrowRange {
                    // A fixed gray, not NSColor.systemGray: this file's
                    // convention (see textColor above) is to avoid
                    // system-appearance-dynamic colors, since the toast's
                    // light/dark background is forced independently of
                    // system appearance and a dynamic color can mismatch
                    // it. Dimmed by the same ~0.4 factor as fullRange above
                    // so the arrow reads as muted along with the rest of
                    // the label, instead of standing out at full alpha in a
                    // state whose entire point is "this looks rejected."
                    let dimmedArrowGray = NSColor(calibratedWhite: 0.5, alpha: textColor.alphaComponent * 0.4)
                    attributed.addAttribute(.foregroundColor, value: dimmedArrowGray, range: arrowRange)
                }
                label.attributedStringValue = attributed
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.rejectRestyleHoldSeconds * 1_000_000_000))
                playExitAnimation()
            }
        }
    }

    // Pill geometry, chosen to read as an obviously-rounded capsule (like
    // RecordingHUDView's pill) rather than a barely-rounded rectangle.
    private static let pillHeight: CGFloat = 60
    private static let horizontalPadding: CGFloat = 26
    private static let minPillWidth: CGFloat = 180
    private static let maxPillWidth: CGFloat = 540

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        return panel
    }

    /// Mirrors RecordingHUDView.backgroundPalette(alpha:) (HUDViews.swift)
    /// so the toast's fill/stroke match the recording HUD's solid,
    /// mostly-opaque capsule background rather than a translucent blur
    /// material (NSVisualEffectView's ".hudWindow" material read as flat
    /// gray, which is what this redesign moves away from).
    private static func backgroundPalette(lightBackground: Bool) -> (fill: NSColor, stroke: NSColor) {
        if lightBackground {
            return (
                NSColor(calibratedWhite: 1.0, alpha: 0.84),
                NSColor(calibratedWhite: 0.0, alpha: 0.14)
            )
        }
        return (
            NSColor(calibratedWhite: 0.0, alpha: 0.96),
            NSColor(calibratedWhite: 0.22, alpha: 0.26)
        )
    }

    /// makeContentView's return value: the assembled pill view, plus a
    /// strong reference to its label and the arrow segment's NSRange
    /// within the label's attributed string — captured by the controller
    /// (which itself only keeps a *weak* reference to the label, see
    /// `label` above) so dismiss(confirmed:) can restyle the label in
    /// place (Task 2) without walking the view hierarchy to find it.
    private struct ContentViewResult {
        let view: NSView
        let label: NSTextField
        let arrowRange: NSRange
        let textColor: NSColor
    }

    private static func makeContentView(record: VocabularyRecord,
                                        lightBackground: Bool,
                                        accentColor: NSColor,
                                        onUndo: @escaping () -> Void) -> ContentViewResult {
        // Mirrors RecordingHUDView.drawTimerOutlineFill's textColor formula
        // (HUDViews.swift) — NSColor.labelColor resolves against the
        // *system* appearance, which can mismatch this container's forced
        // light/dark background (e.g. a forced-light toast on a Dark-mode
        // Mac would render unreadable white-on-white text).
        let textColor: NSColor = lightBackground
            ? NSColor(calibratedWhite: 0.0, alpha: 0.85)
            : NSColor(calibratedWhite: 1.0, alpha: 0.92)
        let font = NSFont.systemFont(ofSize: 17, weight: .bold)

        let text = NSMutableAttributedString(string: record.source, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        // Take the arrow's range off the attributed string's own UTF-16
        // length (NSRange's unit) rather than record.source.count (Swift's
        // grapheme-cluster count) — the two can disagree for combining
        // characters/emoji, and an out-of-bounds NSRange later would trap.
        let arrowStart = text.length
        text.append(NSAttributedString(string: "  →  ", attributes: [
            .font: font,
            .foregroundColor: accentColor,
        ]))
        let arrowRange = NSRange(location: arrowStart, length: text.length - arrowStart)
        text.append(NSAttributedString(string: record.replacement, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ]))

        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        // Content-sized pill: measure the text and clamp it into
        // [minPillWidth, maxPillWidth], with generous horizontal padding.
        let measuredWidth = text.size().width + (horizontalPadding * 2)
        let pillWidth = min(max(measuredWidth, minPillWidth), maxPillWidth)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        container.wantsLayer = true
        let palette = backgroundPalette(lightBackground: lightBackground)
        container.layer?.backgroundColor = palette.fill.cgColor
        container.layer?.cornerRadius = pillHeight / 2
        container.layer?.borderWidth = 1
        container.layer?.borderColor = palette.stroke.cgColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -horizontalPadding),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        // Undo/cancel affordance: clicking anywhere on the toast, or
        // pressing Escape, cancels the just-learned save — same mechanism
        // as before (UndoButtonAction + keyEquivalent), but with all
        // visible button chrome stripped so nothing reads as a button. The
        // user explicitly doesn't want any "press Escape to cancel" text
        // shown; they already know the shortcut.
        let undoButton = NSButton(title: "", target: nil, action: nil)
        undoButton.isBordered = false
        // isTransparent guarantees the cell draws nothing at all (an empty
        // bordered/borderless title can still leave faint cell artifacts on
        // some bezel styles) while still tracking mouse-down and honoring
        // keyEquivalent, so clicking anywhere on the toast — or pressing
        // Escape — still fires onUndo with zero visible button chrome.
        undoButton.isTransparent = true
        // ...but isTransparent does NOT suppress the AppKit focus ring:
        // clicking the pill makes this nonactivating panel the key window
        // and the full-size button its first responder, so a dotted focus
        // outline would appear around the toast and linger through the
        // dismiss animations. Kill it at the source: no focus ring, and
        // never become first responder in the first place (keyEquivalent
        // matching works via performKeyEquivalent regardless of first
        // responder status, so the Escape fallback is unaffected).
        undoButton.focusRingType = .none
        undoButton.refusesFirstResponder = true
        undoButton.keyEquivalent = "\u{1b}"
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        let action = UndoButtonAction(handler: onUndo)
        undoButton.target = action
        undoButton.action = #selector(UndoButtonAction.undoTapped)
        objc_setAssociatedObject(undoButton, &UndoButtonAction.associationKey, action, .OBJC_ASSOCIATION_RETAIN)

        container.addSubview(undoButton)
        NSLayoutConstraint.activate([
            undoButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            undoButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            undoButton.topAnchor.constraint(equalTo: container.topAnchor),
            undoButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return ContentViewResult(view: container, label: label, arrowRange: arrowRange, textColor: textColor)
    }

    private static func positionBottomRight(_ panel: NSPanel) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - 24,
            y: screenFrame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }

    /// Positions the panel just above `targetFrame` (the field the
    /// correction was just made in), falling back to below it if there
    /// isn't room above, clamped to the target's screen's visible frame.
    /// Mirrors ParakeyApp's `recordingHUDFrameAboveTarget` positioning
    /// logic for the recording indicator HUD.
    private static func positionAboveTarget(_ panel: NSPanel, targetFrame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let size = panel.frame.size
        let preferredX = targetFrame.minX
        let preferredY = targetFrame.maxY + gap
        let fallbackY = targetFrame.minY - gap - size.height
        let y = preferredY + size.height <= visible.maxY - 8 ? preferredY : fallbackY
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let clampedY = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    private static func screenFor(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Mirrors RecordingHUDView.shouldUseLightBackground() (HUDViews.swift)
    /// so the toast follows the same user-configured background style as
    /// the recording indicator HUD.
    private static func shouldUseLightBackground() -> Bool {
        switch Settings.shared.recordingHUDBackgroundStyle {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return appearance == .aqua
        }
    }
}

/// NSButton's target must be an NSObject; this wraps a Swift closure so
/// the toast controller doesn't need to become one itself.
private final class UndoButtonAction: NSObject {
    nonisolated(unsafe) static var associationKey: UInt8 = 0
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
    @objc func undoTapped() { handler() }
}
