import Foundation

#if canImport(os)
import os
#endif

/// Logging shim so the package also builds on Linux (for tests).
///
/// `message` is fixed text and logged publicly. `detail` carries runtime values (error messages from
/// Hub, the engine or the app's JWT decoder, bundle IDs) and is private, so it is redacted in logs
/// collected from devices unless a debugger or profile is attached.
enum CerbosLog {
    static let subsystem = "dev.cerbos.epdp"

    #if canImport(os)
    private static let logger = Logger(subsystem: subsystem, category: "CerbosEmbeddedPDP")
    #endif

    static func log(_ level: CerbosLogLevel, _ message: StaticString, detail: String? = nil) {
        #if canImport(os)
        let text = "\(message)"
        let osLevel: OSLogType =
            switch level {
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        if let detail {
            logger.log(level: osLevel, "\(text, privacy: .public): \(detail, privacy: .private)")
        } else {
            logger.log(level: osLevel, "\(text, privacy: .public)")
        }
        #else
        guard ProcessInfo.processInfo.environment["CERBOS_LOG"] != nil else { return }
        let line = detail.map { "\(message): \($0)" } ?? "\(message)"
        FileHandle.standardError.write(Data("[CerbosEmbeddedPDP] \(level.rawValue): \(line)\n".utf8))
        #endif
    }

    static func debug(_ message: StaticString, detail: String? = nil) { log(.debug, message, detail: detail) }
    static func info(_ message: StaticString, detail: String? = nil) { log(.info, message, detail: detail) }
    static func error(_ message: StaticString, detail: String? = nil) { log(.error, message, detail: detail) }
}

/// Severity of a ``CerbosEmbeddedPDP/LogLine``.
public enum CerbosLogLevel: String, Sendable, Comparable, CaseIterable {
    case debug, info, warning, error

    /// Maps the bridge's JavaScript console levels.
    init(bridgeLevel: String) {
        switch bridgeLevel {
        case "debug": self = .debug
        case "warn": self = .warning
        case "error": self = .error
        default: self = .info
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
