import Foundation

#if canImport(os)
import os
#endif

/// Minimal logging shim so the package builds on Linux (for tests) as well as Apple platforms.
enum CerbosLog {
    #if canImport(os)
    private static let logger = Logger(subsystem: "dev.cerbos.epdp", category: "CerbosEmbeddedPDP")
    #endif

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.debug("\(text, privacy: .public)")
        #else
        emit("DEBUG", text)
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.info("\(text, privacy: .public)")
        #else
        emit("INFO", text)
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        #if canImport(os)
        logger.error("\(text, privacy: .public)")
        #else
        emit("ERROR", text)
        #endif
    }

    #if !canImport(os)
    private static func emit(_ level: String, _ message: String) {
        guard ProcessInfo.processInfo.environment["CERBOS_LOG"] != nil else { return }
        FileHandle.standardError.write(Data("[CerbosEmbeddedPDP] \(level): \(message)\n".utf8))
    }
    #endif
}
