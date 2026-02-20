import Foundation
import SwiftBebop
import Synchronization
import XPC

/// BebopChannel implementation over Apple XPC.
public final class XPCBebopChannel: BebopChannel, @unchecked Sendable {
  public typealias Metadata = XPCMessage.Reader

  // MARK: - Internal types

  private enum ActiveCall {
    case unary(CheckedContinuation<Response<[UInt8], XPCMessage.Reader>, any Error>)
    case stream(
      AsyncThrowingStream<([UInt8], UInt64?), any Error>.Continuation,
      MetadataPromise
    )
  }

  private struct State {
    var nextCallId: UInt32 = 1
    var activeCalls: [UInt32: ActiveCall] = [:]
  }

  // MARK: - Stored state

  private let _state = Mutex(State())
  private let _session = Mutex<XPCSession?>(nil)
  private let _connectionState = Mutex(ConnectionState.idle)
  private let _eventContinuation: AsyncStream<ConnectionEvent>.Continuation

  /// Connection lifecycle events.
  public let events: AsyncStream<ConnectionEvent>

  var state: ConnectionState { _connectionState.withLock { $0 } }

  // MARK: - Initializers

  /// Connect to a bundled XPC service.
  public init(xpcService name: String, security: SecurityPolicy = .none) throws {
    let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
    self.events = stream
    self._eventContinuation = continuation
    try createSession(xpcService: name, security: security)
  }

  /// Connect to a launchd Mach service.
  public init(machService name: String, security: SecurityPolicy = .none) throws {
    let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
    self.events = stream
    self._eventContinuation = continuation
    try createSession(machService: name, security: security)
  }

  /// Connect to an anonymous listener endpoint for testing per TN3113.
  public init(endpoint: XPCEndpoint) throws {
    let (stream, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self)
    self.events = stream
    self._eventContinuation = continuation
    try createSession(endpoint: endpoint)
  }

  // MARK: - Lifecycle

  /// Close the channel and cancel all outstanding calls.
  public func cancel() {
    let session = _session.withLock { s -> XPCSession? in
      let current = s
      s = nil
      return current
    }
    session?.cancel(reason: "client cancelled")
    updateState(.disconnected(reason: "cancelled"))
    _eventContinuation.yield(.disconnected(reason: "cancelled"))
    cancelAllCalls(error: BebopRpcError(code: .cancelled))
    _eventContinuation.finish()
  }

  // MARK: - BebopChannel

  public func unary(
    method: UInt32,
    request: [UInt8],
    context: RpcContext
  ) async throws -> Response<[UInt8], XPCMessage.Reader> {
    if let deadline = context.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let deadlineTask = context.deadline.map { enforceDeadline($0, forCall: callId) }
    return try await withTaskCancellationHandler {
      defer { deadlineTask?.cancel() }
      return try await withCheckedThrowingContinuation { continuation in
        _state.withLock { $0.activeCalls[callId] = .unary(continuation) }
        do {
          let session = try self.session()
          try sendHeader(callId: callId, method: method, context: context, via: session)
          try sendFrame(callId: callId, bytes: Frame(payload: request, flags: .endStream).encode(), via: session)
        } catch {
          deadlineTask?.cancel()
          if _state.withLock({ $0.activeCalls.removeValue(forKey: callId) }) != nil {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      deadlineTask?.cancel()
      self.cancelCall(callId)
    }
  }

  public func serverStream(
    method: UInt32,
    request: [UInt8],
    context: RpcContext
  ) async throws -> StreamResponse<[UInt8], XPCMessage.Reader> {
    if let deadline = context.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let promise = MetadataPromise()
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ([UInt8], UInt64?).self)
    _state.withLock { $0.activeCalls[callId] = .stream(continuation, promise) }
    let deadlineTask = context.deadline.map { enforceDeadline($0, forCall: callId) }
    continuation.onTermination = { @Sendable _ in
      deadlineTask?.cancel()
      self.removeCall(callId)
    }
    do {
      let session = try self.session()
      try sendHeader(callId: callId, method: method, context: context, via: session)
      try sendFrame(callId: callId, bytes: Frame(payload: request, flags: .endStream).encode(), via: session)
    } catch {
      deadlineTask?.cancel()
      if _state.withLock({ $0.activeCalls.removeValue(forKey: callId) }) != nil {
        continuation.finish(throwing: error)
      }
    }
    return StreamResponse(stream: stream, trailing: { await promise.value })
  }

  public func clientStream(
    method: UInt32,
    context: RpcContext
  ) async throws -> (
    send: @Sendable ([UInt8]) async throws -> Void,
    finish: @Sendable () async throws -> Response<[UInt8], XPCMessage.Reader>
  ) {
    if let deadline = context.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let session = try self.session()
    try sendHeader(callId: callId, method: method, context: context, via: session)

    let send: @Sendable ([UInt8]) async throws -> Void = { [weak self] payload in
      guard let self else { throw XPCError.notConnected }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: Frame(payload: payload, flags: []).encode(), via: s)
    }

    let finish: @Sendable () async throws -> Response<[UInt8], XPCMessage.Reader> = { [weak self] in
      guard let self else { throw XPCError.notConnected }
      if let deadline = context.deadline, deadline.isPast {
        throw BebopRpcError(code: .deadlineExceeded)
      }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: Frame(payload: [], flags: .endStream).encode(), via: s)
      let deadlineTask = context.deadline.map { self.enforceDeadline($0, forCall: callId) }
      return try await withTaskCancellationHandler {
        defer { deadlineTask?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
          self._state.withLock { $0.activeCalls[callId] = .unary(continuation) }
        }
      } onCancel: {
        deadlineTask?.cancel()
        self.cancelCall(callId)
      }
    }

    return (send: send, finish: finish)
  }

  public func duplexStream(
    method: UInt32,
    context: RpcContext
  ) async throws -> (
    send: @Sendable ([UInt8]) async throws -> Void,
    finish: @Sendable () async throws -> Void,
    responses: StreamResponse<[UInt8], XPCMessage.Reader>
  ) {
    if let deadline = context.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let promise = MetadataPromise()
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ([UInt8], UInt64?).self)
    _state.withLock { $0.activeCalls[callId] = .stream(continuation, promise) }
    let deadlineTask = context.deadline.map { enforceDeadline($0, forCall: callId) }
    continuation.onTermination = { @Sendable _ in
      deadlineTask?.cancel()
      self.removeCall(callId)
    }

    do {
      let session = try self.session()
      try sendHeader(callId: callId, method: method, context: context, via: session)
    } catch {
      deadlineTask?.cancel()
      if _state.withLock({ $0.activeCalls.removeValue(forKey: callId) }) != nil {
        continuation.finish(throwing: error)
      }
      throw error
    }

    let send: @Sendable ([UInt8]) async throws -> Void = { [weak self] payload in
      guard let self else { throw XPCError.notConnected }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: Frame(payload: payload, flags: []).encode(), via: s)
    }

    let finish: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { throw XPCError.notConnected }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: Frame(payload: [], flags: .endStream).encode(), via: s)
    }

    return (send: send, finish: finish, responses: StreamResponse(stream: stream, trailing: { await promise.value }))
  }

  // MARK: - Session creation

  private func createSession(xpcService name: String, security: SecurityPolicy) throws {
    updateState(.connecting)
    do {
      let incoming = makeIncomingHandler()
      let cancelled = makeCancellationHandler()
      let session: XPCSession
      if let requirement = security.makePeerRequirement() {
        session = try XPCSession(
          xpcService: name, options: .inactive, requirement: requirement,
          incomingMessageHandler: incoming, cancellationHandler: cancelled)
      } else {
        session = try XPCSession(
          xpcService: name, options: .inactive,
          incomingMessageHandler: incoming, cancellationHandler: cancelled)
      }
      try activateAndStore(session)
    } catch {
      throw handleCreationFailure(error)
    }
  }

  private func createSession(machService name: String, security: SecurityPolicy) throws {
    updateState(.connecting)
    do {
      let incoming = makeIncomingHandler()
      let cancelled = makeCancellationHandler()
      let session: XPCSession
      if let requirement = security.makePeerRequirement() {
        session = try XPCSession(
          machService: name, options: .inactive, requirement: requirement,
          incomingMessageHandler: incoming, cancellationHandler: cancelled)
      } else {
        session = try XPCSession(
          machService: name, options: .inactive,
          incomingMessageHandler: incoming, cancellationHandler: cancelled)
      }
      try activateAndStore(session)
    } catch {
      throw handleCreationFailure(error)
    }
  }

  private func createSession(endpoint: XPCEndpoint) throws {
    updateState(.connecting)
    do {
      let session = try XPCSession(
        endpoint: endpoint,
        incomingMessageHandler: makeIncomingHandler(),
        cancellationHandler: makeCancellationHandler())
      _session.withLock { $0 = session }
      updateState(.connected)
      _eventContinuation.yield(.connected)
    } catch {
      throw handleCreationFailure(error)
    }
  }

  private func handleCreationFailure(_ error: any Error) -> XPCError {
    let reason = String(describing: error)
    updateState(.failed(reason: reason))
    _eventContinuation.yield(.failed(reason: reason))
    _eventContinuation.finish()
    return .sessionCreationFailed(reason)
  }

  private func makeIncomingHandler() -> @Sendable (XPCDictionary) -> XPCDictionary? {
    { [weak self] msg in
      self?.handleIncoming(msg)
      return nil
    }
  }

  private func makeCancellationHandler() -> @Sendable (any Error) -> Void {
    { [weak self] _ in self?.handleConnectionLoss() }
  }

  private func activateAndStore(_ session: XPCSession) throws {
    try session.activate()
    _session.withLock { $0 = session }
    updateState(.connected)
    _eventContinuation.yield(.connected)
  }

  // MARK: - Incoming message handling

  private func handleIncoming(_ message: XPCDictionary) {
    guard let envelope = try? RpcEnvelope.fromMessage(message) else {
      Log.rpc.error("failed to decode RpcEnvelope")
      return
    }
    guard !envelope.isHeader else { return }
    guard let frame = try? Frame.decode(from: envelope.payload) else {
      Log.rpc.error("failed to decode frame for call \(envelope.callId)")
      return
    }

    let callId = envelope.callId
    let reader = message.withUnsafeUnderlyingDictionary { xdict in
      XPCMessage.Reader(xdict)
    }

    if frame.isError {
      let rpcError =
        (try? RpcError.decode(from: frame.payload))
        .map { BebopRpcError(from: $0) }
        ?? BebopRpcError(code: .internal)
      let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
      switch call {
      case .unary(let continuation):
        continuation.resume(throwing: rpcError)
      case .stream(let continuation, _):
        continuation.finish(throwing: rpcError)
      case nil:
        break
      }
      return
    }

    if frame.isEndStream {
      let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
      switch call {
      case .unary(let continuation):
        continuation.resume(returning: Response(value: frame.payload, metadata: reader))
      case .stream(let continuation, let promise):
        if !frame.payload.isEmpty {
          continuation.yield((frame.payload, frame.cursor))
        }
        promise.resolve(reader)
        continuation.finish()
      case nil:
        break
      }
      return
    }

    // Mid-stream data frame
    let call = _state.withLock { $0.activeCalls[callId] }
    switch call {
    case .unary(let continuation):
      _ = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
      continuation.resume(
        throwing: BebopRpcError(code: .internal, detail: "unexpected data frame in unary response"))
    case .stream(let continuation, _):
      if !frame.payload.isEmpty {
        continuation.yield((frame.payload, frame.cursor))
      }
    case nil:
      break
    }
  }

  // MARK: - Connection loss

  private func handleConnectionLoss() {
    _session.withLock { $0 = nil }
    updateState(.failed(reason: "connection lost"))
    _eventContinuation.yield(.failed(reason: "connection lost"))
    cancelAllCalls(error: BebopRpcError(code: .unavailable, detail: "connection lost"))
    _eventContinuation.finish()
  }

  // MARK: - Private helpers

  private func nextCallId() -> UInt32 {
    _state.withLock {
      let id = $0.nextCallId
      $0.nextCallId &+= 1
      return id
    }
  }

  private func session() throws -> XPCSession {
    let state = _connectionState.withLock { $0 }
    switch state {
    case .disconnected:
      throw XPCError.cancelled
    case .failed(let reason):
      throw XPCError.connectionLost(reason: reason)
    default:
      break
    }
    guard let session = _session.withLock({ $0 }) else {
      throw XPCError.notConnected
    }
    return session
  }

  private func sendMessage(_ envelope: RpcEnvelope, via session: XPCSession) throws {
    let dict = envelope.toMessage()
    if envelope.isHeader, let prepare = XPCMessage.prepare {
      dict.withUnsafeUnderlyingDictionary { xdict in
        prepare(XPCMessage.Writer(xdict))
      }
    }
    try session.send(message: dict)
  }

  private func sendHeader(
    callId: UInt32,
    method: UInt32,
    context: RpcContext,
    via session: XPCSession
  ) throws {
    let header = CallHeader(
      methodId: method,
      deadline: context.deadline,
      metadata: context.metadata.isEmpty ? nil : context.metadata,
      cursor: context.cursor != 0 ? context.cursor : nil
    )
    let bytes = header.serializedData()
    let envelope = RpcEnvelope.header(callId: callId, payload: bytes)
    try sendMessage(envelope, via: session)
  }

  private func sendFrame(callId: UInt32, bytes: [UInt8], via session: XPCSession) throws {
    let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
    try sendMessage(envelope, via: session)
  }

  private func cancelCall(_ callId: UInt32) {
    let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
    switch call {
    case .unary(let continuation):
      continuation.resume(throwing: CancellationError())
    case .stream(let continuation, _):
      continuation.finish(throwing: CancellationError())
    case nil:
      break
    }
  }

  private func removeCall(_ callId: UInt32) {
    _state.withLock { $0.activeCalls[callId] = nil }
  }

  private func failCall(_ callId: UInt32, error: BebopRpcError) {
    let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
    switch call {
    case .unary(let continuation):
      continuation.resume(throwing: error)
    case .stream(let continuation, _):
      continuation.finish(throwing: error)
    case nil:
      break
    }
  }

  private func enforceDeadline(_ deadline: BebopTimestamp, forCall callId: UInt32) -> Task<
    Void, Never
  > {
    Task { [weak self] in
      guard let remaining = deadline.timeRemaining else {
        self?.failCall(callId, error: BebopRpcError(code: .deadlineExceeded))
        return
      }
      try? await Task.sleep(for: remaining)
      guard !Task.isCancelled else { return }
      self?.failCall(callId, error: BebopRpcError(code: .deadlineExceeded))
    }
  }

  private func cancelAllCalls(error: BebopRpcError) {
    let calls = _state.withLock {
      let all = $0.activeCalls
      $0.activeCalls.removeAll()
      return all
    }
    for call in calls.values {
      switch call {
      case .unary(let continuation):
        continuation.resume(throwing: error)
      case .stream(let continuation, _):
        continuation.finish(throwing: error)
      }
    }
  }

  private func updateState(_ newState: ConnectionState) {
    _connectionState.withLock { $0 = newState }
  }
}

struct MetadataPromise: Sendable {
  private let _stream: AsyncStream<XPCMessage.Reader>
  private let _continuation: AsyncStream<XPCMessage.Reader>.Continuation

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: XPCMessage.Reader.self)
    self._stream = stream
    self._continuation = continuation
  }

  func resolve(_ reader: XPCMessage.Reader) {
    _continuation.yield(reader)
    _continuation.finish()
  }

  var value: XPCMessage.Reader {
    get async {
      for await reader in _stream {
        return reader
      }
      return XPCMessage.Reader(xpc_dictionary_create_empty())
    }
  }
}
