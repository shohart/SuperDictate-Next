// Parakey — push-to-talk dictation for macOS.
//
// Swift menu-bar app. The runtime covers hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (vendored `parakeet.cpp`, CPU by
// default with an opt-in Vulkan GPU backend planned — see the "Use GPU" setting),
// paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, and permission guidance.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.
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
// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `ParakeyApp` for anything that touches the menu.
enum DictationReleaseShortcut: Equatable {
    case standard
    case alternate
}
func shouldPressEnterAfterDictation(
    shortcut: DictationReleaseShortcut,
    primaryBehavior: DictationCompletionBehavior
) -> Bool {
    let behavior = shortcut == .standard ? primaryBehavior : primaryBehavior.opposite
    return behavior.pressesEnter
}
@MainActor
final class CorrectionShareCleanupDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let cleanup: (String) -> Void
    init(cleanup: @escaping (String) -> Void) {
        self.cleanup = cleanup
    }
    private func runCleanup(reason: String) {
        cleanup(reason)
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil {
            runCleanup(reason: "dismissed")
        }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        runCleanup(reason: "shared")
    }
    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        runCleanup(reason: "share failed")
    }
}
/// Builds the portion of a capsule's rounded-rect outline that should be lit,
/// growing from the bottom center point symmetrically up both the left and
/// right sides as `fraction` (0...1) increases, tracing the same rounded-rect
/// path geometry as the full capsule outline (bottom-half straight run, then
/// the end-cap arc, then the top-half straight run back to top-center).
///
/// Pure geometry, no view/window/context dependency, so it can be exercised
/// directly by self-tests.
func recordingHUDOutlineFillPath(in capsuleRect: NSRect, fraction: CGFloat) -> NSBezierPath {
    let clamped = max(0, min(1, fraction))
    let fullPath = NSBezierPath(roundedRect: capsuleRect,
                                xRadius: capsuleRect.height / 2,
                                yRadius: capsuleRect.height / 2)
    guard clamped < 1 else { return fullPath }
    let radius = capsuleRect.height / 2
    let bottomCenter = NSPoint(x: capsuleRect.midX, y: capsuleRect.maxY)
    let topCenter = NSPoint(x: capsuleRect.midX, y: capsuleRect.minY)
    let straightLength = max(0, capsuleRect.width - capsuleRect.height)
    let halfStraight = straightLength / 2
    let arcLength = CGFloat.pi * radius
    // Full traversal from bottom-center up one side to top-center covers the
    // bottom-half straight run, the full end-cap arc, and the top-half
    // straight run: halfStraight + arcLength + halfStraight == straightLength + arcLength.
    let halfPerimeter = straightLength + arcLength
    let litLength = clamped * halfPerimeter
    let path = NSBezierPath()
    path.lineJoinStyle = .round
    func appendSide(direction: CGFloat) {
        // direction: -1 for left side, +1 for right side.
        var remaining = litLength
        path.move(to: bottomCenter)
        // Segment 1: bottom-half straight run.
        let seg1 = min(remaining, halfStraight)
        let straightEnd = NSPoint(x: bottomCenter.x + (direction * seg1), y: bottomCenter.y)
        path.line(to: straightEnd)
        remaining -= seg1
        guard remaining > 0 else { return }
        // Segment 2: the end-cap arc, starting at the visual bottom of the
        // cap (matching where segment 1 left off) and sweeping toward the
        // visual top of the cap.
        let arcTraversed = min(remaining, arcLength)
        let arcFraction = arcTraversed / arcLength
        let center = NSPoint(x: capsuleRect.midX + (direction * halfStraight), y: capsuleRect.midY)
        let startAngle: CGFloat = 90
        let sweep = direction > 0 ? -180 * arcFraction : 180 * arcFraction
        path.appendArc(withCenter: center,
                       radius: radius,
                       startAngle: startAngle,
                       endAngle: startAngle + sweep,
                       clockwise: direction > 0)
        remaining -= arcTraversed
        guard remaining > 0 else { return }
        // Segment 3: top-half straight run, from the arc's end point inward
        // toward top-center.
        let seg3 = min(remaining, halfStraight)
        let arcEnd = NSPoint(x: capsuleRect.midX + (direction * halfStraight), y: topCenter.y)
        let topEnd = NSPoint(x: arcEnd.x - (direction * seg3), y: topCenter.y)
        path.line(to: topEnd)
    }
    appendSide(direction: -1)
    appendSide(direction: 1)
    return path
}
final class RecordingHUDView: NSView {
    var visualScale: CGFloat = RecordingHUDSize.standard.visualScale {
        didSet {
            if oldValue != visualScale { needsDisplay = true }
        }
    }
    var recordingColor: NSColor = .systemRed {
        didSet {
            if !oldValue.isEqual(recordingColor) { needsDisplay = true }
        }
    }
    var transcribingColor: NSColor = NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1) {
        didSet {
            if !oldValue.isEqual(transcribingColor) { needsDisplay = true }
        }
    }
    var backgroundStyle: RecordingHUDBackgroundStyle = .system {
        didSet {
            if oldValue != backgroundStyle { needsDisplay = true }
        }
    }
    var showsCapsuleStroke = true {
        didSet {
            if oldValue != showsCapsuleStroke { needsDisplay = true }
        }
    }
    var transcribingElapsedOverride: CGFloat? {
        didSet { needsDisplay = true }
    }
    var revealProgress: CGFloat = 1 {
        didSet {
            if oldValue != revealProgress { needsDisplay = true }
        }
    }
    var mode: RecordingHUDMode = .recording {
        didSet {
            if oldValue != mode {
                modeChangedAt = ProcessInfo.processInfo.systemUptime
                needsDisplay = true
            }
        }
    }
    private var modeChangedAt = ProcessInfo.processInfo.systemUptime
    var level: Float = 0 {
        didSet {
            if oldValue != level { needsDisplay = true }
        }
    }
    var recordingStartedAt: Date? {
        didSet { if oldValue != recordingStartedAt { needsDisplay = true } }
    }
    var displayMode: RecordingHUDDisplayMode = .levelBars {
        didSet {
            if oldValue != displayMode { needsDisplay = true }
        }
    }
    var phase: CGFloat = 0 {
        didSet {
            if oldValue != phase { needsDisplay = true }
        }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFloatingWaveformOnly()
    }
    private func drawFloatingWaveformOnly() {
        let reveal = max(0, min(1, revealProgress))
        guard reveal > 0.001 else { return }
        let clamped = CGFloat(max(0, min(1, level)))
        let audio = pow(clamped, 0.82)
        let settlePeak: CGFloat = 0.68
        let settleOvershoot: CGFloat = 0.10
        let grow: CGFloat
        if reveal <= settlePeak {
            grow = (1 + settleOvershoot) * smootherstep(0, settlePeak, reveal)
        } else {
            grow = (1 + settleOvershoot)
                - (settleOvershoot * smootherstep(settlePeak, 1, reveal))
        }
        let capsuleAlpha = smootherstep(0, 0.34, reveal)
        let contentAlpha = smootherstep(0.16, 0.78, reveal)
        let visualScale = self.visualScale
        let startDiameter: CGFloat = 6 * visualScale
        let finalRect = bounds.insetBy(dx: 4 * visualScale, dy: 4 * visualScale)
        let breathingReady = smootherstep(0.82, 1, reveal)
        let idleBreath = 0.0032 + (0.0018 * sin(phase * 0.31))
        let voiceBreath = audio * (0.014 + (0.008 * ((sin(phase * 0.87) + 1) / 2)))
        let liveScale = 1 + ((idleBreath + voiceBreath) * breathingReady)
        let capsuleWidth = (startDiameter + ((finalRect.width - startDiameter) * grow)) * liveScale
        let capsuleHeight = (startDiameter + ((finalRect.height - startDiameter) * grow)) * liveScale
        let capsuleRect = NSRect(x: bounds.midX - (capsuleWidth / 2),
                                 y: bounds.midY - (capsuleHeight / 2),
                                 width: capsuleWidth,
                                 height: capsuleHeight)
        let capsule = NSBezierPath(roundedRect: capsuleRect,
                                   xRadius: capsuleRect.height / 2,
                                   yRadius: capsuleRect.height / 2)
        let palette = backgroundPalette(alpha: capsuleAlpha)
        palette.fill.setFill()
        capsule.fill()
        let accent: NSColor
        switch mode {
        case .transcribing: accent = transcribingColor
        case .error:        accent = .systemYellow
        case .recording:    accent = recordingColor
        }
        let vividAccent = accent
        if showsCapsuleStroke {
            palette.stroke.setStroke()
            capsule.lineWidth = 1 * visualScale
            capsule.stroke()
        }
        guard contentAlpha > 0.001 else { return }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        capsule.addClip()
        context.setAlpha(contentAlpha)
        defer { NSGraphicsContext.restoreGraphicsState() }
        if mode == .transcribing {
            drawTranscribingWave(in: capsuleRect, alpha: 1)
            return
        }
        if mode == .error {
            drawErrorIndicator(in: capsuleRect)
            return
        }
        let elapsedForMode: TimeInterval = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let timerActivationSeconds: TimeInterval = 10
        let transitionDuration: TimeInterval = 0.5
        let timerModeTransition: CGFloat
        if displayMode == .timerOutline {
            let progress = (elapsedForMode - timerActivationSeconds) / transitionDuration
            timerModeTransition = smootherstep(0, 1, CGFloat(max(0, min(1, progress))))
        } else {
            timerModeTransition = 0
        }
        if timerModeTransition < 1 {
            NSGraphicsContext.saveGraphicsState()
            // `setAlpha` REPLACES the graphics-state alpha rather than
            // composing with it, so it must be multiplied by `contentAlpha`
            // here or the reveal fade-in gets discarded (a hard-1.0 pop) in
            // the default .levelBars mode, where timerModeTransition is 0.
            context.setAlpha(contentAlpha * (1 - timerModeTransition))
            drawRecordingLevelBars(audio: audio, vividAccent: vividAccent, visualScale: visualScale, capsuleRect: capsuleRect)
            NSGraphicsContext.restoreGraphicsState()
        }
        if timerModeTransition > 0 {
            NSGraphicsContext.saveGraphicsState()
            context.setAlpha(contentAlpha * timerModeTransition)
            drawTimerOutlineFill(in: capsuleRect, accent: vividAccent, level: CGFloat(max(0, min(1, level))), elapsed: elapsedForMode)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func drawRecordingLevelBars(audio: CGFloat, vividAccent: NSColor, visualScale: CGFloat, capsuleRect: NSRect) {
        let barCount = 8
        let barWidth: CGFloat = 2.05 * visualScale
        let barGap: CGFloat = 2.55 * visualScale
        let minHeight: CGFloat = 3.0 * visualScale
        let maxHeight = min(capsuleRect.height * 0.58, 13.2 * visualScale)
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = bounds.midX - (totalWidth / 2)
        let centerY = bounds.midY
        let centerIndex = CGFloat(barCount - 1) / 2
        let centerDenominator = max(centerIndex, 1)
        for index in 0..<barCount {
            let i = CGFloat(index)
            let normalized = (i - centerIndex) / centerDenominator
            let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
            let traveling = (sin((phase * 1.02) - (normalized * 2.85)) + 1) / 2
            let counter = (sin((phase * 1.57) + (i * 1.17)) + 1) / 2
            let slowVariance = (sin((phase * 0.23) + (i * 2.11)) + 1) / 2
            let perBarGain = 0.72 + (0.28 * slowVariance)
            let idleMotion = 0.14 + (0.075 * traveling) + (0.055 * counter * envelope)
            let centerBias = 0.22 + (0.78 * envelope)
            let voiceMotion = audio
                * centerBias
                * (0.18 + (0.42 * traveling) + (0.14 * counter))
                * perBarGain
            let activity = min(0.88, idleMotion + voiceMotion)
            let height = minHeight + ((maxHeight - minHeight) * activity)
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let rect = NSRect(x: x,
                              y: centerY - (height / 2),
                              width: barWidth,
                              height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            let glowRect = rect.insetBy(dx: -1.1 * visualScale,
                                        dy: -1.1 * visualScale)
            vividAccent.withAlphaComponent(0.07 + (0.10 * activity)).setFill()
            NSBezierPath(roundedRect: glowRect,
                         xRadius: glowRect.width / 2,
                         yRadius: glowRect.width / 2).fill()
            vividAccent.withAlphaComponent(0.74 + (0.26 * activity)).setFill()
            path.fill()
        }
    }
    private func drawTimerOutlineFill(in capsuleRect: NSRect, accent: NSColor, level: CGFloat, elapsed: TimeInterval) {
        // Outline stroke, filled fraction of the perimeter grows from the
        // bottom center point symmetrically up both sides with `level`.
        //
        // The outer clip region (see `capsule.addClip()` in
        // `drawFloatingWaveformOnly`) is the un-inset capsule, so a stroke
        // centered on that same path would have half its width — and the
        // glow's outward half — clipped away. Inset by half of the widest
        // stroke used here (the fully-widened glow, worst case at level==1)
        // so the whole glow stays inside the clip region.
        let strokeWidth: CGFloat = 2.4 * visualScale
        let maxGlowWidth = strokeWidth + (3.0 * visualScale)
        let halfMaxStrokeWidth = maxGlowWidth / 2
        let outlineRect = capsuleRect.insetBy(dx: halfMaxStrokeWidth, dy: halfMaxStrokeWidth)
        let capsule = NSBezierPath(roundedRect: outlineRect,
                                   xRadius: outlineRect.height / 2,
                                   yRadius: outlineRect.height / 2)
        let unfilledColor = accent.withAlphaComponent(0.14)
        unfilledColor.setStroke()
        capsule.lineWidth = strokeWidth
        capsule.stroke()
        if level > 0.001 {
            let filledPath = recordingHUDOutlineFillPath(in: outlineRect, fraction: level)
            let glowAlpha = 0.18 + (0.55 * level)
            let glowWidth = strokeWidth + (3.0 * visualScale * level)
            accent.withAlphaComponent(glowAlpha).setStroke()
            filledPath.lineWidth = glowWidth
            filledPath.lineCapStyle = .round
            filledPath.stroke()
            accent.withAlphaComponent(0.85 + (0.15 * level)).setStroke()
            filledPath.lineWidth = strokeWidth
            filledPath.lineCapStyle = .round
            filledPath.stroke()
        }
        let text = formatRecordingHUDElapsed(elapsed)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12 * visualScale, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // Explicit light/dark-bubble-derived color, matching the same
        // `shouldUseLightBackground()` idiom `backgroundPalette` uses below —
        // `NSColor.labelColor` resolves against system appearance, which can
        // mismatch the bubble's actual background (e.g. a forced-light bubble
        // on a Dark-mode Mac would render unreadable white-on-white text).
        let textColor: NSColor = shouldUseLightBackground()
            ? NSColor(calibratedWhite: 0.0, alpha: 0.85)
            : NSColor(calibratedWhite: 1.0, alpha: 0.92)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textRect = NSRect(x: capsuleRect.midX - (textSize.width / 2),
                              y: capsuleRect.midY - (textSize.height / 2),
                              width: textSize.width,
                              height: textSize.height)
        attributed.draw(in: textRect)
    }
    private func drawTranscribingWave(in capsuleRect: NSRect, alpha: CGFloat) {
        guard alpha > 0.001 else { return }
        let recordingAccent = recordingColor
        let transcribingAccent = transcribingColor
        let barCount = 8
        let visualScale = self.visualScale
        let barWidth: CGFloat = 2.05 * visualScale
        let barGap: CGFloat = 2.55 * visualScale
        let minHeight: CGFloat = 3.2 * visualScale
        let maxHeight = min(capsuleRect.height * 0.60, 14.6 * visualScale)
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = capsuleRect.midX - (totalWidth / 2)
        let centerY = capsuleRect.midY
        let centerIndex = CGFloat(barCount - 1) / 2
        let centerDenominator = max(centerIndex, 1)
        let age = transcribingElapsedOverride
            ?? CGFloat(max(0, ProcessInfo.processInfo.systemUptime - modeChangedAt))
        let resolveDuration = CGFloat(RECORDING_HUD_TRANSCRIBING_RESOLVE_SECONDS)
        let resolveProgress = min(1, age / resolveDuration)
        let loopPhase = max(0, age - resolveDuration)
        for index in 0..<barCount {
            let i = CGFloat(index)
            let normalized = (i - centerIndex) / centerDenominator
            let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
            let barProgress = CGFloat(index) / CGFloat(max(1, barCount - 1))
            let conversion = smoothstep(barProgress - 0.34, barProgress + 0.08, resolveProgress)
            let front = max(0, 1 - abs(resolveProgress - barProgress) / 0.18) * (1 - smoothstep(0.82, 1, resolveProgress))
            let reverseHead = 1 - (loopPhase * 3.8).truncatingRemainder(dividingBy: 1)
            let reversePulse = max(0, 1 - abs(reverseHead - barProgress) / 0.24)
            let loopWave = (sin((loopPhase * 6.2) + (i * 0.56)) + 1) / 2
            let loopCounter = (sin((loopPhase * 2.8) + (i * 1.27)) + 1) / 2
            let resolveLift = front * (0.48 + (0.30 * envelope))
            let blueLoop = conversion * ((0.14 * loopWave) + (0.08 * loopCounter * envelope) + (0.34 * reversePulse))
            let redHold = (1 - conversion) * (0.16 + (0.12 * envelope))
            let activity = min(0.94,
                               0.15
                               + (0.24 * envelope)
                               + redHold
                               + blueLoop
                               + resolveLift)
            let height = minHeight + ((maxHeight - minHeight) * activity)
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let rect = NSRect(x: x,
                              y: centerY - (height / 2),
                              width: barWidth,
                              height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            let glowRect = rect.insetBy(dx: -1.35 * visualScale,
                                        dy: -1.45 * visualScale)
            let fillColor = recordingAccent.blended(withFraction: conversion, of: transcribingAccent) ?? transcribingAccent
            let glowAlpha = (0.055 + (0.12 * front) + (0.10 * reversePulse) + (0.045 * conversion)) * alpha
            fillColor.withAlphaComponent(glowAlpha).setFill()
            NSBezierPath(roundedRect: glowRect,
                         xRadius: glowRect.width / 2,
                         yRadius: glowRect.width / 2).fill()
            fillColor.withAlphaComponent((0.58 + (0.26 * front) + (0.20 * reversePulse) + (0.14 * conversion)) * alpha).setFill()
            path.fill()
        }
    }
    /// Static exclamation mark drawn inside the yellow error capsule.
    private func drawErrorIndicator(in capsuleRect: NSRect) {
        let visualScale = self.visualScale
        let accent = NSColor.systemYellow
        let stemWidth: CGFloat = 2.4 * visualScale
        let stemHeight: CGFloat = min(capsuleRect.height * 0.38, 9 * visualScale)
        let dotDiameter: CGFloat = 2.4 * visualScale
        let gap: CGFloat = 2.0 * visualScale
        let totalHeight = stemHeight + gap + dotDiameter
        let topY = capsuleRect.midY + (totalHeight / 2)
        let stemRect = NSRect(x: capsuleRect.midX - (stemWidth / 2),
                              y: topY - stemHeight,
                              width: stemWidth,
                              height: stemHeight)
        accent.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: stemRect,
                     xRadius: stemWidth / 2,
                     yRadius: stemWidth / 2).fill()
        let dotRect = NSRect(x: capsuleRect.midX - (dotDiameter / 2),
                             y: topY - totalHeight,
                             width: dotDiameter,
                             height: dotDiameter)
        NSBezierPath(ovalIn: dotRect).fill()
    }
    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - (2 * t))
    }
    private func smootherstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (value - edge0) / (edge1 - edge0)))
        return t * t * t * (t * ((t * 6) - 15) + 10)
    }
    private func backgroundPalette(alpha: CGFloat) -> (fill: NSColor, stroke: NSColor) {
        let light = shouldUseLightBackground()
        if light {
            return (
                NSColor(calibratedWhite: 1.0, alpha: 0.84 * alpha),
                NSColor(calibratedWhite: 0.0, alpha: 0.14 * alpha)
            )
        }
        return (
            NSColor(calibratedWhite: 0.0, alpha: 0.96 * alpha),
            NSColor(calibratedWhite: 0.22, alpha: 0.26 * alpha)
        )
    }
    func shouldUseLightBackground() -> Bool {
        switch backgroundStyle {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            let appearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return appearance == .aqua
        }
    }
}
let RECORDING_HUD_EXPORT_ARGUMENT = "--export-hud-animation"
@MainActor
func exportRecordingHUDAnimationFrames(to directory: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
    }
    try fileManager.createDirectory(at: directory,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    let hudSize = Settings.shared.recordingHUDSize
    let pointSize = hudSize.expandedSize
    let pixelScale: CGFloat = 4
    let pixelWidth = Int((pointSize.width * pixelScale).rounded())
    let pixelHeight = Int((pointSize.height * pixelScale).rounded())
    let framesPerSecond = 120.0
    let emptyLead = 0.35
    let recordingDuration = 6.20
    let transcribingDuration = 2.40
    let emptyTail = 0.50
    let totalDuration = emptyLead
        + RECORDING_HUD_ANIMATE_IN_SECONDS
        + recordingDuration
        + transcribingDuration
        + RECORDING_HUD_ANIMATE_OUT_SECONDS
        + emptyTail
    let frameCount = Int((totalDuration * framesPerSecond).rounded())
    let view = RecordingHUDView(frame: NSRect(origin: .zero, size: pointSize))
    view.visualScale = hudSize.visualScale
    let settings = Settings.shared
    view.recordingColor = settings.recordingHUDRecordingColor.resolvedColor(lightBackground: false)
    view.transcribingColor = settings.recordingHUDTranscribingColor.resolvedColor(lightBackground: false)
    view.backgroundStyle = .dark
    view.showsCapsuleStroke = false
    view.mode = .recording
    var phase: CGFloat = 0
    for frameIndex in 0..<frameCount {
        try autoreleasepool {
            let time = Double(frameIndex) / framesPerSecond
            let revealStart = emptyLead
            let recordingStart = revealStart + RECORDING_HUD_ANIMATE_IN_SECONDS
            let transcribingStart = recordingStart + recordingDuration
            let hideStart = transcribingStart + transcribingDuration
            let tailStart = hideStart + RECORDING_HUD_ANIMATE_OUT_SECONDS
            let reveal: CGFloat
            let level: Float
            let mode: RecordingHUDMode
            let transcribingElapsed: CGFloat?
            if time < revealStart {
                reveal = 0
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < recordingStart {
                reveal = CGFloat((time - revealStart) / RECORDING_HUD_ANIMATE_IN_SECONDS)
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < transcribingStart {
                reveal = 1
                let voiceTime = time - recordingStart
                let syllables = pow(max(0, sin((voiceTime * 8.7) + 0.35)), 0.58)
                let phrasing = 0.58 + (0.42 * ((sin((voiceTime * 2.15) - 0.7) + 1) / 2))
                let detail = 0.78 + (0.22 * ((sin((voiceTime * 13.4) + 1.8) + 1) / 2))
                level = Float(min(0.94, 0.10 + (0.78 * syllables * phrasing * detail)))
                mode = .recording
                transcribingElapsed = nil
            } else if time < hideStart {
                reveal = 1
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else if time < tailStart {
                reveal = 1 - CGFloat((time - hideStart) / RECORDING_HUD_ANIMATE_OUT_SECONDS)
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else {
                reveal = 0
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            }
            phase += recordingHUDPhaseSpeed(mode: mode, level: level)
                / CGFloat(framesPerSecond)
            view.revealProgress = max(0, min(1, reveal))
            view.mode = mode
            view.transcribingElapsedOverride = transcribingElapsed
            view.level = level
            view.phase = phase
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: pixelWidth,
                                                pixelsHigh: pixelHeight,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0,
                                                bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "SuperDictateHUDExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create an RGBA frame."])
            }
            bitmap.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(NSRect(origin: .zero, size: pointSize))
            context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
            view.displayIgnoringOpacity(view.bounds, in: context)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SuperDictateHUDExport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode a PNG frame."])
            }
            let name = String(format: "frame-%05d.png", frameIndex)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
    print("HUD_EXPORT frames=\(frameCount) fps=120 size=\(pixelWidth)x\(pixelHeight) duration=\(String(format: "%.3f", totalDuration))")
}
struct UpdateProgressLaunch {
    let statePath: String
    let logPath: String
    let targetVersion: String
    let cleanupAppPath: String
    init?(arguments: [String]) {
        guard arguments.count >= 5,
              arguments[0] == UPDATE_PROGRESS_ARGUMENT,
              !arguments[1].isEmpty,
              !arguments[2].isEmpty,
              !arguments[3].isEmpty,
              !arguments[4].isEmpty else {
            return nil
        }
        statePath = arguments[1]
        logPath = arguments[2]
        targetVersion = arguments[3]
        cleanupAppPath = arguments[4]
    }
}
struct UpdateProgressState {
    let phase: String
    let message: String
    static func read(from path: String) -> UpdateProgressState? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UpdateProgressState(phase: String(parts[0]), message: String(parts[1]))
    }
}
func isSafeUpdateProgressCleanupPath(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let tempPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .standardizedFileURL
        .path
    let tempPrefix = tempPath.hasSuffix("/") ? tempPath : "\(tempPath)/"
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return url.path.hasPrefix(tempPrefix)
        && url.pathExtension == "app"
        && url.lastPathComponent.hasPrefix(UPDATE_PROGRESS_APP_PREFIX)
}
@MainActor
final class UpdateProgressAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launch: UpdateProgressLaunch
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var closeWorkItem: DispatchWorkItem?
    private var lastPhase = ""
    private var lastMessage = ""
    private var messageLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openReleaseButton: NSButton!
    private var closeButton: NSButton!
    init(launch: UpdateProgressLaunch) {
        self.launch = launch
    }
    private var language: InterfaceLanguage { Settings.shared.interfaceLanguage }
    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        pollState()
        pollTimer = Timer.scheduledTimer(timeInterval: 0.5,
                                         target: self,
                                         selector: #selector(updateProgressTimerFired(_:)),
                                         userInfo: nil,
                                         repeats: true)
        pollTimer?.tolerance = 0.15
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        closeWorkItem?.cancel()
        scheduleCopiedAppCleanup()
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 184),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = t("Обновление SuperDictate Next", "Updating SuperDictate Next")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let title = updateProgressLabel(t("Обновление SuperDictate Next до v\(launch.targetVersion)",
                                          "Updating SuperDictate Next to v\(launch.targetVersion)"),
                                        font: .systemFont(ofSize: 18, weight: .semibold))
        messageLabel = updateProgressLabel(t("Запускаю обновление…", "Starting update…"),
                                           font: .systemFont(ofSize: 13, weight: .medium))
        detailLabel = updateProgressLabel(t("SuperDictate Next автоматически откроется после установки.",
                                             "SuperDictate Next will reopen automatically when the update finishes."),
                                          font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 390
        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let openLog = NSButton(title: t("Открыть журнал", "Open Log"),
                               target: self,
                               action: #selector(openUpdateLogClicked(_:)))
        openLog.bezelStyle = .rounded
        openReleaseButton = NSButton(title: t("Открыть страницу релиза", "Open Release Page"),
                                     target: self,
                                     action: #selector(openReleasePageClicked(_:)))
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.isHidden = true
        closeButton = NSButton(title: t("Закрыть", "Close"),
                               target: self,
                               action: #selector(closeUpdateProgressClicked(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true
        buttonRow.addArrangedSubview(openLog)
        buttonRow.addArrangedSubview(openReleaseButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(title)
        root.addArrangedSubview(messageLabel)
        root.addArrangedSubview(progress)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(buttonRow)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -(root.edgeInsets.left + root.edgeInsets.right)).isActive = true
        }
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 430),
            progress.heightAnchor.constraint(equalToConstant: 14),
        ])
        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    private func updateProgressLabel(_ text: String,
                                     font: NSFont,
                                     color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
    @objc private func updateProgressTimerFired(_ timer: Timer) {
        pollState()
    }
    private func pollState() {
        let state = UpdateProgressState.read(from: launch.statePath)
            ?? UpdateProgressState(phase: "starting",
                                   message: t("Запускаю обновление…", "Starting update…"))
        guard state.phase != lastPhase || state.message != lastMessage else { return }
        lastPhase = state.phase
        lastMessage = state.message
        messageLabel.stringValue = state.message
        switch state.phase {
        case "failed":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Предыдущая версия сохранена. Подробности доступны в журнале.",
                                        "The previous version was preserved. Open the log for details.")
            openReleaseButton.isHidden = false
            closeButton.isHidden = false
            NSApp.activate(ignoringOtherApps: true)
        case "complete":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Обновлённое приложение открывается. Это окно скоро закроется.",
                                        "The updated app is opening. This window will close shortly.")
            closeButton.isHidden = false
            scheduleClose(after: 4)
        case "installing":
            detailLabel.stringValue = t("Старая версия закрыта, новая устанавливается. Приложение откроется автоматически.",
                                        "The old version has closed while the new one is installed. It will reopen automatically.")
        case "relaunching":
            detailLabel.stringValue = t("Запускаю новую версию SuperDictate Next.",
                                        "Opening the new version of SuperDictate Next.")
            scheduleClose(after: 0.5)
        default:
            detailLabel.stringValue = t("SuperDictate Next автоматически откроется после установки.",
                                        "SuperDictate Next will reopen automatically when the update finishes.")
        }
    }
    private func scheduleClose(after delay: TimeInterval) {
        guard closeWorkItem == nil else { return }
        let item = DispatchWorkItem { NSApp.terminate(nil) }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func scheduleCopiedAppCleanup() {
        guard isSafeUpdateProgressCleanupPath(launch.cleanupAppPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 2; /bin/rm -rf \"$1\"", "cleanup", launch.cleanupAppPath]
        proc.environment = systemToolProcessEnvironment()
        try? proc.run()
    }
    @objc private func openUpdateLogClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(fileURLWithPath: launch.logPath))
    }
    @objc private func openReleasePageClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(GITHUB_RELEASES_PAGE)
    }
    @objc private func closeUpdateProgressClicked(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}
@MainActor
final class HistoryOverlayPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == ESCAPE_KEYCODE {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
@MainActor
final class HistoryItemLabel: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
    }
    required init?(coder: NSCoder) {
        nil
    }
    override var acceptsFirstResponder: Bool {
        false
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
@MainActor
final class HistoryDeleteButton: NSButton {
    let historyIndex: Int
    private let normalBackground = NSColor.clear
    private let hoverBackground = NSColor.systemRed.withAlphaComponent(0.12)
    init(historyIndex: Int) {
        self.historyIndex = historyIndex
        super.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .tertiaryLabelColor
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        toolTip = "Delete from History"
        setAccessibilityLabel("Delete from History")
    }
    required init?(coder: NSCoder) {
        nil
    }
    override var acceptsFirstResponder: Bool {
        false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
    func setHovered(_ hovered: Bool) {
        layer?.backgroundColor = (hovered ? hoverBackground : normalBackground).cgColor
        contentTintColor = hovered ? .systemRed : .tertiaryLabelColor
    }
}
@MainActor
final class HistoryTranscriptItemView: NSControl {
    enum HitAction {
        case copy(String)
        case delete(Int)
    }
    var transcript = ""
    private let label: HistoryItemLabel
    private let timingLabel: HistoryItemLabel
    private let timingBadge = NSView()
    private let deleteButton: HistoryDeleteButton
    private let onDelete: (Int) -> Void
    private var tracking: NSTrackingArea?
    private let normalBackground = NSColor.controlBackgroundColor.withAlphaComponent(0.28)
    private let hoverBackground = NSColor.labelColor.withAlphaComponent(0.08)
    private let pressedBackground = NSColor.labelColor.withAlphaComponent(0.14)
    init(transcript: String,
         preview: String,
         transcriptionDurationSeconds: Double?,
         asrTiming: ASRTimingBreakdown?,
         historyIndex: Int,
         target: AnyObject?,
         action: Selector,
         onDelete: @escaping (Int) -> Void) {
        self.transcript = transcript
        self.onDelete = onDelete
        label = HistoryItemLabel(preview)
        timingLabel = HistoryItemLabel(transcriptionDurationLabel(transcriptionDurationSeconds))
        deleteButton = HistoryDeleteButton(historyIndex: historyIndex)
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.13).cgColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        timingBadge.wantsLayer = true
        timingBadge.layer?.cornerRadius = 7
        timingBadge.layer?.cornerCurve = .continuous
        timingBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        timingBadge.layer?.borderWidth = 1
        timingBadge.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor
        timingBadge.toolTip = asrTimingTooltip(asrTiming)
        timingBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timingBadge)
        timingLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        timingLabel.textColor = transcriptionDurationSeconds == nil ? .tertiaryLabelColor : .secondaryLabelColor
        timingLabel.alignment = .center
        timingLabel.translatesAutoresizingMaskIntoConstraints = false
        timingBadge.addSubview(timingLabel)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            timingBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            timingBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            timingBadge.widthAnchor.constraint(equalToConstant: 68),
            timingBadge.heightAnchor.constraint(equalToConstant: 24),
            timingLabel.leadingAnchor.constraint(equalTo: timingBadge.leadingAnchor, constant: 4),
            timingLabel.trailingAnchor.constraint(equalTo: timingBadge.trailingAnchor, constant: -4),
            timingLabel.centerYAnchor.constraint(equalTo: timingBadge.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: timingBadge.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) {
        nil
    }
    override var acceptsFirstResponder: Bool {
        false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverBackground.cgColor
        updateDeleteHover(for: event)
    }
    override func mouseMoved(with event: NSEvent) {
        updateDeleteHover(for: event)
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
        deleteButton.setHovered(false)
    }
    override func mouseDown(with event: NSEvent) {
        guard let hitAction = hitAction(atWindowPoint: event.locationInWindow) else { return }
        switch hitAction {
        case .copy:
            layer?.backgroundColor = pressedBackground.cgColor
            guard let action else { return }
            NSApp.sendAction(action, to: target, from: self)
        case .delete(let historyIndex):
            onDelete(historyIndex)
        }
    }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }
    func hitAction(atWindowPoint point: NSPoint) -> HitAction? {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return nil }
        if deleteButton.frame.insetBy(dx: -6, dy: -6).contains(localPoint) {
            return .delete(deleteButton.historyIndex)
        }
        return .copy(transcript)
    }
    private func updateDeleteHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        deleteButton.setHovered(deleteButton.frame.contains(point))
    }
}
@MainActor
final class HistoryToolbarButton: NSControl {
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private let normalBackground = NSColor.clear
    private let hoverBackground = NSColor.labelColor.withAlphaComponent(0.08)
    private let pressedBackground = NSColor.labelColor.withAlphaComponent(0.14)
    init(symbolName: String,
         accessibilityDescription: String,
         toolTip: String,
         target: AnyObject?,
         action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normalBackground.cgColor
        imageView.image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        imageView.image?.isTemplate = true
        imageView.contentTintColor = .secondaryLabelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17),
        ])
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityDescription)
    }
    required init?(coder: NSCoder) {
        nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverBackground.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedBackground.cgColor
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = normalBackground.cgColor
    }
}
func formattedUsageInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
}
func formattedUsageDuration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total >= 3_600 {
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes > 0 ? "\(hours) ч \(minutes) мин" : "\(hours) ч"
    }
    if total >= 60 {
        let minutes = total / 60
        let remainder = total % 60
        return remainder > 0 ? "\(minutes) мин \(remainder) сек" : "\(minutes) мин"
    }
    return "\(total) сек"
}
func formattedUsageSeconds(_ seconds: Double) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return "\(formatter.string(from: NSNumber(value: max(0, seconds))) ?? "0,00") с"
}
func compactUsageInteger(_ value: Int) -> String {
    guard value >= 1_000 else { return String(max(0, value)) }
    let scaled = Double(value) / 1_000
    let digits = scaled >= 10 ? 0 : 1
    return String(format: "%.*fк", digits, scaled).replacingOccurrences(of: ".", with: ",")
}
func russianUsageDateRange(_ snapshot: DictationUsageWeekSnapshot,
                                   calendar: Calendar) -> String {
    guard let first = snapshot.days.first?.date,
          let last = snapshot.days.last?.date else { return "" }
    let locale = Locale(identifier: "ru_RU")
    let firstComponents = calendar.dateComponents([.month, .year], from: first)
    let lastComponents = calendar.dateComponents([.month, .year], from: last)
    let lastFormatter = DateFormatter()
    lastFormatter.locale = locale
    lastFormatter.calendar = calendar
    lastFormatter.dateFormat = "d MMMM"
    if firstComponents == lastComponents {
        return "\(calendar.component(.day, from: first))–\(lastFormatter.string(from: last))"
    }
    let firstFormatter = DateFormatter()
    firstFormatter.locale = locale
    firstFormatter.calendar = calendar
    firstFormatter.dateFormat = "d MMM"
    return "\(firstFormatter.string(from: first)) – \(lastFormatter.string(from: last))"
}
@MainActor
final class UsageMetricCard: NSView {
    init(symbolName: String,
         tint: NSColor,
         title: String,
         value: String,
         detail: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.052).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        icon.image?.isTemplate = true
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        let titleLabel = HistoryItemLabel(title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        let valueLabel = HistoryItemLabel(value)
        valueLabel.font = .systemFont(ofSize: 31, weight: .bold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        let detailLabel = HistoryItemLabel(detail)
        detailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 136),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalToConstant: 19),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 13),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 5),
        ])
    }
    required init?(coder: NSCoder) {
        nil
    }
}
@MainActor
final class DictationUsageChartView: NSView {
    let snapshot: DictationUsageWeekSnapshot
    private let calendar: Calendar
    init(snapshot: DictationUsageWeekSnapshot, calendar: Calendar) {
        self.snapshot = snapshot
        self.calendar = calendar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("График символов по дням")
    }
    required init?(coder: NSCoder) {
        nil
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = NSRect(x: 24, y: 32, width: max(1, bounds.width - 48), height: max(1, bounds.height - 72))
        let values = snapshot.days.map(\.usage.characterCount)
        let maximum = max(1, values.max() ?? 0)
        let slotWidth = plot.width / CGFloat(max(1, snapshot.days.count))
        let barWidth = min(54, slotWidth * 0.54)
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.16)
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plot.maxY - (plot.height * fraction)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 1
            gridColor.setStroke()
            path.stroke()
        }
        let peakIndex = values.firstIndex(of: values.max() ?? 0)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ru_RU")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "EEE"
        for (index, slot) in snapshot.days.enumerated() {
            let value = slot.usage.characterCount
            let normalized = CGFloat(value) / CGFloat(maximum)
            let height = value > 0 ? max(4, plot.height * normalized) : 2
            let centerX = plot.minX + (slotWidth * (CGFloat(index) + 0.5))
            let rect = NSRect(x: centerX - (barWidth / 2),
                              y: plot.maxY - height,
                              width: barWidth,
                              height: height)
            let color: NSColor = index == peakIndex && value > 0 ? .systemPink : .systemBlue
            color.withAlphaComponent(value > 0 ? 0.78 : 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(7, barWidth / 2), yRadius: min(7, barWidth / 2)).fill()
            if value > 0 {
                let valueText = compactUsageInteger(value) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let size = valueText.size(withAttributes: attributes)
                valueText.draw(at: NSPoint(x: centerX - (size.width / 2),
                                           y: max(3, rect.minY - size.height - 4)),
                               withAttributes: attributes)
            }
            let rawDay = dayFormatter.string(from: slot.date)
                .replacingOccurrences(of: ".", with: "")
                .lowercased()
            let dayText = rawDay as NSString
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let daySize = dayText.size(withAttributes: dayAttributes)
            dayText.draw(at: NSPoint(x: centerX - (daySize.width / 2), y: plot.maxY + 13),
                         withAttributes: dayAttributes)
        }
        if snapshot.totalDictations == 0 {
            let text = "За этот период пока нет данных" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - (size.width / 2),
                                  y: plot.midY - (size.height / 2)),
                      withAttributes: attributes)
        }
    }
}
@MainActor
final class DictationSpeechTimeChartView: NSView {
    private let snapshot: DictationUsageWeekSnapshot
    private let calendar: Calendar
    init(snapshot: DictationUsageWeekSnapshot, calendar: Calendar) {
        self.snapshot = snapshot
        self.calendar = calendar
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("График времени речи по дням")
    }
    required init?(coder: NSCoder) {
        nil
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = NSRect(x: 26,
                          y: 42,
                          width: max(1, bounds.width - 52),
                          height: max(1, bounds.height - 82))
        let values = snapshot.days.map { max(0, $0.usage.audioSeconds / 60) }
        let maximum = max(1, values.max() ?? 0)
        let slotWidth = plot.width / CGFloat(max(1, snapshot.days.count))
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.16)
        for fraction in [CGFloat(0), 0.5, 1] {
            let y = plot.maxY - (plot.height * fraction)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y))
            path.line(to: NSPoint(x: plot.maxX, y: y))
            path.lineWidth = 1
            gridColor.setStroke()
            path.stroke()
        }
        let points = values.enumerated().map { index, value in
            NSPoint(x: plot.minX + (slotWidth * (CGFloat(index) + 0.5)),
                    y: plot.maxY - (plot.height * CGFloat(value / maximum)))
        }
        func appendSmoothCurve(to path: NSBezierPath, moveToFirst: Bool = true) {
            guard let first = points.first else { return }
            if moveToFirst {
                path.move(to: first)
            }
            guard points.count > 1 else { return }
            for index in 1..<points.count {
                let p0 = points[max(0, index - 2)]
                let p1 = points[index - 1]
                let p2 = points[index]
                let p3 = points[min(points.count - 1, index + 1)]
                let control1 = NSPoint(x: p1.x + ((p2.x - p0.x) / 6),
                                       y: p1.y + ((p2.y - p0.y) / 6))
                let control2 = NSPoint(x: p2.x - ((p3.x - p1.x) / 6),
                                       y: p2.y - ((p3.y - p1.y) / 6))
                path.curve(to: p2, controlPoint1: control1, controlPoint2: control2)
            }
        }
        if let first = points.first, let last = points.last {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: first.x, y: plot.maxY))
            area.line(to: first)
            appendSmoothCurve(to: area, moveToFirst: false)
            area.line(to: NSPoint(x: last.x, y: plot.maxY))
            area.close()
            NSColor.systemOrange.withAlphaComponent(0.10).setFill()
            area.fill()
            let line = NSBezierPath()
            appendSmoothCurve(to: line)
            line.lineWidth = 3
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            NSColor.systemOrange.withAlphaComponent(0.88).setStroke()
            line.stroke()
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ru_RU")
        dayFormatter.calendar = calendar
        dayFormatter.dateFormat = "EEE"
        let peakIndex = values.firstIndex(of: values.max() ?? 0)
        for (index, slot) in snapshot.days.enumerated() {
            guard index < points.count else { continue }
            let point = points[index]
            let dotRadius: CGFloat = index == peakIndex && values[index] > 0 ? 5.5 : 4
            let dotColor: NSColor = index == peakIndex && values[index] > 0 ? .systemPink : .systemOrange
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - dotRadius,
                                        y: point.y - dotRadius,
                                        width: dotRadius * 2,
                                        height: dotRadius * 2)).fill()
            if values[index] > 0 {
                let valueText = "\(Int(values[index].rounded())) м" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let size = valueText.size(withAttributes: attributes)
                valueText.draw(at: NSPoint(x: point.x - (size.width / 2),
                                           y: max(4, point.y - size.height - 10)),
                               withAttributes: attributes)
            }
            let dayText = dayFormatter.string(from: slot.date)
                .replacingOccurrences(of: ".", with: "")
                .lowercased() as NSString
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let daySize = dayText.size(withAttributes: dayAttributes)
            dayText.draw(at: NSPoint(x: point.x - (daySize.width / 2), y: plot.maxY + 14),
                         withAttributes: dayAttributes)
        }
        if snapshot.totalDictations == 0 {
            let text = "За этот период пока нет данных" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - (size.width / 2),
                                  y: plot.midY - (size.height / 2)),
                      withAttributes: attributes)
        }
    }
}
