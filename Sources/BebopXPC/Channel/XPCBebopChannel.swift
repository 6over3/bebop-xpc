import Foundation
import SwiftBebop
import Synchronization
import XPC

/// BebopChannel implementation over Apple XPC.
public final class XPCBebopChannel: BebopChannel, @unchecked Sendable {

  // MARK: - Internal types

  private enum ActiveCall {
    case unary(CheckedContinuation<[UInt8], any Error>)
    case unaryWaitingTrailer([UInt8], CheckedContinuation<[UInt8], any Error>)
    case stream(AsyncThrowingStream<[UInt8], any Error>.Continuation)
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
    options: CallOptions
  ) async throws -> [UInt8] {
    if let deadline = options.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let deadlineTask = options.deadline.map { enforceDeadline($0, forCall: callId) }
    return try await withTaskCancellationHandler {
      defer { deadlineTask?.cancel() }
      return try await withCheckedThrowingContinuation { continuation in
        _state.withLock { $0.activeCalls[callId] = .unary(continuation) }
        do {
          let session = try self.session()
          try sendHeader(callId: callId, method: method, options: options, via: session)
          try sendFrame(callId: callId, bytes: FrameWriter.endStream(request), via: session)
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
    options: CallOptions
  ) async throws -> AsyncThrowingStream<[UInt8], Error> {
    if let deadline = options.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
    _state.withLock { $0.activeCalls[callId] = .stream(continuation) }
    let deadlineTask = options.deadline.map { enforceDeadline($0, forCall: callId) }
    continuation.onTermination = { @Sendable _ in
      deadlineTask?.cancel()
      self.removeCall(callId)
    }
    do {
      let session = try self.session()
      try sendHeader(callId: callId, method: method, options: options, via: session)
      try sendFrame(callId: callId, bytes: FrameWriter.endStream(request), via: session)
    } catch {
      deadlineTask?.cancel()
      if _state.withLock({ $0.activeCalls.removeValue(forKey: callId) }) != nil {
        continuation.finish(throwing: error)
      }
    }
    return stream
  }

  public func clientStream(
    method: UInt32,
    options: CallOptions
  ) async throws -> (
    send: @Sendable ([UInt8]) async throws -> Void,
    finish: @Sendable () async throws -> [UInt8]
  ) {
    if let deadline = options.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let session = try self.session()
    try sendHeader(callId: callId, method: method, options: options, via: session)

    let send: @Sendable ([UInt8]) async throws -> Void = { [weak self] payload in
      guard let self else { throw XPCError.notConnected }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: FrameWriter.data(payload), via: s)
    }

    let finish: @Sendable () async throws -> [UInt8] = { [weak self] in
      guard let self else { throw XPCError.notConnected }
      if let deadline = options.deadline, deadline.isPast {
        throw BebopRpcError(code: .deadlineExceeded)
      }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: FrameWriter.endStream([]), via: s)
      let deadlineTask = options.deadline.map { self.enforceDeadline($0, forCall: callId) }
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
    options: CallOptions
  ) async throws -> (
    send: @Sendable ([UInt8]) async throws -> Void,
    finish: @Sendable () async throws -> Void,
    responses: AsyncThrowingStream<[UInt8], Error>
  ) {
    if let deadline = options.deadline, deadline.isPast {
      throw BebopRpcError(code: .deadlineExceeded)
    }
    let callId = nextCallId()
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
    _state.withLock { $0.activeCalls[callId] = .stream(continuation) }
    let deadlineTask = options.deadline.map { enforceDeadline($0, forCall: callId) }
    continuation.onTermination = { @Sendable _ in
      deadlineTask?.cancel()
      self.removeCall(callId)
    }

    do {
      let session = try self.session()
      try sendHeader(callId: callId, method: method, options: options, via: session)
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
      try self.sendFrame(callId: callId, bytes: FrameWriter.data(payload), via: s)
    }

    let finish: @Sendable () async throws -> Void = { [weak self] in
      guard let self else { throw XPCError.notConnected }
      let s = try self.session()
      try self.sendFrame(callId: callId, bytes: FrameWriter.endStream([]), via: s)
    }

    return (send: send, finish: finish, responses: stream)
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

  private func makeIncomingHandler() -> @Sendable (XPCReceivedMessage) -> (any Encodable)? {
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

  private func handleIncoming(_ message: XPCReceivedMessage) {
    guard let data = try? message.decode(as: Data.self),
      let envelope = try? RpcEnvelope.decode(from: data)
    else {
      Log.rpc.error("failed to decode RpcEnvelope")
      return
    }
    guard !envelope.isHeader else { return }
    guard let frame = try? Frame.decode(from: envelope.payload) else {
      Log.rpc.error("failed to decode frame for call \(envelope.callId)")
      return
    }

    let callId = envelope.callId

    if frame.isError {
      let rpcError =
        (try? RpcError.decode(from: frame.payload))
        .map { BebopRpcError(from: $0) }
        ?? BebopRpcError(code: .internal)
      let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
      switch call {
      case .unary(let continuation):
        continuation.resume(throwing: rpcError)
      case .unaryWaitingTrailer(_, let continuation):
        continuation.resume(throwing: rpcError)
      case .stream(let continuation):
        continuation.finish(throwing: rpcError)
      case nil:
        break
      }
      return
    }

    if frame.isTrailer {
      let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
      switch call {
      case .unaryWaitingTrailer(let buffered, let continuation):
        continuation.resume(returning: buffered)
      case .unary(let continuation):
        continuation.resume(returning: [])
      case .stream(let continuation):
        continuation.finish()
      case nil:
        break
      }
      return
    }

    let call = _state.withLock { state -> ActiveCall? in
      guard let call = state.activeCalls[callId] else { return nil }
      switch call {
      case .unary(let continuation):
        if frame.isEndStream {
          state.activeCalls.removeValue(forKey: callId)
        } else {
          state.activeCalls[callId] = .unaryWaitingTrailer(frame.payload, continuation)
        }
      case .unaryWaitingTrailer:
        state.activeCalls.removeValue(forKey: callId)
      case .stream:
        if frame.isEndStream {
          state.activeCalls.removeValue(forKey: callId)
        }
      }
      return call
    }
    switch call {
    case .unary(let continuation):
      if frame.isEndStream {
        continuation.resume(returning: frame.payload)
      }
    case .unaryWaitingTrailer(_, let continuation):
      continuation.resume(
        throwing: BebopRpcError(code: .internal, detail: "multiple data frames in unary response"))
    case .stream(let continuation):
      if !frame.payload.isEmpty {
        continuation.yield(frame.payload)
      }
      if frame.isEndStream {
        continuation.finish()
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

  private func sendHeader(
    callId: UInt32,
    method: UInt32,
    options: CallOptions,
    via session: XPCSession
  ) throws {
    let header = CallHeader(
      methodId: method,
      deadline: options.deadline,
      metadata: options.metadata.isEmpty ? nil : options.metadata
    )
    let bytes = header.serializedData()
    let envelope = RpcEnvelope.header(callId: callId, payload: bytes)
    try session.send(envelope.toData())
  }

  private func sendFrame(callId: UInt32, bytes: [UInt8], via session: XPCSession) throws {
    let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
    try session.send(envelope.toData())
  }

  private func cancelCall(_ callId: UInt32) {
    let call = _state.withLock { $0.activeCalls.removeValue(forKey: callId) }
    switch call {
    case .unary(let continuation):
      continuation.resume(throwing: CancellationError())
    case .unaryWaitingTrailer(_, let continuation):
      continuation.resume(throwing: CancellationError())
    case .stream(let continuation):
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
    case .unaryWaitingTrailer(_, let continuation):
      continuation.resume(throwing: error)
    case .stream(let continuation):
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
      case .unaryWaitingTrailer(_, let continuation):
        continuation.resume(throwing: error)
      case .stream(let continuation):
        continuation.finish(throwing: error)
      }
    }
  }

  private func updateState(_ newState: ConnectionState) {
    _connectionState.withLock { $0 = newState }
  }
}
