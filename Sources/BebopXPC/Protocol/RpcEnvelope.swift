import Foundation
import SwiftBebop

/// Binary envelope for XPC messages. Layout: [kind: UInt8][callId: UInt32][payload...]
/// Sent as raw `Data` over XPC (maps to xpc_data_t).
struct RpcEnvelope: Sendable {
  static let headerSize = 5

  let callId: UInt32
  let kind: UInt8
  let payload: [UInt8]

  static func header(callId: UInt32, payload: [UInt8]) -> Self {
    Self(callId: callId, kind: 0, payload: payload)
  }

  static func frame(callId: UInt32, payload: [UInt8]) -> Self {
    Self(callId: callId, kind: 1, payload: payload)
  }

  var isHeader: Bool { kind == 0 }

  func toData() -> Data {
    var writer = BebopWriter(capacity: Self.headerSize + payload.count)
    writer.writeByte(kind)
    writer.writeUInt32(callId)
    writer.writeBytes(payload)
    return Data(writer.toBytes())
  }

  static func decode(from data: Data) throws -> Self {
    guard data.count >= headerSize else {
      throw BebopRpcError(code: .internal, detail: "envelope too short: \(data.count) bytes")
    }
    return try data.withUnsafeBytes { buf in
      var reader = BebopReader(data: UnsafeRawBufferPointer(buf))
      let kind = try reader.readByte()
      let callId = try reader.readUInt32()
      let payload = try reader.readBytes(data.count - headerSize)
      return Self(callId: callId, kind: kind, payload: payload)
    }
  }
}
