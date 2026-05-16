import Foundation
import Security

/// Generates and manages a self-signed TLS certificate for the local MCP server.
/// Uses Security.framework only — safe inside the App Sandbox.
///
/// The private key is stored in the app's keychain partition. The certificate
/// is stored alongside it, which lets the keychain vend a SecIdentity pairing
/// them automatically. On the first call to `getOrCreateIdentity()` the key +
/// cert are generated; subsequent calls return the cached keychain items.
enum MCPTLSHelper {

    enum E: Error, LocalizedError {
        case keyGen(String), pubKeyExport, signing(String), certCreate, identityNotFound
        var errorDescription: String? {
            switch self {
            case .keyGen(let m):   return "Key generation failed: \(m)"
            case .pubKeyExport:    return "Could not export public key"
            case .signing(let m):  return "Signing failed: \(m)"
            case .certCreate:      return "SecCertificateCreateWithData returned nil — DER encoding error"
            case .identityNotFound: return "Identity not found in keychain after adding certificate"
            }
        }
    }

    /// Shared keychain label for the private key and the certificate.
    static let keychainLabel = "matrix-mcp-tls"

    // MARK: - Public API

    /// Returns an existing identity from the keychain, or generates a fresh one.
    /// This is synchronous (Security.framework keychain ops are synchronous).
    static func getOrCreateIdentity() throws -> SecIdentity {
        if let id = findIdentity() { return id }
        return try makeIdentity()
    }

    /// Exports the certificate to a temporary `.cer` file and returns its URL.
    /// The caller can open the URL with NSWorkspace to let the user trust it
    /// in Keychain Access.
    static func exportCertToTemp(identity: SecIdentity) -> URL? {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess,
              let cert else { return nil }
        let data = SecCertificateCopyData(cert) as Data
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("matrix-mcp.cer")
        try? data.write(to: url)
        return url
    }

    // MARK: - Keychain helpers

    private static func findIdentity() -> SecIdentity? {
        let q: [String: Any] = [
            kSecClass as String:      kSecClassIdentity,
            kSecAttrLabel as String:  keychainLabel,
            kSecReturnRef as String:  true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let ref else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! SecIdentity)
    }

    private static func purge() {
        for cls in [kSecClassKey, kSecClassCertificate] as [CFString] {
            SecItemDelete([
                kSecClass as String:     cls,
                kSecAttrLabel as String: keychainLabel,
            ] as CFDictionary)
        }
    }

    // MARK: - Identity creation

    private static func makeIdentity() throws -> SecIdentity {
        purge()

        // 1. Generate an EC P-256 key pair; store private key in keychain.
        var cfErr: Unmanaged<CFError>?
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeEC,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:  true,
                kSecAttrLabel as String:        keychainLabel,
                kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock,
            ],
        ]
        guard let privKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &cfErr),
              let pubKey  = SecKeyCopyPublicKey(privKey),
              let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &cfErr) as Data?
        else {
            throw E.keyGen(cfErr?.takeRetainedValue().localizedDescription ?? "unknown")
        }

        // 2. Build the TBSCertificate DER blob.
        let tbsCert = buildTBS(pubKeyData: pubKeyData)

        // 3. Sign it with the private key (ecdsa-with-SHA256, DER output).
        guard let sig = SecKeyCreateSignature(
            privKey, .ecdsaSignatureMessageX962SHA256, tbsCert as CFData, &cfErr
        ) as Data? else {
            throw E.signing(cfErr?.takeRetainedValue().localizedDescription ?? "unknown")
        }

        // 4. Wrap TBS + algorithm + signature into the outer Certificate SEQUENCE.
        let certDER = seq(
            tbsCert +
            seq(oid(OIDs.ecdsaSHA256)) +   // outer signatureAlgorithm
            bitstr(sig)                     // outer signature
        )

        // 5. Create a SecCertificate.
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw E.certCreate
        }

        // 6. Store the certificate in the keychain so it can be paired with the key.
        SecItemAdd([
            kSecClass as String:     kSecClassCertificate,
            kSecValueRef as String:  cert,
            kSecAttrLabel as String: keychainLabel,
        ] as CFDictionary, nil)

        // 7. Retrieve the paired identity.
        guard let identity = findIdentity() else { throw E.identityNotFound }
        return identity
    }

    // MARK: - X.509 certificate construction

    private enum OIDs {
        static let ecPublicKey:  [UInt8] = [0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]
        static let prime256v1:   [UInt8] = [0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07]
        static let ecdsaSHA256:  [UInt8] = [0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02]
        static let commonName:   [UInt8] = [0x55,0x04,0x03]
        static let san:          [UInt8] = [0x55,0x1d,0x11]   // subjectAltName
        static let eku:          [UInt8] = [0x55,0x1d,0x25]   // extendedKeyUsage
        static let serverAuth:   [UInt8] = [0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01]
    }

    private static func buildTBS(pubKeyData: Data) -> Data {
        // version v3
        let version = ctx(0, int([0x02]))

        // random 8-byte serial, positive
        var serialBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &serialBytes)
        serialBytes[0] &= 0x7F
        let serialNum = int(serialBytes)

        // signatureAlgorithm (must match outer)
        let sigAlg = seq(oid(OIDs.ecdsaSHA256))

        // issuer == subject == CN=matrix-mcp
        let name = seq(set(seq(oid(OIDs.commonName) + utf8("matrix-mcp"))))

        // validity: now → +10 years
        let now    = Date()
        let expiry = now.addingTimeInterval(10 * 365.25 * 86400)
        let validity = seq(gtime(now) + gtime(expiry))

        // subjectPublicKeyInfo
        let spki = seq(
            seq(oid(OIDs.ecPublicKey) + oid(OIDs.prime256v1)) +
            bitstr(pubKeyData)
        )

        // extensions
        let extensions = ctx(3, seq(sanExtension() + ekuExtension()))

        return seq(version + serialNum + sigAlg + name + validity + name + spki + extensions)
    }

    private static func sanExtension() -> Data {
        // IP:127.0.0.1  →  [7] IMPLICIT OCTET STRING
        // DNS:localhost  →  [2] IMPLICIT IA5String
        let san = seq(
            tlv(0x87, Data([127, 0, 0, 1])) +
            tlv(0x82, Data("localhost".utf8))
        )
        return seq(oid(OIDs.san) + octet(san))
    }

    private static func ekuExtension() -> Data {
        let eku = seq(oid(OIDs.serverAuth))
        return seq(oid(OIDs.eku) + octet(eku))
    }

    // MARK: - ASN.1 DER primitives

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var r = Data([tag])
        let n = content.count
        if      n < 0x80   { r.append(UInt8(n)) }
        else if n < 0x100  { r += [0x81, UInt8(n)] }
        else               { r += [0x82, UInt8(n >> 8), UInt8(n & 0xFF)] }
        r.append(content)
        return r
    }

    static func seq(_ c: Data)    -> Data { tlv(0x30, c) }
    static func set(_ c: Data)    -> Data { tlv(0x31, c) }
    static func int(_ b: [UInt8]) -> Data { tlv(0x02, Data(b)) }
    static func oid(_ b: [UInt8]) -> Data { tlv(0x06, Data(b)) }
    static func utf8(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    static func octet(_ c: Data)  -> Data { tlv(0x04, c) }
    static func bitstr(_ c: Data) -> Data { tlv(0x03, Data([0x00]) + c) }
    static func ctx(_ tag: UInt8, _ c: Data) -> Data { tlv(0xA0 | tag, c) }

    static func gtime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return tlv(0x18, Data(f.string(from: date).utf8))
    }
}
