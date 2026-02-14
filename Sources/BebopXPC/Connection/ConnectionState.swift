enum ConnectionState: Sendable, Equatable {
  case idle
  case connecting
  case connected
  case disconnected(reason: String)
  case failed(reason: String)

  var isReady: Bool {
    if case .connected = self { return true }
    return false
  }
}
