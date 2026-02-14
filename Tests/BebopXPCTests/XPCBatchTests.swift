import SwiftBebop
import Testing
import XPC

@testable import BebopXPC

@Suite("XPC Batch") struct XPCBatchTests {

  @Test(.timeLimit(.minutes(1))) func singleUnary() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    let ref = batch.greeter.sayHello(name: "Batch")
    let results = try await batch.execute()
    let reply = try results[ref]
    #expect(reply.greeting == "Hello, Batch!")
  }

  @Test(.timeLimit(.minutes(1))) func multipleUnary() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    let r1 = batch.greeter.sayHello(name: "Alice")
    let r2 = batch.greeter.sayHello(name: "Bob")
    let r3 = batch.greeter.sayHello(name: "Charlie")
    let results = try await batch.execute()

    #expect(try results[r1].greeting == "Hello, Alice!")
    #expect(try results[r2].greeting == "Hello, Bob!")
    #expect(try results[r3].greeting == "Hello, Charlie!")
  }

  @Test(.timeLimit(.minutes(1))) func serverStreamInBatch() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    let ref = batch.greeter.streamTicks(count: 3)
    let results = try await batch.execute()
    let ticks = try results[ref]

    #expect(ticks.count == 3)
    #expect(ticks.map(\.seq) == [0, 1, 2])
  }

  @Test(.timeLimit(.minutes(1))) func mixedUnaryAndStream() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    let helloRef = batch.greeter.sayHello(name: "Mix")
    let tickRef = batch.greeter.streamTicks(count: 2)
    let results = try await batch.execute()

    #expect(try results[helloRef].greeting == "Hello, Mix!")
    let ticks = try results[tickRef]
    #expect(ticks.count == 2)
    #expect(ticks[0].seq == 0)
    #expect(ticks[1].seq == 1)
  }

  @Test(.timeLimit(.minutes(1))) func unknownMethodInBatchReturnsPerCallError() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    let good = batch.greeter.sayHello(name: "OK")
    let bad: CallRef<HelloReply> = batch.addUnary(
      methodId: 0xDEAD_BEEF,
      request: HelloRequest(name: "bad")
    )
    let results = try await batch.execute()

    #expect(try results[good].greeting == "Hello, OK!")
    #expect(throws: BebopRpcError.self) {
      _ = try results[bad]
    }
  }

  @Test(.timeLimit(.minutes(1))) func emptyBatch() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch()
    _ = try await batch.execute()
  }

  @Test(.timeLimit(.minutes(1))) func batchWithMetadata() async throws {
    let (server, client) = try makeGreeterPair()
    defer {
      client.channel.cancel()
      server.stop()
    }

    let batch = client.channel.makeBatch(metadata: ["trace-id": "abc123"])
    let ref = batch.greeter.sayHello(name: "Meta")
    let results = try await batch.execute()
    #expect(try results[ref].greeting == "Hello, Meta!")
  }
}
