import Foundation
import SwiftBebop
import Synchronization
import XPC

/// Server-side XPC listener that routes incoming BebopRPC calls through a BebopRouter.
public final class XPCBebopServer: @unchecked Sendable {

  private let router: BebopRouter
  private let security: SecurityPolicy
  private let _listener = Mutex<XPCListener?>(nil)
  private let _connections = Mutex<[ConnectionBox]>([])
  private let _serviceName = Mutex<String?>(nil)

  public init(router: BebopRouter, security: SecurityPolicy = .none) {
    self.router = router
    self.security = security
  }

  // MARK: - Public listen methods

  public func listen(service name: String) throws {
    _serviceName.withLock { $0 = name }
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
    let localAddress: String?
    let _peerInfo = Mutex<PeerInfo?>(nil)
    let collectors = Mutex<[UInt32: FrameCollector]>([:])
    let session = Mutex<XPCSession?>(nil)

    init(localAddress: String?) {
      self.localAddress = localAddress
    }

    func peerInfo(from message: XPCDictionary) -> PeerInfo {
      if let existing = _peerInfo.withLock({ $0 }) {
        return existing
      }
      let info = message.withUnsafeUnderlyingDictionary { xdict -> PeerInfo in
        guard let conn = xpc_dictionary_get_remote_connection(xdict) else {
          return PeerInfo(localAddress: localAddress)
        }
        let pid = xpc_connection_get_pid(conn)
        let uid = xpc_connection_get_euid(conn)
        let gid = xpc_connection_get_egid(conn)
        return PeerInfo(
          remoteAddress: "pid:\(pid)",
          localAddress: localAddress,
          authInfo: XPCAuthInfo(pid: pid, uid: uid, gid: gid)
        )
      }
      _peerInfo.withLock { $0 = info }
      return info
    }
  }

  // MARK: - Connection acceptance

  private func acceptConnection(
    _ request: XPCListener.IncomingSessionRequest
  ) -> XPCListener.IncomingSessionRequest.Decision {
    let box = ConnectionBox(localAddress: _serviceName.withLock { $0 })
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

          let ctx = RpcContext(
            methodId: methodId,
            metadata: header.metadata ?? [:],
            deadline: header.deadline,
            cursor: header.cursor ?? 0
          )
          ctx[XPCMessageKey.self] = reader
          ctx[PeerInfoKey.self] = box.peerInfo(from: message)

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
    ctx: RpcContext,
    collector: FrameCollector,
    session: XPCSession,
    box: ConnectionBox,
    router: BebopRouter
  ) async {
    defer { box.collectors.withLock { $0[callId] = nil } }

    let writer = makeFrameWriter(callId: callId, session: session, ctx: ctx)

    if let deadline = header.deadline, deadline.isPast {
      try? await writer.error(BebopRpcError(code: .deadlineExceeded))
      return
    }

    await withTaskCancellationHandler {
      do {
        if let deadline = header.deadline {
          try await withDeadline(deadline) {
            try await self.executeMethod(
              ctx: ctx, collector: collector, writer: writer, router: router
            )
          }
        } else {
          try await executeMethod(
            ctx: ctx, collector: collector, writer: writer, router: router
          )
        }
      } catch let error as BebopRpcError {
        try? await writer.error(error)
      } catch is CancellationError {
        try? await writer.error(BebopRpcError(code: .cancelled))
      } catch {
        try? await writer.error(
          BebopRpcError(code: .internal, detail: String(describing: error)))
      }
    } onCancel: {
      ctx.cancel()
    }
  }

  private func executeMethod(
    ctx: RpcContext,
    collector: FrameCollector,
    writer: FrameWriter,
    router: BebopRouter
  ) async throws {
    let methodId = ctx.methodId

    // Reserved unary methods: discovery (0), batch (1), dispatch (2), cancel (4)
    switch methodId {
    case BebopReservedMethod.discovery, BebopReservedMethod.batch,
         BebopReservedMethod.dispatch, BebopReservedMethod.cancel:
      let payload = try await readOnePayload(from: collector)
      let response = try await router.unary(methodId: methodId, payload: payload, ctx: ctx)
      try await writer.writeUnary(response, metadata: ctx.responseMetadata)
      return
    case BebopReservedMethod.resolve:
      let payload = try await readOnePayload(from: collector)
      let stream = try await router.serverStream(methodId: methodId, payload: payload, ctx: ctx)
      try await writer.drainServerStream(stream, metadata: { ctx.responseMetadata })
      return
    default:
      break
    }

    guard let type = router.methodType(for: methodId) else {
      throw BebopRpcError(code: .notFound, detail: "method \(methodId)")
    }

    switch type {
    case .unary:
      let payload = try await readOnePayload(from: collector)
      let response = try await router.unary(methodId: methodId, payload: payload, ctx: ctx)
      try await writer.writeUnary(response, metadata: ctx.responseMetadata)

    case .serverStream:
      let payload = try await readOnePayload(from: collector)
      let stream = try await router.serverStream(methodId: methodId, payload: payload, ctx: ctx)
      try await writer.drainServerStream(stream, metadata: { ctx.responseMetadata })

    case .clientStream:
      let (send, finish) = try await router.clientStream(methodId: methodId, ctx: ctx)
      for try await payload in collector.payloads {
        try await send(payload)
      }
      let response = try await finish()
      try await writer.writeUnary(response, metadata: ctx.responseMetadata)

    case .duplexStream:
      let (send, finish, responses) = try await router.duplexStream(methodId: methodId, ctx: ctx)

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await payload in collector.payloads {
            try await send(payload)
          }
          try await finish()
        }
        group.addTask {
          try await writer.drainServerStream(responses, metadata: { ctx.responseMetadata })
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

  /// Build a FrameWriter that sends via XPC and applies response metadata on final frames.
  private func makeFrameWriter(
    callId: UInt32, session: XPCSession, ctx: RpcContext
  ) -> FrameWriter {
    FrameWriter { bytes, flags in
      let envelope = RpcEnvelope.frame(callId: callId, payload: bytes)
      if flags.contains(.endStream) {
        let dict = envelope.toMessage()
        self.applyResponseMetadata(dict, ctx: ctx)
        try session.send(message: dict)
      } else {
        try session.send(message: envelope.toMessage())
      }
    }
  }

  private func applyResponseMetadata(_ dict: XPCDictionary, ctx: RpcContext) {
    let metadata = ctx.responseMetadata
    let prepareResponse = ctx[XPCResponsePreparerKey.self]
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
