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
        panel.contentView = content
        if let targetFrame, let screen = Self.screenFor(point: NSPoint(x: targetFrame.midX, y: targetFrame.midY)) {
            Self.positionAboveTarget(panel, targetFrame: targetFrame, screen: screen)
        } else {
            Self.positionBottomRight(panel)
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
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

    private static func makeContentView(record: VocabularyRecord,
                                        lightBackground: Bool,
                                        accentColor: NSColor,
                                        onUndo: @escaping () -> Void) -> NSView {
        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 64))
        container.material = .hudWindow
        // Mirrors RecordingHUDView.shouldUseLightBackground()'s light/dark
        // decision (HUDViews.swift) so the toast reads as part of the same
        // visual family as the recording indicator HUD, rather than always
        // rendering with a fixed appearance regardless of user settings.
        container.appearance = NSAppearance(named: lightBackground ? .aqua : .darkAqua)
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = accentColor.withAlphaComponent(0.6).cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Small accent dot ties the toast's color to the recording HUD's
        // configured accent color, without reimplementing the HUD's
        // custom Core Graphics capsule drawing.
        let accentDot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        accentDot.wantsLayer = true
        accentDot.layer?.backgroundColor = accentColor.cgColor
        accentDot.layer?.cornerRadius = 4
        accentDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            accentDot.widthAnchor.constraint(equalToConstant: 8),
            accentDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let label = NSTextField(labelWithString: "Запомнил: «\(record.source)» → «\(record.replacement)»")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        // NSColor.labelColor resolves against the *system* appearance,
        // which can mismatch this container's forced light/dark appearance
        // (e.g. a forced-light toast on a Dark-mode Mac would render
        // unreadable white-on-white text) — same reasoning as
        // RecordingHUDView's textColor. Use an explicit color instead.
        label.textColor = lightBackground
            ? NSColor(calibratedWhite: 0.0, alpha: 0.85)
            : NSColor(calibratedWhite: 1.0, alpha: 0.92)

        let undoButton = NSButton(title: "Отменить", target: nil, action: nil)
        undoButton.bezelStyle = .rounded
        undoButton.contentTintColor = accentColor
        // Escape triggers the same action as clicking "Отменить" — the
        // user explicitly wants pressing Escape while the toast is showing
        // to cancel the just-learned save, overriding an earlier review
        // pass that removed this binding on "Escape means harmless
        // dismiss" grounds.
        undoButton.keyEquivalent = "\u{1b}"
        let action = UndoButtonAction(handler: onUndo)
        undoButton.target = action
        undoButton.action = #selector(UndoButtonAction.undoTapped)
        objc_setAssociatedObject(undoButton, &UndoButtonAction.associationKey, action, .OBJC_ASSOCIATION_RETAIN)

        stack.addArrangedSubview(accentDot)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(undoButton)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
