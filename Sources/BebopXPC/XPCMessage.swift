import Foundation
import XPC

/// Per-call XPC message customization and typed access to the underlying dictionary.
///
///     try await XPCMessage.$prepare.withValue({ writer in
///         writer.setFileDescriptor("fd", fd)
///     }) {
///         try await client.readMetadata(path: path)
///     }
public enum XPCMessage {
  @TaskLocal public static var prepare: (@Sendable (Writer) -> Void)?

  public struct Writer: @unchecked Sendable {
    let dict: xpc_object_t

    init(_ dict: xpc_object_t) { self.dict = dict }

    public func setFileDescriptor(_ key: String, _ fd: Int32) {
      xpc_dictionary_set_fd(dict, key, fd)
    }

    public func setData(_ key: String, _ data: Data) {
      data.withUnsafeBytes { buf in
        xpc_dictionary_set_data(dict, key, buf.baseAddress!, buf.count)
      }
    }

    public func setString(_ key: String, _ value: String) {
      xpc_dictionary_set_string(dict, key, value)
    }

    public func setInt64(_ key: String, _ value: Int64) {
      xpc_dictionary_set_int64(dict, key, value)
    }

    public func setUInt64(_ key: String, _ value: UInt64) {
      xpc_dictionary_set_uint64(dict, key, value)
    }

    public func setBool(_ key: String, _ value: Bool) {
      xpc_dictionary_set_bool(dict, key, value)
    }

    public func setDouble(_ key: String, _ value: Double) {
      xpc_dictionary_set_double(dict, key, value)
    }

    public func withUnsafeDictionary<T>(_ body: (xpc_object_t) throws -> T) rethrows -> T {
      try body(dict)
    }
  }

  public struct Reader: @unchecked Sendable {
    let dict: xpc_object_t

    init(_ dict: xpc_object_t) { self.dict = dict }

    /// Duplicate a file descriptor from the dictionary. Caller must close the returned fd.
    public func fileDescriptor(_ key: String) -> Int32? {
      let fd = xpc_dictionary_dup_fd(dict, key)
      return fd >= 0 ? fd : nil
    }

    public func data(_ key: String) -> Data? {
      var length = 0
      guard let ptr = xpc_dictionary_get_data(dict, key, &length) else { return nil }
      return Data(bytes: ptr, count: length)
    }

    /// Zero-copy access to data bytes. Pointer is valid for the lifetime of this reader.
    public func withData<T>(_ key: String, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T? {
      var length = 0
      guard let ptr = xpc_dictionary_get_data(dict, key, &length) else { return nil }
      return try body(UnsafeRawBufferPointer(start: ptr, count: length))
    }

    public func string(_ key: String) -> String? {
      guard let ptr = xpc_dictionary_get_string(dict, key) else { return nil }
      return String(cString: ptr)
    }

    public func int64(_ key: String) -> Int64 {
      xpc_dictionary_get_int64(dict, key)
    }

    public func uint64(_ key: String) -> UInt64 {
      xpc_dictionary_get_uint64(dict, key)
    }

    public func bool(_ key: String) -> Bool {
      xpc_dictionary_get_bool(dict, key)
    }

    public func double(_ key: String) -> Double {
      xpc_dictionary_get_double(dict, key)
    }

    public func withUnsafeDictionary<T>(_ body: (xpc_object_t) throws -> T) rethrows -> T {
      try body(dict)
    }
  }
}
