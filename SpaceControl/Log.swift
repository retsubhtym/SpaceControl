import Foundation

/// Error reporting to the unified log (visible in Console.app, filter by "SpaceControl").
enum Log {
    static func error(_ message: String) {
        NSLog("SpaceControl: %@", message)
    }
}
