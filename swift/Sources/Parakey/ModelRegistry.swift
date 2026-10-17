// SuperDictate — extracted from the monolithic main.swift
// during the refactor/split-main refactor (custom registry hardening).
//
import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Model registry hardening
//
// These historically overrode the speech-model download base URL for
// the previous CoreML-based ASR stack. Parakey's parakeet.cpp download
// path (`downloadParakeetModelIfNeeded`) uses a single hardcoded, pinned
// URL and does not consult either variable, but the hardening check
// stays as defense in depth: a value here still means either
// (a) a developer is debugging a mirror — uncommon — or (b) a process
// or LaunchAgent has injected one, which is worth surfacing regardless.
// An attacker who can plant `~/Library/LaunchAgents/*.plist` with
// `EnvironmentVariables` gets this persistence channel for free on
// every GUI app launch. Treat any value as adversarial: log it, present
// a blocking alert, refuse to start. The user fixes the env source and
// relaunches.
//
// We do not block HF_TOKEN etc. — those are auth headers some download
// tooling sends to the (unchanged) huggingface.co host; a user with
// HF_TOKEN set for unrelated tooling shouldn't be punished.

let HOSTILE_REGISTRY_ENV_VARS = ["REGISTRY_URL", "MODEL_REGISTRY_URL"]

func detectedHostileRegistryEnvVars(in env: [String: String]) -> [String] {
    HOSTILE_REGISTRY_ENV_VARS.filter { env[$0] != nil }.sorted()
}

@MainActor
func refuseHostileRegistryEnvironmentAndExit() {
    let detected = detectedHostileRegistryEnvVars(in: ProcessInfo.processInfo.environment)
    guard !detected.isEmpty else { return }
    let names = detected.joined(separator: ", ")
    log("refusing to start: registry override env var(s) set: \(names)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Parakey refused to start"
    alert.informativeText = """
        These environment variable(s) are set in Parakey's process: \(names).

        Parakey does not support overriding the speech-model download URL and treats their presence as a sign that the launch environment has been tampered with.

        Check ~/Library/LaunchAgents/, your shell rc files, and any parent process. Once the variables are gone, launch Parakey again.
        """
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(EXIT_FAILURE)
}

