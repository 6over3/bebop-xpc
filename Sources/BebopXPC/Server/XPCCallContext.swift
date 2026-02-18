import Foundation
import SwiftBebop
import Synchronization

/// CallContext conformance for server-side XPC calls.
public final class XPCCallContext: CallContext, @unchecked Sendable {
  public let methodId: UInt32
  public let requestMetadata: [String: String]
  public let deadline: BebopTimestamp?

  /// The incoming XPC header message for this call.
  public let message: XPCMessage.Reader?

  private let _cancelled = Mutex(false)
  private let _responseMetadata = Mutex<[String: String]>([:])
  private let _userInfo = Mutex<[String: any Sendable]>([:])
  private let _responsePreparer = Mutex<(@Sendable (XPCMessage.Writer) -> Void)?>(nil)

  public var isCancelled: Bool { _cancelled.withLock { $0 } }

  /// Per-call storage for custom data.
  public subscript(key: String) -> (any Sendable)? {
    get { _userInfo.withLock { $0[key] } }
    set { _userInfo.withLock { $0[key] = newValue } }
  }

  init(
    methodId: UInt32,
    metadata: [String: String],
    deadline: BebopTimestamp?,
    message: XPCMessage.Reader? = nil
  ) {
    self.methodId = methodId
    self.requestMetadata = metadata
    self.deadline = deadline
    self.message = message
  }

  /// Attach a key-value pair to the response trailer.
  public func setResponseMetadata(_ key: String, _ value: String) {
    _responseMetadata.withLock { $0[key] = value }
  }

  /// Register a closure to write custom XPC data (fds, blobs, etc.) into the response message.
  public func prepareResponse(_ body: @escaping @Sendable (XPCMessage.Writer) -> Void) {
    _responsePreparer.withLock { $0 = body }
  }

  var responseMetadata: [String: String] { _responseMetadata.withLock { $0 } }
  var responsePreparer: (@Sendable (XPCMessage.Writer) -> Void)? { _responsePreparer.withLock { $0 } }

  func cancel() { _cancelled.withLock { $0 = true } }
}
