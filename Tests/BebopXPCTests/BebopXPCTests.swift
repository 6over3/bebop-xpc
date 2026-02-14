import Foundation
import SwiftBebop
import Testing

@testable import BebopXPC

@Suite struct ConnectionStateTests {
  @Test func isReadyOnlyForConnected() {
    #expect(ConnectionState.idle.isReady == false)
    #expect(ConnectionState.connecting.isReady == false)
    #expect(ConnectionState.connected.isReady == true)
    #expect(ConnectionState.disconnected(reason: "test").isReady == false)
    #expect(ConnectionState.failed(reason: "test").isReady == false)
  }

  @Test func equalitySameCases() {
    #expect(ConnectionState.idle == .idle)
    #expect(ConnectionState.connecting == .connecting)
    #expect(ConnectionState.connected == .connected)
  }

  @Test func equalityDifferentCases() {
    #expect(ConnectionState.idle != .connecting)
    #expect(ConnectionState.connected != .idle)
    #expect(ConnectionState.connecting != .connected)
  }

  @Test func equalityAssociatedValues() {
    #expect(ConnectionState.disconnected(reason: "timeout") == .disconnected(reason: "timeout"))
    #expect(ConnectionState.disconnected(reason: "timeout") != .disconnected(reason: "error"))
    #expect(ConnectionState.failed(reason: "auth") == .failed(reason: "auth"))
    #expect(ConnectionState.failed(reason: "auth") != .failed(reason: "network"))
    #expect(ConnectionState.disconnected(reason: "test") != .failed(reason: "test"))
  }
}

@Suite struct ConnectionEventTests {
  @Test func isConnectedForConnected() {
    #expect(ConnectionEvent.connected.isConnected == true)
  }

  @Test func isConnectedFalseForOthers() {
    #expect(ConnectionEvent.disconnected(reason: "test").isConnected == false)
    #expect(ConnectionEvent.failed(reason: "error").isConnected == false)
  }
}

@Suite struct XPCErrorTests {
  @Test func retryableErrors() {
    #expect(XPCError.connectionLost(reason: "test").isRetryable == true)
    #expect(XPCError.timeout(.seconds(5)).isRetryable == true)
  }

  @Test func nonRetryableErrors() {
    #expect(XPCError.notConnected.isRetryable == false)
    #expect(XPCError.securityViolation(reason: "test").isRetryable == false)
    #expect(XPCError.cancelled.isRetryable == false)
    #expect(XPCError.sessionCreationFailed("test").isRetryable == false)
  }

  @Test func errorDescriptionsNotNil() {
    #expect(XPCError.notConnected.errorDescription != nil)
    #expect(XPCError.connectionLost(reason: "test").errorDescription != nil)
    #expect(XPCError.securityViolation(reason: "test").errorDescription != nil)
    #expect(XPCError.timeout(.seconds(5)).errorDescription != nil)
    #expect(XPCError.cancelled.errorDescription != nil)
    #expect(XPCError.sessionCreationFailed("test").errorDescription != nil)
  }

  @Test func errorDescriptionContent() {
    #expect(XPCError.notConnected.errorDescription?.contains("Not connected") == true)
    #expect(
      XPCError.connectionLost(reason: "network").errorDescription?.contains("network") == true)
    #expect(
      XPCError.securityViolation(reason: "unauthorized").errorDescription?.contains("unauthorized")
        == true)
    #expect(XPCError.cancelled.errorDescription?.contains("cancelled") == true)
  }
}

@Suite struct RpcEnvelopeTests {
  @Test func headerCreatesWithKindZero() {
    let envelope = RpcEnvelope.header(callId: 42, payload: [1, 2, 3])
    #expect(envelope.callId == 42)
    #expect(envelope.kind == 0)
    #expect(envelope.isHeader == true)
    #expect(envelope.payload == [1, 2, 3])
  }

  @Test func frameCreatesWithKindOne() {
    let envelope = RpcEnvelope.frame(callId: 99, payload: [4, 5, 6])
    #expect(envelope.callId == 99)
    #expect(envelope.kind == 1)
    #expect(envelope.isHeader == false)
    #expect(envelope.payload == [4, 5, 6])
  }

  @Test func binaryRoundTrip() throws {
    let original = RpcEnvelope(callId: 123, kind: 2, payload: [7, 8, 9])
    let data = original.toData()
    let decoded = try RpcEnvelope.decode(from: data)

    #expect(decoded.callId == original.callId)
    #expect(decoded.kind == original.kind)
    #expect(decoded.payload == original.payload)
  }

  @Test func isHeaderDetectsKindZero() {
    let header = RpcEnvelope(callId: 1, kind: 0, payload: [])
    let frame = RpcEnvelope(callId: 1, kind: 1, payload: [])
    let other = RpcEnvelope(callId: 1, kind: 2, payload: [])

    #expect(header.isHeader == true)
    #expect(frame.isHeader == false)
    #expect(other.isHeader == false)
  }
}

@Suite struct XPCCallContextTests {
  @Test func initStoresValues() {
    let metadata = ["key": "value", "auth": "token"]
    let deadline = BebopTimestamp(seconds: 1_234_567_890, nanoseconds: 500_000_000)
    let context = XPCCallContext(methodId: 42, metadata: metadata, deadline: deadline)

    #expect(context.methodId == 42)
    #expect(context.requestMetadata == metadata)
    #expect(context.deadline == deadline)
  }

  @Test func isCancelledStartsFalse() {
    let context = XPCCallContext(methodId: 1, metadata: [:], deadline: nil)
    #expect(context.isCancelled == false)
  }

  @Test func cancelSetsCancelledTrue() {
    let context = XPCCallContext(methodId: 1, metadata: [:], deadline: nil)
    context.cancel()
    #expect(context.isCancelled == true)
  }

  @Test func setResponseMetadataStoresValues() {
    let context = XPCCallContext(methodId: 1, metadata: [:], deadline: nil)
    context.setResponseMetadata("status", "ok")
    context.setResponseMetadata("count", "5")

    let metadata = context.responseMetadata
    #expect(metadata["status"] == "ok")
    #expect(metadata["count"] == "5")
  }

  @Test func responseMetadataReturnsSetValues() {
    let context = XPCCallContext(methodId: 1, metadata: [:], deadline: nil)
    #expect(context.responseMetadata.isEmpty)

    context.setResponseMetadata("a", "1")
    #expect(context.responseMetadata == ["a": "1"])

    context.setResponseMetadata("b", "2")
    #expect(context.responseMetadata == ["a": "1", "b": "2"])
  }

  @Test func setResponseMetadataOverwritesExisting() {
    let context = XPCCallContext(methodId: 1, metadata: [:], deadline: nil)
    context.setResponseMetadata("key", "first")
    context.setResponseMetadata("key", "second")

    #expect(context.responseMetadata["key"] == "second")
  }
}

@Suite struct FrameCollectorTests {
  @Test func receiveDataFrameYieldsPayload() async throws {
    let collector = FrameCollector()
    let dataBytes = FrameWriter.data([1, 2, 3])
    let frame = try Frame.decode(from: dataBytes)

    collector.receive(frame)

    var payloads: [[UInt8]] = []
    for try await payload in collector.payloads {
      payloads.append(payload)
      break
    }

    #expect(payloads.count == 1)
    #expect(payloads[0] == [1, 2, 3])
  }

  @Test func receiveEndStreamFrameFinishes() async throws {
    let collector = FrameCollector()
    let endBytes = FrameWriter.endStream([4, 5])
    let frame = try Frame.decode(from: endBytes)

    collector.receive(frame)

    var payloads: [[UInt8]] = []
    for try await payload in collector.payloads {
      payloads.append(payload)
    }

    #expect(payloads.count == 1)
    #expect(payloads[0] == [4, 5])
  }

  @Test func receiveMultipleDataThenEndStream() async throws {
    let collector = FrameCollector()

    let data1Bytes = FrameWriter.data([1, 2])
    let frame1 = try Frame.decode(from: data1Bytes)

    let data2Bytes = FrameWriter.data([3, 4])
    let frame2 = try Frame.decode(from: data2Bytes)

    let endBytes = FrameWriter.endStream([5])
    let endFrame = try Frame.decode(from: endBytes)

    collector.receive(frame1)
    collector.receive(frame2)
    collector.receive(endFrame)

    var payloads: [[UInt8]] = []
    for try await payload in collector.payloads {
      payloads.append(payload)
    }

    #expect(payloads.count == 3)
    #expect(payloads[0] == [1, 2])
    #expect(payloads[1] == [3, 4])
    #expect(payloads[2] == [5])
  }

  @Test func cancelThrowsCancellationError() async throws {
    let collector = FrameCollector()
    collector.cancel()

    var threwCancellation = false
    do {
      for try await _ in collector.payloads {
        Issue.record("Should not yield any values")
      }
    } catch is CancellationError {
      threwCancellation = true
    }

    #expect(threwCancellation)
  }

  @Test func receiveErrorFrameThrows() async throws {
    let collector = FrameCollector()
    let errBytes = FrameWriter.error(BebopRpcError(code: .internal))
    let frame = try Frame.decode(from: errBytes)

    collector.receive(frame)

    var threwError = false
    do {
      for try await _ in collector.payloads {
        Issue.record("Should not yield any values")
      }
    } catch {
      threwError = true
    }

    #expect(threwError)
  }

  @Test func emptyPayloadNotYielded() async throws {
    let collector = FrameCollector()

    let emptyData = FrameWriter.data([])
    let emptyFrame = try Frame.decode(from: emptyData)

    let endBytes = FrameWriter.endStream([])
    let endFrame = try Frame.decode(from: endBytes)

    collector.receive(emptyFrame)
    collector.receive(endFrame)

    var payloads: [[UInt8]] = []
    for try await payload in collector.payloads {
      payloads.append(payload)
    }

    #expect(payloads.isEmpty)
  }
}
