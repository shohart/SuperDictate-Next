// SuperDictate — small auto-dismissing HUD toast shown right after
// PostInsertionEditWatcher learns a new correction, with an "Undo" button
// that deletes the just-learned row within a short window.

import AppKit

@MainActor
final class VocabularyLearnedToastController {
    private static let autoDismissSeconds: TimeInterval = 7
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ record: VocabularyRecord, store: VocabularyStore, targetFrame: NSRect? = nil) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel()
        let lightBackground = Self.shouldUseLightBackground()
        let accentColor = Settings.shared.recordingHUDRecordingColor.resolvedColor(lightBackground: lightBackground)
        let content = Self.makeContentView(
            record: record,
            lightBackground: lightBackground,
            accentColor: accentColor,
            onUndo: { [weak self] in
                store.delete(id: record.id)
                self?.dismiss()
            }
        )
        // Resize the panel to the content's already-computed size *before*
        // assigning it as contentView — setting `panel.contentView` resets
        // the view's frame to fill the panel's *existing* content rect, so
        // resizing after assignment would silently discard the measured
        // width (every toast would render at minPillWidth instead of fitting
        // its text). Positioning below reads panel.frame.size, so this must
        // happen first.
        panel.setContentSize(content.frame.size)
        panel.contentView = content
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
        if let layer = content.layer {
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
        content.layer?.setAffineTransform(CGAffineTransform(scaleX: Self.entryExitScale, y: Self.entryExitScale))
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        let scaleIn = CABasicAnimation(keyPath: "transform")
        scaleIn.fromValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
        scaleIn.toValue = CATransform3DIdentity
        scaleIn.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
        scaleIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scaleIn.fillMode = .forwards
        scaleIn.isRemovedOnCompletion = false
        content.layer?.add(scaleIn, forKey: "toastScaleIn")
        content.layer?.setAffineTransform(.identity)

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Scale the toast animates from (on appear) / to (on dismiss). Applied
    /// to the content view's layer, which has its anchorPoint recentered in
    /// `show(_:store:targetFrame:)` so scaling grows from/shrinks toward
    /// the pill's own center rather than a corner.
    private static let entryExitScale: CGFloat = 0.85

    private func dismiss() {
        // Guard against double-invocation (e.g. the 7s auto-timer firing
        // just as the user clicks/Escapes the toast): once the completion
        // handler below runs, `panel` is nil'd out, so a second call here
        // is a no-op instead of animating/ordering-out an already-gone panel.
        guard let panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        self.panel = nil

        let content = panel.contentView
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        let scaleOut = CABasicAnimation(keyPath: "transform")
        scaleOut.fromValue = CATransform3DIdentity
        scaleOut.toValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
        scaleOut.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
        scaleOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scaleOut.fillMode = .forwards
        scaleOut.isRemovedOnCompletion = false
        content?.layer?.add(scaleOut, forKey: "toastScaleOut")
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

    private static func makeContentView(record: VocabularyRecord,
                                        lightBackground: Bool,
                                        accentColor: NSColor,
                                        onUndo: @escaping () -> Void) -> NSView {
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
        text.append(NSAttributedString(string: "  →  ", attributes: [
            .font: font,
            .foregroundColor: accentColor,
        ]))
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

        return container
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
