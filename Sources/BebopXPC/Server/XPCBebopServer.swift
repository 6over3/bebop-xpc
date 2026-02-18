import Foundation
import SwiftBebop
import Synchronization
import XPC

/// Server-side XPC listener that routes incoming BebopRPC calls through a BebopRouter.
public final class XPCBebopServer: @unchecked Sendable {

  private let router: BebopRouter<XPCCallContext>
  private let security: SecurityPolicy
  private let _listener = Mutex<XPCListener?>(nil)
  private let _connections = Mutex<[ConnectionBox]>([])

  public init(router: BebopRouter<XPCCallContext>, security: SecurityPolicy = .none) {
    self.router = router
    self.security = security
  }

  // MARK: - Public listen methods

  public func listen(service name: String) throws {
    let listener = try createListener(name: name)
    _listener.withLock { $0 = listener }
  }

  public func listen(machService name: String) throws {
    try listen(service: name)
  }

  public func listenAnonymous() throws -> XPCEndpoint {
    let listener = XPCListener(incomingSessionHandler: { [self] request in
      self.acceptConnection(request)
    })
    _listener.withLock { $0 = listener }
    return listener.endpoint
  }

  public func stop() {
    let listener = _listener.withLock { l -> XPCListener? in
      let current = l
      l = nil
      return current
    }
    listener?.cancel()

    let connections = _connections.withLock {
      let all = $0
      $0.removeAll()
      return all
    }
    for box in connections {
      let collectors = box.collectors.withLock {
        let all = $0
        $0.removeAll()
        return all
      }
      for collector in collectors.values {
        collector.cancel()
      }
      box.session.withLock { $0 }?.cancel(reason: "server stopped")
    }
  }

  // MARK: - Per-connection state

  private final class ConnectionBox: Sendable {
    let collectors = Mutex<[UInt32: FrameCollector]>([:])
    let session = Mutex<XPCSession?>(nil)
  }

  // MARK: - Connection acceptance

  private func acceptConnection(
    _ request: XPCListener.IncomingSessionRequest
  ) -> XPCListener.IncomingSessionRequest.Decision {
    let box = ConnectionBox()
    let router = self.router
    _connections.withLock { $0.append(box) }

    let (decision, session) = request.accept(
      incomingMessageHandler: { [self] (message: XPCDictionary) -> XPCDictionary? in
        guard let envelope = try? RpcEnvelope.fromMessage(message) else {
          Log.rpc.error("failed to decode RpcEnvelope")
          return nil
        }

        if envelope.isHeader {
          guard let header = try? CallHeader.decode(from: envelope.payload),
                let methodId = header.methodId else {
            Log.rpc.error("failed to decode CallHeader for call \(envelope.callId)")
            return nil
          }

          let reader = message.withUnsafeUnderlyingDictionary { xdict in
            XPCMessage.Reader(xdict)
          }

          let ctx = XPCCallContext(
            methodId: methodId,
            metadata: header.metadata ?? [:],
            deadline: header.deadline,
            message: reader
          )

          let collector = FrameCollector()
          box.collectors.withLock { $0[envelope.callId] = collector }
          let callId = envelope.callId

          Task {
            guard let session = box.session.withLock({ $0 }) else { return }
            await self.dispatchCall(
              callId: callId,
              header: header,
              ctx: ctx,
              collector: collector,
              session: session,
              box: box,
              router: router
            )
          }
        } else {
          guard let frame = try? Frame.decode(from: envelope.payload) else {
            Log.rpc.error("failed to decode frame for call \(envelope.callId)")
            return nil
          }
          box.collectors.withLock { $0[envelope.callId] }?.receive(frame)
        }
        return nil
      },
      cancellationHandler: { [self] _ in
        let allCollectors = box.collectors.withLock {
          let all = $0
          $0.removeAll()
          return all
        }
        for collector in allCollectors.values {
          collector.cancel()
        }
        self._connections.withLock { $0.removeAll(where: { $0 === box }) }
      }
    )

    box.session.withLock { $0 = session }
    do {
      try session.activate()
    } catch {
      Log.connection.error("failed to activate session: \(error)")
      box.session.withLock { $0 = nil }
    }
    return decision
  }

  // MARK: - Call dispatch

  private func dispatchCall(
    callId: UInt32,
    header: CallHeader,
    ctx: XPCCallContext,
    collector: FrameCollector,
    session: XPCSession,
    box: ConnectionBox,
    router: BebopRouter<XPCCallContext>
  ) async {
    defer { box.collectors.withLock { $0[callId] = nil } }

    if let deadline = header.deadline, deadline.isPast {
      try? sendError(
        callId: callId, to: session,
        error: BebopRpcError(code: .deadlineExceeded))
      return
    }

    await withTaskCancellationHandler {
      do {
        if let deadline = header.deadline {
          try await withDeadline(deadline) {
            try await self.executeMethod(
              callId: callId, methodId: ctx.methodId, ctx: ctx,
              collector: collector, session: session, router: router
            )
          }
        } else {
          try await executeMethod(
            callId: callId, methodId: ctx.methodId, ctx: ctx,
            collector: collector, session: session, router: router
          )
        }
      } catch let error as BebopRpcError {
        try? sendError(callId: callId, to: session, error: error)
      } catch is CancellationError {
        try? sendError(callId: callId, to: session, error: BebopRpcError(code: .cancelled))
      } catch {
        try? sendError(
          callId: callId, to: session,
          error: BebopRpcError(code: .internal, detail: String(describing: error))
        )
      }
    } onCancel: {
      ctx.cancel()
    }
  }

  private func executeMethod(
    callId: UInt32,
    methodId: UInt32,
    ctx: XPCCallContext,
    collector: FrameCollector,
    session: XPCSession,
    router: BebopRouter<XPCCallContext>
  ) async throws {
    if methodId <= 1 {
      let payload = try await readOnePayload(from: collector)
      let response = try await router.unary(methodId: methodId, payload: payload, ctx: ctx)
      try sendResponse(callId: callId, to: session, payload: response, ctx: ctx)
      return
    }

    guard let type = router.methodType(for: methodId) else {
      throw BebopRpcError(code: .notFound, detail: "method \(methodId)")
    }

    switch type {
    case .unary:
      let payload = try await readOnePayload(from: collector)
      let response = try await router.unary(methodId: methodId, payload: payload, ctx: ctx)
      try sendResponse(callId: callId, to: session, payload: response, ctx: ctx)

    case .serverStream:
      let payload = try await readOnePayload(from: collector)
      let stream = try await router.serverStream(methodId: methodId, payload: payload, ctx: ctx)
      for try await chunk in stream {
        try sendFrame(callId: callId, to: session, bytes: FrameWriter.data(chunk))
      }
      try sendEndOfStream(callId: callId, to: session, ctx: ctx)

    case .clientStream:
      let (send, finish) = try await router.clientStream(methodId: methodId, ctx: ctx)
      for try await payload in collector.payloads {
        try await send(payload)
      }
      let response = try await finish()
      try sendResponse(callId: callId, to: session, payload: response, ctx: ctx)

    case .duplexStream:
      let (send, finish, responses) = try await router.duplexStream(methodId: methodId, ctx: ctx)

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await payload in collector.payloads {
            try await send(payload)
          }
          try await finish()
        }
        group.addTask { [self] in
          for try await chunk in responses {
            try self.sendFrame(callId: callId, to: session, bytes: FrameWriter.data(chunk))
          }
          try self.sendEndOfStream(callId: callId, to: session, ctx: ctx)
        }
        try await group.waitForAll()
      }

    default:
      throw BebopRpcError(code: .unimplemented, detail: "unknown method type")
    }
  }

  // MARK: - Private helpers

  private func readOnePayload(from collector: FrameCollector) async throws -> [UInt8] {
    for try await payload in collector.payloads {
      return payload
    }
    return []
  }

  private func sendMessage(_ envelope: RpcEnvelope, to session: XPCSession) throws {
    try session.send(message: envelope.toMessage())
  }

  private func sendFrame(callId: UInt32, to session: XPCSession, bytes: [UInt8]) throws {
    let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
    try sendMessage(envelope, to: session)
  }

  private func sendError(callId: UInt32, to session: XPCSession, error: BebopRpcError) throws {
    let bytes = FrameWriter.error(error)
    try sendFrame(callId: callId, to: session, bytes: bytes)
  }

  private func sendResponse(
    callId: UInt32, to session: XPCSession, payload: [UInt8], ctx: XPCCallContext
  ) throws {
    let bytes = FrameWriter.endStream(payload)
    let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
    let dict = envelope.toMessage()
    applyResponseMetadata(dict, ctx: ctx)
    try session.send(message: dict)
  }

  private func sendEndOfStream(
    callId: UInt32, to session: XPCSession, ctx: XPCCallContext
  ) throws {
    let bytes = FrameWriter.endStream([])
    let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
    let dict = envelope.toMessage()
    applyResponseMetadata(dict, ctx: ctx)
    try session.send(message: dict)
  }

  private func applyResponseMetadata(_ dict: XPCDictionary, ctx: XPCCallContext) {
    let metadata = ctx.responseMetadata
    let prepareResponse = ctx.responsePreparer
    guard !metadata.isEmpty || prepareResponse != nil else { return }
    dict.withUnsafeUnderlyingDictionary { xdict in
      let writer = XPCMessage.Writer(xdict)
      for (key, value) in metadata {
        writer.setString("m.\(key)", value)
      }
      prepareResponse?(writer)
    }
  }

  private func createListener(name: String) throws -> XPCListener {
    if let requirement = security.makePeerRequirement() {
      return try XPCListener(
        service: name,
        requirement: requirement,
        incomingSessionHandler: { [self] request in
          self.acceptConnection(request)
        }
      )
    }
    return try XPCListener(
      service: name,
      incomingSessionHandler: { [self] request in
        self.acceptConnection(request)
      }
    )
  }
}
