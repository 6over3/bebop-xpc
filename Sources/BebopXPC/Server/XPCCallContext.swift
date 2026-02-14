import SwiftBebop
import Synchronization

/// CallContext conformance for server-side XPC calls.
public final class XPCCallContext: CallContext, @unchecked Sendable {
  public let methodId: UInt32
  public let requestMetadata: [String: String]
  public let deadline: BebopTimestamp?

  private let _cancelled = Mutex(false)
  private let _responseMetadata = Mutex<[String: String]>([:])

  public var isCancelled: Bool { _cancelled.withLock { $0 } }

  init(methodId: UInt32, metadata: [String: String], deadline: BebopTimestamp?) {
    self.methodId = methodId
    self.requestMetadata = metadata
    self.deadline = deadline
  }

  /// Attach a key-value pair to the response trailer.
  public func setResponseMetadata(_ key: String, _ value: String) {
    _responseMetadata.withLock { $0[key] = value }
  }

  var responseMetadata: [String: String] { _responseMetadata.withLock { $0 } }

  func cancel() { _cancelled.withLock { $0 = true } }
}
