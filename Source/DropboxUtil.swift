//
//  DropboxClient.swift
//  Pods
//
//  Created by Ryan Pearl on 5/20/15.
//
//

import Foundation
import Alamofire

class DropboxServerTrustPolicyManager: ServerTrustPolicyManager {
    init() {
        super.init(policies: [String : ServerTrustPolicy]())
    }
        
    override func serverTrustPolicyForHost(_ host: String) -> ServerTrustPolicy? {
        let trustPolicy = ServerTrustPolicy.customEvaluation {(serverTrust, host) in
            let policy = SecPolicyCreateSSL(true,  host as CFString)
            let array = [policy]
            SecTrustSetPolicies(serverTrust, array)
            
            let certificates = SecurityUtil.rootCertificates()
            SecTrustSetAnchorCertificates(serverTrust, certificates!)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            
            var isValid = false
            var result = SecTrustResultType.invalid
            let status = SecTrustEvaluate(serverTrust, &result)
            
            if status == errSecSuccess {
                let unspecified = SecTrustResultType.unspecified
                let proceed = SecTrustResultType.proceed
                
                isValid = result == unspecified || result == proceed
            }
            
            if (isValid) {
                let certificate = SecTrustGetCertificateAtIndex(serverTrust, 0)
                isValid = !SecurityUtil.isRevokedCertificate(certificate)
            }
            
            return isValid

        }
        
        return trustPolicy
    }
}

/// This is a convenience class for the typical single user case. To use this
/// class, see details in the tutorial at:
/// https://www.dropbox.com/developers/documentation/swift#tutorial
///
/// For information on the available API methods, see the documentation for DropboxClient
public class Dropbox {
    /// An authorized client. This will be set to nil if unlinked.
    public static var authorizedClient : DropboxClient?

    /// Sets up access to the API
    public static func setupWithAppKey(_ appKey : String) {
        precondition(DropboxAuthManager.sharedAuthManager == nil, "Only call `Dropbox.initAppWithKey` once")
        DropboxAuthManager.sharedAuthManager = DropboxAuthManager(appKey: appKey)

        if let token = DropboxAuthManager.sharedAuthManager.getFirstAccessToken() {
            Dropbox.authorizedClient = DropboxClient(accessToken: token)
            DropboxClient.sharedClient = Dropbox.authorizedClient
        }
    }

    /// Present the OAuth2 authorization request page by presenting a web view controller modally
    ///
    /// - parameter controller: The controller to present from
#if os(iOS)
    public static func authorizeFromController(_ controller: UIViewController) {
        precondition(DropboxAuthManager.sharedAuthManager != nil, "Call `Dropbox.initAppWithKey` before calling this method")
        precondition(Dropbox.authorizedClient == nil, "Client is already authorized")
        DropboxAuthManager.sharedAuthManager.authorizeFromController(controller)
    }
#else
        // TODO Screens Mac
#endif

    /// Handle a redirect and automatically initialize the client and save the token.
    public static func handleRedirectURL(_ url: URL) -> DropboxAuthResult? {
        precondition(DropboxAuthManager.sharedAuthManager != nil, "Call `Dropbox.initAppWithKey` before calling this method")
        precondition(Dropbox.authorizedClient == nil, "Client is already authorized")
        if let result =  DropboxAuthManager.sharedAuthManager.handleRedirectURL(url) {
            switch result {
            case .success(let token):
                Dropbox.authorizedClient = DropboxClient(accessToken: token)
                DropboxClient.sharedClient = Dropbox.authorizedClient
                return result
            case .error:
                return result
            }
        } else {
            return nil
        }
    }

    /// Unlink the user.
    public static func unlinkClient() {
        precondition(DropboxAuthManager.sharedAuthManager != nil, "Call `Dropbox.initAppWithKey` before calling this method")
        if Dropbox.authorizedClient == nil {
            // already unlinked
            return
        }

        _ = DropboxAuthManager.sharedAuthManager.clearStoredAccessTokens()
        Dropbox.authorizedClient = nil
        DropboxClient.sharedClient = nil
    }
}

