import Foundation
import SwiftBebop
import XPC

/// Binary envelope for XPC messages. Layout: [kind: UInt8][callId: UInt32][payload...]
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

  // MARK: - XPCDictionary transport

  /// Pack envelope bytes into an XPCDictionary under the `"p"` key.
  func toMessage() -> XPCDictionary {
    let dict = XPCDictionary()
    let data = toData()
    dict.withUnsafeUnderlyingDictionary { xdict in
      data.withUnsafeBytes { buf in
        xpc_dictionary_set_data(xdict, "p", buf.baseAddress!, buf.count)
      }
    }
    return dict
  }

  /// Decode envelope bytes from the `"p"` key of an XPCDictionary.
  static func fromMessage(_ message: XPCDictionary) throws -> Self {
    var result: Result<Self, any Error>?

    message.withUnsafeUnderlyingDictionary { xdict in
      var length = 0
      guard let ptr = xpc_dictionary_get_data(xdict, "p", &length) else {
        result = .failure(BebopRpcError(code: .internal, detail: "missing payload in XPC message"))
        return
      }
      let data = Data(bytes: ptr, count: length)
      do {
        result = .success(try Self.decode(from: data))
      } catch {
        result = .failure(error)
      }
    }

    switch result {
    case .success(let envelope): return envelope
    case .failure(let error): throw error
    case nil: throw BebopRpcError(code: .internal, detail: "missing payload in XPC message")
    }
  }
}
