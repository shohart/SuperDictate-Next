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
                // tapDisabledByTimeout/tapDisabledByUserInput (and anything
                // else outside our mask) carry no keycode worth reading —
                // pass them through untouched.
                guard type == .keyDown || type == .keyUp,
                      CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == ESCAPE_KEYCODE
                else {
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<VocabularyLearnedToastController>.fromOpaque(userInfo).takeUnretainedValue()
                let suppress = MainActor.assumeIsolated {
                    controller.handleEscapeTapEvent(isKeyDown: type == .keyDown)
                }
                return suppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            // No Input Monitoring permission (or tap creation otherwise
            // failed) — fall back silently to the local NSButton
            // keyEquivalent, which still works whenever the panel is key.
            log("VocabularyLearnedToastController: escape tap create failed — falling back to local keyEquivalent")
            return
        }

        escapeTap = tap
        escapeRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), escapeRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns whether the event should be swallowed (return nil from the
    /// tap callback). Mirrors HotkeyTransitionState.transitionEscape's
    /// suppressEscapeKeyUp handling in Hotkeys.swift: the keyDown that
    /// triggers undo also arms a flag so the matching keyUp is swallowed
    /// too, rather than leaking through to the frontmost app.
    private func handleEscapeTapEvent(isKeyDown: Bool) -> Bool {
        if isKeyDown {
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
    /// Duration of the "accepted" glow/scale-bump pulse, timed to overlap
    /// just the start of the exit animation rather than delay it — this
    /// path is non-interactive, so it shouldn't make the user wait.
    private static let confirmGlowSeconds: TimeInterval = 0.2

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
        self.label = nil
        self.arrowRange = nil
        self.accentColor = nil
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
        suppressEscapeKeyUp = false
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
            // Accepted: a brief accent-colored shadow glow plus a small
            // scale bump, layered on top of (not replacing) the exit
            // animation above. The glow is a CALayer property, so it's
            // applied to the content view's layer rather than the panel;
            // panel.setContentSize sizes the panel exactly to the content,
            // so a shadow radius that would extend past the content's
            // bounds gets clipped at the window edge.
            if let layer = content?.layer, let accentColor {
                layer.shadowColor = accentColor.cgColor
                // shadowOpacity/shadowRadius default to 0/3 and have never
                // been set on this layer before, so — unlike scaleIn/
                // scaleOut's transform, which always has a real "current"
                // model value to animate from — there's no meaningful
                // resting state to read back. Pick the resting values
                // explicitly and write them to the model layer *before*
                // adding the animations (mirrors scaleOut's
                // setAffineTransform call below: the model layer holds the
                // true final value, the CABasicAnimation only animates the
                // presentation toward it), otherwise the animation would
                // remove itself and reveal an implicit opacity-0 layer that
                // never glowed at all.
                let restingShadowOpacity: Float = 0
                let restingShadowRadius: CGFloat = 6
                layer.shadowOpacity = restingShadowOpacity
                layer.shadowRadius = restingShadowRadius

                let glowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
                glowOpacity.fromValue = Float(0.9)
                glowOpacity.toValue = restingShadowOpacity
                glowOpacity.duration = Self.confirmGlowSeconds
                glowOpacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(glowOpacity, forKey: "toastConfirmGlowOpacity")

                let glowRadius = CABasicAnimation(keyPath: "shadowRadius")
                glowRadius.fromValue = CGFloat(16)
                glowRadius.toValue = restingShadowRadius
                glowRadius.duration = Self.confirmGlowSeconds
                glowRadius.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(glowRadius, forKey: "toastConfirmGlowRadius")

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
            playExitAnimation()
        } else {
            // Rejected: strike through the whole label, dim both words, and
            // recolor the arrow away from accentColor to a neutral gray —
            // then hold briefly so the restyle actually reads before the
            // normal fade+shrink-out plays.
            if let label,
               let attributed = label.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
                let fullRange = NSRange(location: 0, length: attributed.length)
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
                attributed.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
                    guard let color = value as? NSColor else { return }
                    if let arrowRange, NSIntersectionRange(range, arrowRange).length > 0 {
                        attributed.addAttribute(.foregroundColor, value: NSColor.systemGray, range: range)
                    } else {
                        attributed.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * 0.4), range: range)
                    }
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

    /// makeContentView's return value: the assembled pill view, plus a weak
    /// reference to its label and the arrow segment's NSRange within the
    /// label's attributed string — captured by the controller so
    /// dismiss(confirmed:) can restyle the label in place (Task 2) without
    /// walking the view hierarchy to find it.
    private struct ContentViewResult {
        let view: NSView
        let label: NSTextField
        let arrowRange: NSRange
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

        return ContentViewResult(view: container, label: label, arrowRange: arrowRange)
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
