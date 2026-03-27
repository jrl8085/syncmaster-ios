import Foundation
import CryptoKit

final class SSLPinningDelegate: NSObject, URLSessionDelegate {
    private let pinnedFingerprint: String

    init(fingerprint: String) {
        self.pinnedFingerprint = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Empty fingerprint = trust-on-first-use (initial pairing only)
        if pinnedFingerprint.isEmpty {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        guard let cert = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let fingerprint = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
            .compactMap { String(format: "%02x", $0) }.joined()

        if fingerprint == pinnedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - TOFU capture delegate

final class FingerprintCapturingDelegate: NSObject, URLSessionDelegate {
    private(set) var capturedFingerprint: String?

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
        if let cert = chain.first {
            capturedFingerprint = SHA256.hash(data: SecCertificateCopyData(cert) as Data)
                .compactMap { String(format: "%02x", $0) }.joined()
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    static func capture(from url: URL) async throws -> String {
        let delegate = FingerprintCapturingDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        _ = try? await session.data(for: URLRequest(url: url.appendingPathComponent("health")))
        return delegate.capturedFingerprint ?? ""
    }
}
