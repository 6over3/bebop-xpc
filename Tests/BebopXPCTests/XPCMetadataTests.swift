import Foundation
import SwiftBebop
import Testing
import XPC

@testable import BebopXPC

struct MetadataGreeter: GreeterHandler {
  func sayHello(
    _ request: HelloRequest, context: RpcContext
  ) async throws -> HelloReply {
    let reader = context[XPCMessageKey.self]

    // Read custom string from inbound XPC dict
    let custom = reader?.string("custom") ?? "missing"

    // Read fd from inbound XPC dict, write a marker byte, close it
    if let fd = reader?.fileDescriptor("pipe") {
      let byte: UInt8 = 0xAB
      _ = withUnsafePointer(to: byte) { Darwin.write(fd, $0, 1) }
      Darwin.close(fd)
    }

    // Attach custom data to the response XPC dict
    context[XPCResponsePreparerKey.self] = { writer in
      writer.setString("echo", custom)
      writer.setInt64("code", 42)
    }

    return HelloReply(greeting: "Hello, \(request.name)!")
  }

  func streamTicks(
    _ request: TickRequest, context: RpcContext
  ) async throws -> AsyncThrowingStream<TickReply, Error> {
    context[XPCResponsePreparerKey.self] = { writer in
      writer.setUInt64("total", UInt64(request.count))
    }
    return AsyncThrowingStream { c in
      for i: UInt32 in 0..<request.count {
        c.yield(TickReply(seq: i, timestamp: "t\(i)"))
      }
      c.finish()
    }
  }

  func uploadLogs(
    _ requests: AsyncThrowingStream<LogEntry, Error>,
    context: RpcContext
  ) async throws -> LogSummary {
    var count: UInt32 = 0
    for try await _ in requests { count += 1 }
    return LogSummary(totalLines: count, preview: "")
  }

  func chat(
    _ requests: AsyncThrowingStream<HelloRequest, Error>,
    context: RpcContext
  ) async throws -> AsyncThrowingStream<HelloReply, Error> {
    fatalError()
  }
}

func makeMetadataPair() throws -> (server: XPCBebopServer, client: GreeterClient<XPCBebopChannel>) {
  let builder = BebopRouterBuilder()
  builder.register(greeter: MetadataGreeter())
  let server = XPCBebopServer(router: builder.build())
  let endpoint = try server.listenAnonymous()
  let channel = try XPCBebopChannel(endpoint: endpoint)
  return (server, GreeterClient(channel: channel))
}

@Suite("XPC Metadata") struct XPCMetadataTests {

  @Test(.timeLimit(.minutes(1)))
  func clientSendsCustomXPCData_serverReadsIt() async throws {
    let (server, client) = try makeMetadataPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let reply = try await XPCMessage.$prepare.withValue({ writer in
      writer.setString("custom", "hello-from-client")
    }) {
      try await client.sayHello(name: "test")
    }

    // Server echoed the custom string back via XPCResponsePreparerKey
    #expect(reply.metadata.string("echo") == "hello-from-client")
    #expect(reply.metadata.int64("code") == 42)
    #expect(reply.value.greeting == "Hello, test!")
  }

  @Test(.timeLimit(.minutes(1)))
  func fileDescriptorRoundTrip() async throws {
    let (server, client) = try makeMetadataPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
      throw BebopRpcError(code: .internal, detail: "pipe() failed")
    }
    let readEnd = fds[0]
    let writeEnd = fds[1]
    defer { close(readEnd) }

    let reply = try await XPCMessage.$prepare.withValue({ writer in
      writer.setFileDescriptor("pipe", writeEnd)
    }) {
      try await client.sayHello(name: "fd-test")
    }
    close(writeEnd)

    _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)
    var buf: UInt8 = 0
    let n = Darwin.read(readEnd, &buf, 1)
    #expect(n == 1)
    #expect(buf == 0xAB)
    #expect(reply.value.greeting == "Hello, fd-test!")
  }

  @Test(.timeLimit(.minutes(1)))
  func serverStreamTrailingMetadata() async throws {
    let (server, client) = try makeMetadataPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let stream = try await client.streamTicks(count: 3)
    var count = 0
    for try await _ in stream { count += 1 }
    #expect(count == 3)

    let trailing = await stream.metadata
    #expect(trailing.uint64("total") == 3)
  }
}
