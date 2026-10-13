import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.endtranslate", category: "application")

    static func write(_ message: String) {
        logger.info("\(message, privacy: .private)")
    }
}
