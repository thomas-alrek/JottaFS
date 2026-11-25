import Foundation

/// The JottaFSCore framework's bundle, which holds the translations of its
/// texts (Localizable.xcstrings). In the Swift package build the texts are
/// not bundled, so they stay in English.
private final class JottaFSCoreBundleToken {}

extension Bundle {
    static let jottaFSCore = Bundle(for: JottaFSCoreBundleToken.self)
}
