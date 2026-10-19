// Verifies bytes against the explicitly configured public key, without Keychain access.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
let configured = ProcessInfo.processInfo.environment["VERBEMO_SPARKLE_PUBLIC_KEY"] ?? ""
guard arguments.count == 3,
      let publicData = Data(base64Encoded: configured),
      let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData),
      let data = try? Data(contentsOf: URL(fileURLWithPath: arguments[1])),
      key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("Sparkle public/private key mismatch or invalid signature\n".utf8))
    exit(1)
}
