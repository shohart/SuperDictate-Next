// SuperDictate — what each stage of a dictation produced, kept on this
// machine only, for finding where the text went wrong. The recent history
// already holds the final text; this adds what recognition wrote before the
// rules and the corrector changed it. Windows: `dictation_trace.py`.

import Foundation

enum DictationTrace {
    static let defaultMaxLines = 2000

    static var fileURL: URL? {
        try? superDictateApplicationSupportDirectory().appendingPathComponent("DictationTrace.jsonl")
    }

    /// Never throws and never blocks a dictation on a disk problem. The file
    /// is cut back to `maxLines` once it reaches twice that.
    static func record(asr: String, rules: String, final: String,
                       to url: URL? = DictationTrace.fileURL, maxLines: Int = defaultMaxLines) {
        guard let url else { return }
        let entry: [String: Any] = ["at": VocabularyStore.timestamp(), "asr": asr, "rules": rules, "final": final]
        guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        try? handle.close()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        if lines.count >= maxLines * 2 {
            let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
            try? kept.write(to: url, atomically: true, encoding: .utf8)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
