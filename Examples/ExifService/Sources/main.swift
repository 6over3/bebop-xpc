import BebopXPC
import Exif
import Foundation
import SwiftBebop

let serviceName = "com.bebop.example.exif"

struct ExifHandler: ExifServiceHandler {
  let exif = try! Exif()

  func read(_ request: ReadRequest, context: some CallContext) async throws -> ReadResponse {
    do {
      let url = URL(fileURLWithPath: request.path)
      let json = try await exif.read(from: url)
      return ReadResponse(path: request.path, json: json)
    } catch {
      return ReadResponse(path: request.path, error: "\(error)")
    }
  }
}

func runServer() throws {
  let builder = BebopRouterBuilder<XPCCallContext>()
  builder.register(exifService: ExifHandler())
  let server = XPCBebopServer(router: builder.build())
  try server.listen(machService: serviceName)
  print("ExifService listening on \(serviceName)")
  dispatchMain()
}

func formatDuration(_ seconds: Double) -> String {
  if seconds < 0.001 {
    return String(format: "%.0fus", seconds * 1_000_000)
  } else if seconds < 1 {
    return String(format: "%.1fms", seconds * 1000)
  } else {
    return String(format: "%.2fs", seconds)
  }
}

func formatBytes(_ count: Int) -> String {
  if count < 1024 {
    return "\(count) B"
  } else if count < 1024 * 1024 {
    return String(format: "%.1f KB", Double(count) / 1024)
  } else {
    return String(format: "%.1f MB", Double(count) / (1024 * 1024))
  }
}

func runClient(paths: [String]) async throws {
  let totalStart = ContinuousClock.now

  let channel = try XPCBebopChannel(machService: serviceName)
  let client = ExifServiceClient(channel: channel)
  defer { channel.cancel() }

  let connectTime = totalStart.duration(to: .now)

  print("\u{1B}[1mExifService\u{1B}[0m  \(paths.count) file(s)")
  print("  connect  \(formatDuration(connectTime.seconds))")
  print()

  var succeeded = 0
  var failed = 0
  var totalBytes = 0

  for path in paths {
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    totalBytes += fileSize
    let filename = (path as NSString).lastPathComponent

    let rpcStart = ContinuousClock.now
    let response = try await client.read(ReadRequest(path: path))
    let rpcTime = rpcStart.duration(to: .now)

    if let json = response.json {
      succeeded += 1
      print(
        "  \u{1B}[32m\u{2713}\u{1B}[0m \u{1B}[1m\(filename)\u{1B}[0m  \(formatBytes(fileSize))  \(formatDuration(rpcTime.seconds))"
      )
      if let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(
          withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
        let str = String(data: pretty, encoding: .utf8)
      {
        for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
          print("    \(line)")
        }
      } else {
        print("    \(json)")
      }
      print()
    } else if let error = response.error {
      failed += 1
      print(
        "  \u{1B}[31m\u{2717}\u{1B}[0m \u{1B}[1m\(filename)\u{1B}[0m  \(formatBytes(fileSize))  \(formatDuration(rpcTime.seconds))"
      )
      print("    \(error)")
      print()
    }
  }

  let totalTime = totalStart.duration(to: .now)

  print("\u{1B}[2m\(String(repeating: "\u{2500}", count: 40))\u{1B}[0m")
  print("  total    \(formatDuration(totalTime.seconds))  \u{2502}  \(formatBytes(totalBytes))")
  if failed > 0 {
    print("  result   \u{1B}[32m\(succeeded) ok\u{1B}[0m  \u{1B}[31m\(failed) failed\u{1B}[0m")
  } else {
    print("  result   \u{1B}[32m\(succeeded) ok\u{1B}[0m")
  }
}

extension Duration {
  var seconds: Double {
    let (s, att) = components
    return Double(s) + Double(att) / 1_000_000_000_000_000_000
  }
}

let args = Array(CommandLine.arguments.dropFirst())

guard let first = args.first else {
  print("Usage:")
  print("  ExifServiceExample --server")
  print("  ExifServiceExample <image-path> [image-path ...]")
  exit(1)
}

if first == "--server" {
  try runServer()
} else {
  try await runClient(paths: args)
}
