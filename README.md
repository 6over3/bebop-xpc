# BebopXPC

Reference implementation of [Bebop RPC](https://github.com/6over3/bebop-next) using Apple XPC as the transport. Supports all four method types: unary, server streaming, client streaming, and duplex.

## Server

Build a router from generated handler protocols and start listening:

```swift
let builder = BebopRouterBuilder<XPCCallContext>()
builder.register(greeter: MyGreeter())
let router = builder.build()

let server = XPCBebopServer(router: router)

// Named Mach service (requires launchd plist with MachServices key)
try server.listen(machService: "com.example.greeter")

// Or anonymous, for in-process testing
let endpoint = try server.listenAnonymous()
```

## Client

Connect by Mach service name or anonymous endpoint:

```swift
let channel = try XPCBebopChannel(machService: "com.example.greeter")
let client = GreeterClient(channel: channel)

let reply = try await client.sayHello(name: "World")
```

The generated client has typed methods for each RPC. `XPCBebopChannel` conforms to `BebopChannel`, so any generated client works with it.

## Security

Peer validation via code-signing requirements:

```swift
let server = XPCBebopServer(router: router, security: .sameTeam())
let channel = try XPCBebopChannel(machService: name, security: .sameTeam())
```

Options: `.none`, `.sameTeam()`, `.platformBinary()`, `.hasEntitlement("com.example.access")`.

## Connection events

The channel exposes lifecycle events:

```swift
for await event in channel.events {
  switch event {
  case .connected: ...
  case .disconnected(let reason): ...
  case .failed(let reason): ...
  }
}
```

## Examples

See [`Examples/ExifService`](Examples/ExifService/) -- an EXIF metadata reader running as a launchd agent.
