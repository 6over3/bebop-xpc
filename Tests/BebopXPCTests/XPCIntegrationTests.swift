import SwiftBebop
import Testing
import XPC

@testable import BebopXPC

// MARK: - Handler implementation

struct TestGreeter: GreeterHandler {
  func sayHello(
    _ request: HelloRequest, context: RpcContext
  ) async throws -> HelloReply {
    HelloReply(greeting: "Hello, \(request.name)!")
  }

  func streamTicks(
    _ request: TickRequest, context: RpcContext
  ) async throws -> AsyncThrowingStream<TickReply, Error> {
    AsyncThrowingStream { c in
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
    var lines: [String] = []
    for try await entry in requests {
      lines.append(entry.line)
    }
    return LogSummary(totalLines: UInt32(lines.count), preview: lines.first ?? "")
  }

  func chat(
    _ requests: AsyncThrowingStream<HelloRequest, Error>,
    context: RpcContext
  ) async throws -> AsyncThrowingStream<HelloReply, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: HelloReply.self)
    Task {
      do {
        for try await req in requests {
          continuation.yield(HelloReply(greeting: "Hi, \(req.name)!"))
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    return stream
  }
}

// MARK: - Test infrastructure

func makeGreeterPair() throws -> (server: XPCBebopServer, client: GreeterClient<XPCBebopChannel>) {
  let builder = BebopRouterBuilder()
  builder.register(greeter: TestGreeter())
  let router = builder.build()

  let server = XPCBebopServer(router: router)
  let endpoint = try server.listenAnonymous()
  let channel = try XPCBebopChannel(endpoint: endpoint)
  return (server, GreeterClient(channel: channel))
}

// MARK: - Integration tests

@Suite("XPC Greeter") struct XPCIntegrationTests {

  @Test(.timeLimit(.minutes(1))) func sayHello() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let reply = try await client.sayHello(name: "World")
    #expect(reply.value.greeting == "Hello, World!")
  }

  @Test(.timeLimit(.minutes(1))) func streamTicks() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let stream = try await client.streamTicks(count: 4)
    var seqs: [UInt32] = []
    for try await tick in stream {
      seqs.append(tick.seq)
    }

    #expect(seqs == [0, 1, 2, 3])
  }

  @Test(.timeLimit(.minutes(1))) func uploadLogs() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let summary = try await client.uploadLogs { send in
      try await send(LogEntry(line: "first line"))
      try await send(LogEntry(line: "second line"))
      try await send(LogEntry(line: "third line"))
    }.value
    #expect(summary.totalLines == 3)
    #expect(summary.preview == "first line")
  }

  @Test(.timeLimit(.minutes(1))) func chat() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    try await client.chat { send, finish, responses in
      try await send(HelloRequest(name: "Alice"))
      try await send(HelloRequest(name: "Bob"))
      try await finish()

      var greetings: [String] = []
      for try await reply in responses {
        greetings.append(reply.greeting)
      }

      #expect(greetings == ["Hi, Alice!", "Hi, Bob!"])
    }
  }

  @Test(.timeLimit(.minutes(1))) func unknownMethodReturnsNotFound() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    do {
      _ = try await client.channel.unary(
        method: 0xDEAD_BEEF,
        request: HelloRequest(name: "x").serializedData(),
        context: RpcContext()
      )
      Issue.record("Expected error for unknown method")
    } catch let error as BebopRpcError {
      #expect(error.code == .notFound)
    }
  }

  @Test(.timeLimit(.minutes(1))) func channelCancelPreventsCall() async throws {
    let (server, client) = try makeGreeterPair()
    defer { server.stop() }

    client.channel.cancel()

    do {
      _ = try await client.sayHello(name: "nobody")
      Issue.record("Expected error after cancel")
    } catch {
      // Expected — channel is closed
    }
  }

  @Test(.timeLimit(.minutes(1))) func serverStopCausesClientError() async throws {
    let (server, client) = try makeGreeterPair()
    defer { client.channel.cancel() }

    server.stop()

    do {
      _ = try await client.sayHello(name: "ghost")
      Issue.record("Expected error after server stop")
    } catch {
      // Expected — server is gone
    }
  }
}
