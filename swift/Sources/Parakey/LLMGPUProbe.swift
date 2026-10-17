import Foundation

/// The GPUs the bundled LLM host can run on, as its own Vulkan stack sees
/// them (`SuperDictateLLMHost --list-devices`). Speech recognition is CPU
/// only, so this exists solely for the "LLM on GPU (Vulkan)" menu item.
/// Probed once per app process: the helper starts, enumerates devices and
/// exits in about 0.2 s; a hung driver is cut off after `timeoutSeconds`.
final class LLMGPUProbe: @unchecked Sendable {
    static let shared = LLMGPUProbe()
    static let timeoutSeconds: Double = 5

    private let lock = NSLock()
    private var cachedDevices: [String]?

    /// Device descriptions (e.g. "AMD Radeon Vega"), empty when the helper
    /// is missing, fails, times out or finds no GPU.
    func devices() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedDevices { return cachedDevices }
        let found = Self.probe()
        cachedDevices = found
        log("LLM GPU probe: \(found.isEmpty ? "no Vulkan device" : found.joined(separator: ", "))")
        return found
    }

    private static func probe() -> [String] {
        guard let binaryURL = LLMHostProcess.resolvedHelperBinaryURL(),
              FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            return []
        }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--list-devices"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return []
        }
        // Read before waiting so a full pipe can never stall the helper.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            process.terminate()
            return []
        }
        guard process.terminationStatus == 0 else { return [] }
        return parseLLMGPUDeviceList(String(decoding: data, as: UTF8.self))
    }
}

/// Parses `--list-devices` output: one `DEVICE <name>\t<description>` line
/// per GPU. Falls back to the name when the description is empty.
func parseLLMGPUDeviceList(_ output: String) -> [String] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
        guard line.hasPrefix("DEVICE ") else { return nil }
        let fields = line.dropFirst("DEVICE ".count).split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let name = fields.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let description = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: .whitespaces) : ""
        let label = description.isEmpty ? name : description
        return label.isEmpty ? nil : label
    }
}
