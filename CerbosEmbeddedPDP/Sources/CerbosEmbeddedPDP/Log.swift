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
        #if canImport(os)
        logger.debug("\(message(), privacy: .public)")
        #else
        emit("DEBUG", message())
        #endif
    }

    static func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.info("\(message(), privacy: .public)")
        #else
        emit("INFO", message())
        #endif
    }

    static func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        logger.error("\(message(), privacy: .public)")
        #else
        emit("ERROR", message())
        #endif
    }

    #if !canImport(os)
    private static func emit(_ level: String, _ message: String) {
        guard ProcessInfo.processInfo.environment["CERBOS_LOG"] != nil else { return }
        FileHandle.standardError.write(Data("[CerbosEmbeddedPDP] \(level): \(message)\n".utf8))
    }
    #endif
}
