import Foundation
import os

/// Sync diagnostics: unified logging (subsystem com.niklasarnitz.opengarmin, category sync), stdout for
/// `devicectl --console`, and Library/Caches/sync-diagnostics.log in the app container, which
/// `devicectl device copy from --domain-type appDataContainer` can fetch from a development build.
enum SyncDiagnostics {
    private static let logger = Logger(subsystem: "com.niklasarnitz.opengarmin", category: "sync")
    private static let queue = DispatchQueue(label: "com.niklasarnitz.opengarmin.diagnostics")
    static let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sync-diagnostics.log")

    static func log(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)"
        logger.notice("\(line, privacy: .public)")
        print("[sync] \(line)")
        queue.async {
            let data = Data((line + "\n").utf8)
            // Keep the file small: start over once it passes 1 MB.
            if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
               size > 1_000_000 {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
