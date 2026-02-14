import OSLog

enum Log {
  static let connection = Logger(subsystem: "dev.bebop.xpc", category: "connection")
  static let rpc = Logger(subsystem: "dev.bebop.xpc", category: "rpc")
}
