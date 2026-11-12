import CryptoKit
import Foundation

/// obs-websocket v5 authentication helper.
///
/// From the protocol documentation (
/// "Creating an authentication string"):
///
/// 1. Concatenate the password with the server-provided `salt`.
/// 2. SHA-256 the result and base64-encode it (the "base64 secret").
/// 3. Concatenate the base64 secret with the server-provided `challenge`.
/// 4. SHA-256 that result and base64-encode it. The output is the `authentication`
///    string sent in `Identify`.
public enum OBSAuthentication {
    public static func authenticationString(
        password: String,
        challenge: String,
        salt: String
    ) -> String {
        let secret = sha256Base64(Data((password + salt).utf8))
        return sha256Base64(Data((secret + challenge).utf8))
    }

    private static func sha256Base64(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }
}
