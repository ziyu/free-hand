import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: "com.feibai.freehand", category: "runtime")
    /// Call sites must supply operational metadata only: no goals, screen labels or typed text.
    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
}
