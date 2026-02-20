import OSLog

enum Log {
  static let connection = Logger(subsystem: "sh.bebop.xpc", category: "connection")
  static let rpc = Logger(subsystem: "sh.bebop.xpc", category: "rpc")
}
