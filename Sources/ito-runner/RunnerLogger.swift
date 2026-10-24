import Foundation
import OSLog

public enum RunnerLogger {
    nonisolated(unsafe) private static let subsystem = "com.ito.runner"

    nonisolated(unsafe) public static let core = Logger(subsystem: subsystem, category: "core")
    nonisolated(unsafe) public static let wasm = Logger(subsystem: subsystem, category: "wasm")
    nonisolated(unsafe) public static let bridge = Logger(subsystem: subsystem, category: "bridge")
}
