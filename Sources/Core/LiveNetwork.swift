import Foundation
#if canImport(Security)
import Security
#endif

/// Used only by live playlists whose caller explicitly enables certificate bypass.
public final class LiveNetwork: NSObject, URLSessionDelegate, @unchecked Sendable {
    public static let shared = LiveNetwork()
    public lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        #if canImport(Security)
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        #endif
        completionHandler(.performDefaultHandling, nil)
    }
}
