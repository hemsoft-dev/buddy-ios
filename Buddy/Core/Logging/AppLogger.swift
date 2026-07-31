import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hemsoft.buddy"

    static let integrations = Logger(subsystem: subsystem, category: "Integrations")
    static let routing = Logger(subsystem: subsystem, category: "Routing")
}
