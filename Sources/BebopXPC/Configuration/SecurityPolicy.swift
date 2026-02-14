import LightweightCodeRequirements
import Security
import XPC

/// Code-signing requirements for XPC peer validation.
public struct SecurityPolicy: Sendable {
  enum Requirement: Sendable {
    case sameTeam
    case platformBinary
    case hasEntitlement(String)
    case entitlementEquals(String, String)
    case entitlementBool(String, Bool)
  }

  let requirements: [Requirement]

  /// No security requirements.
  public static let none = Self(requirements: [])

  /// Require the peer to be signed by the same team.
  public static func sameTeam() -> Self {
    Self(requirements: [.sameTeam])
  }

  /// Require the peer to be a platform binary.
  public static func platformBinary() -> Self {
    Self(requirements: [.platformBinary])
  }

  /// Require the peer to hold the given entitlement.
  public static func hasEntitlement(_ name: String) -> Self {
    Self(requirements: [.hasEntitlement(name)])
  }

  static var currentTeamIdentifier: String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else {
      return nil
    }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
  }

  func makePeerRequirement() -> XPCPeerRequirement? {
    guard !requirements.isEmpty else { return nil }

    if requirements.count == 1 {
      return singleRequirement(requirements[0])
    }

    let constraints = requirements.map { processConstraint(for: $0) }
    let closure: () -> [any ProcessConstraint] = { constraints }
    guard let combined = try? ProcessCodeRequirement.allOf(requirement: closure) else {
      return nil
    }
    return .codeRequirement(combined)
  }

  private func singleRequirement(_ req: Requirement) -> XPCPeerRequirement {
    switch req {
    case .sameTeam:
      return .isFromSameTeam()
    case .platformBinary:
      return .isPlatformCode()
    case .hasEntitlement(let name):
      return .hasEntitlement(name)
    case .entitlementEquals(let name, let value):
      return .entitlement(name, matches: value)
    case .entitlementBool(let name, let value):
      return .entitlement(name, matches: value)
    }
  }

  private func processConstraint(for req: Requirement) -> any ProcessConstraint {
    switch req {
    case .sameTeam:
      return TeamIdentifierMatchesCurrentProcess()
    case .platformBinary:
      return ValidationCategory(.platform)
    case .hasEntitlement(let name):
      return EntitlementsQuery.key(name).matchType(.boolean)
    case .entitlementEquals(let name, let value):
      return EntitlementsQuery.key(name).match(value)
    case .entitlementBool(let name, let value):
      return EntitlementsQuery.key(name).match(value)
    }
  }
}
