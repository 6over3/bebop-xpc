import Darwin
import SwiftBebop

public enum XPCMessageKey: AttachmentKey {
  public typealias Value = XPCMessage.Reader
}

public enum XPCResponsePreparerKey: AttachmentKey {
  public typealias Value = @Sendable (XPCMessage.Writer) -> Void
}

public struct XPCAuthInfo: AuthInfo, Sendable {
  public let pid: pid_t
  public let uid: uid_t
  public let gid: gid_t

  public var authType: String { "xpc" }
  // UID is stable across reconnections for the same user
  public var identity: String { "uid:\(uid)" }
}
