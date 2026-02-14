/// Lifecycle events emitted by an XPC channel.
public enum ConnectionEvent: Sendable {
  case connected
  case disconnected(reason: String)
  case failed(reason: String)

  /// True when the channel has an active connection.
  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}
