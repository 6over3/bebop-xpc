import Foundation

/// Errors specific to the XPC transport layer.
public enum XPCError: LocalizedError, Sendable {
  case notConnected
  case connectionLost(reason: String)
  case securityViolation(reason: String)
  case timeout(Duration)
  case cancelled
  case sessionCreationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Not connected to XPC service"
    case .connectionLost(let reason):
      return "XPC connection lost: \(reason)"
    case .securityViolation(let reason):
      return "XPC security violation: \(reason)"
    case .timeout(let duration):
      return "XPC operation timed out after \(duration)"
    case .cancelled:
      return "XPC operation cancelled"
    case .sessionCreationFailed(let reason):
      return "Failed to create XPC session: \(reason)"
    }
  }

  /// Whether the operation can be retried on a new connection.
  public var isRetryable: Bool {
    switch self {
    case .connectionLost, .timeout:
      return true
    case .notConnected, .securityViolation, .cancelled, .sessionCreationFailed:
      return false
    }
  }
}
