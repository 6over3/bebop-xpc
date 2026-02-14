import SwiftBebop

/// Buffer incoming frames for an active server-side call.
final class FrameCollector: Sendable {
  let payloads: AsyncThrowingStream<[UInt8], Error>
  private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

  init() {
    let (s, c) = AsyncThrowingStream.makeStream(of: [UInt8].self)
    payloads = s
    continuation = c
  }

  func receive(_ frame: Frame) {
    if frame.isError {
      let err =
        (try? RpcError.decode(from: frame.payload))
        .map { BebopRpcError(from: $0) }
        ?? BebopRpcError(code: .internal)
      continuation.finish(throwing: err)
      return
    }
    if !frame.payload.isEmpty {
      continuation.yield(frame.payload)
    }
    if frame.isEndStream {
      continuation.finish()
    }
  }

  func cancel() {
    continuation.finish(throwing: CancellationError())
  }
}
