#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

import WebKit

import Security

import Foundation


/// A Dropbox access token
public class DropboxAccessToken : CustomStringConvertible {
    
    /// The access token string
    public let accessToken: String
    
    /// The associated user
    public let uid: String
    
    public init(accessToken: String, uid: String) {
        self.accessToken = accessToken
        self.uid = uid
    }
    
    public var description : String {
        return self.accessToken
    }
}

/// A failed authorization.
/// See RFC6749 4.2.2.1
public enum OAuth2Error {
    /// The client is not authorized to request an access token using this method.
    case unauthorizedClient
    
    /// The resource owner or authorization server denied the request.
    case accessDenied
    
    /// The authorization server does not support obtaining an access token using this method.
    case unsupportedResponseType
    
    /// The requested scope is invalid, unknown, or malformed.
    case invalidScope
    
    /// The authorization server encountered an unexpected condition that prevented it from fulfilling the request.
    case serverError
    
    /// The authorization server is currently unable to handle the request due to a temporary overloading or maintenance of the server.
    case temporarilyUnavailable
    
    /// Some other error (outside of the OAuth2 specification)
    case unknown
    
    /// Initializes an error code from the string specced in RFC6749
    init(errorCode: String) {
        switch errorCode {
            case "unauthorized_client": self = .unauthorizedClient
            case "access_denied": self = .accessDenied
            case "unsupported_response_type": self = .unsupportedResponseType
            case "invalid_scope": self = .invalidScope
            case "server_error": self = .serverError
            case "temporarily_unavailable": self = .temporarilyUnavailable
            default: self = .unknown
        }
    }
}

private let kDBLinkNonce = "dropbox.sync.nonce"

/// The result of an authorization attempt.
public enum DropboxAuthResult {
    /// The authorization succeeded. Includes a `DropboxAccessToken`.
    case success(DropboxAccessToken)
    
    /// The authorization failed. Includes an `OAuth2Error` and a descriptive message.
    case error(OAuth2Error, String)
}

class DBKeychain {
    
    class func queryWithDict(_ query: [String : AnyObject]) -> CFDictionary
    {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        var queryDict = query
        
        queryDict[kSecClass as String]       = kSecClassGenericPassword
        queryDict[kSecAttrService as String] = "\(bundleId).dropbox.authv2" as AnyObject

        return queryDict as CFDictionary
    }

    class func set(_ key: String, value: String) -> Bool {
        if let data = value.data(using: String.Encoding.utf8) {
            return set(key, value: data)
        } else {
            return false
        }
    }
    
    class func set(_ key: String, value: Data) -> Bool {
        let query = DBKeychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject,
            (  kSecValueData as String): value as AnyObject
        ])
        
        SecItemDelete(query)
        
        return SecItemAdd(query, nil) == noErr
    }
    
    class func getAsData(_ key: String) -> Data? {
        let query = DBKeychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject,
            ( kSecReturnData as String): kCFBooleanTrue,
            ( kSecMatchLimit as String): kSecMatchLimitOne
        ])
        
        var dataResult : AnyObject?
        let status = withUnsafeMutablePointer(to: &dataResult) { (ptr) in
            SecItemCopyMatching(query, UnsafeMutablePointer(ptr))
        }
        
        if status == noErr {
            return dataResult as? Data
        }
        
        return nil
    }
    
    class func dbgListAllItems() {
        let query = [
            (kSecClass as String)           : kSecClassGenericPassword,
            (kSecReturnAttributes as String): kCFBooleanTrue,
            (       kSecMatchLimit as String): kSecMatchLimitAll
        ] as [String : Any]
        
        var dataResult : AnyObject?
        let status = withUnsafeMutablePointer(to: &dataResult) { (ptr) in
            SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer(ptr))
        }
        
        if status == noErr {
            let results = dataResult as? [[String : AnyObject]] ?? []
            
            print(results.map {d in (d["svce"] as! String, d["acct"] as! String)})
        }

    }
    
    class func getAll() -> [String] {
        let query = DBKeychain.queryWithDict([
            ( kSecReturnAttributes as String): kCFBooleanTrue,
            (       kSecMatchLimit as String): kSecMatchLimitAll
        ])
        
        var dataResult : AnyObject?
        let status = withUnsafeMutablePointer(to: &dataResult) { (ptr) in
            SecItemCopyMatching(query, UnsafeMutablePointer(ptr))
        }
        
        if status == noErr {
            let results = dataResult as? [[String : AnyObject]] ?? []
            return results.map { d in d["acct"] as! String }
        
        }
        return []
    }
    

    
    class func get(_ key: String) -> String? {
        if let data = getAsData(key) {
            return NSString(data: data, encoding: String.Encoding.utf8.rawValue) as? String
        } else {
            return nil
        }
    }
    
    class func delete(_ key: String) -> Bool {
        let query = DBKeychain.queryWithDict([
            (kSecAttrAccount as String): key as AnyObject
        ])
        
        return SecItemDelete(query) == noErr
    }
    
    class func clear() -> Bool {
        let query = DBKeychain.queryWithDict([:])
        return SecItemDelete(query) == noErr
    }
}
/// Manages access token storage and authentication
///
/// Use the `DropboxAuthManager` to authenticate users through OAuth2, save access tokens, and retrieve access tokens.
public class DropboxAuthManager {
    
    let appKey : String
    let redirectURL: URL
    let dauthRedirectURL: URL

    let host: String
    
    // MARK: Shared instance
    /// A shared instance of a `DropboxAuthManager` for convenience
    public static var sharedAuthManager : DropboxAuthManager!
    
    // MARK: Functions
    public init(appKey: String, host: String) {
        self.appKey = appKey
        self.host = host
        self.redirectURL = URL(string: "db-\(self.appKey)://2/token")!
        self.dauthRedirectURL = URL(string: "db-\(self.appKey)://1/connect")!
    }
    
    /** 
        Create an instance

        parameter appKey: The app key from the developer console that identifies this app.
    */
    convenience public init(appKey: String) {
        self.init(appKey: appKey, host: "www.dropbox.com")
    }
    
    private func conformsToAppScheme() -> Bool {
        let appScheme = "db-\(self.appKey)"
        
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [ [String: AnyObject] ] ?? []
        
        for urlType in urlTypes {
            let schemes = urlType["CFBundleURLSchemes"] as? [String] ?? []
            for scheme in schemes {
                print(scheme)
                if scheme == appScheme {
                    return true
                }
            }
        }
        return false
    }
    
    private func hasApplicationQueriesScheme() -> Bool {
        
        let queriesSchemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        
        for scheme in queriesSchemes {
            if scheme == "dbapi-2" {
                return true
            }
        }
        return false
    }
    
    
    private func authURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = self.host
        components.path = "/1/oauth2/authorize"

        components.queryItems = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: self.appKey),
            URLQueryItem(name: "redirect_uri", value: self.redirectURL.urlString),
            URLQueryItem(name: "disable_signup", value: "true"),
        ]
        return components.url!
    }
    
    private func dAuthURL(_ nonce: String?) -> URL {
        var components = URLComponents()
        components.scheme =  "dbapi-2"
        components.host = "1"
        components.path = "/connect"
        
        if let n = nonce {
            let state = "oauth2:\(n)"
            components.queryItems = [
                URLQueryItem(name: "k", value: self.appKey),
                URLQueryItem(name: "s", value: ""),
                URLQueryItem(name: "state", value: state),
            ]
        }
        return components.url!
    }
    
    private func canHandleURL(_ url: URL) -> Bool {
        for known in [self.redirectURL, self.dauthRedirectURL] {
            if (url.scheme == known.scheme &&  url.host == known.host && url.path == known.path) {
                return true
            }
        }
        return false
    }
    
    /// Present the OAuth2 authorization request page by presenting a web view controller modally
    ///
    /// parameter controller: The controller to present from
#if os(iOS)
    public func authorizeFromController(_ controller: UIViewController) {
        if !self.conformsToAppScheme() {
            let message = "DropboxSDK: unable to link; app isn't registered for correct URL scheme (db-\(self.appKey))"
            let alertController = UIAlertController(
                title: "SwiftyDropbox Error",
                message: message,
                preferredStyle: UIAlertControllerStyle.alert)
            controller.present(alertController, animated: true, completion: { fatalError(message) } )
            return
        }
        if !self.hasApplicationQueriesScheme() {
            let message = "DropboxSDK: unable to link; app isn't registered to query for URL scheme dbapi-2. Add a dbapi-2 entry to LSApplicationQueriesSchemes"
            
            let alertController = UIAlertController(
                title: "SwiftyDropbox Error",
                message: message,
                preferredStyle: UIAlertControllerStyle.alert)
            controller.present(alertController, animated: true, completion: { fatalError(message) } )
            return
        }
        if UIApplication.shared.canOpenURL(dAuthURL(nil)) {
            let nonce = UUID().uuidString
            UserDefaults.standard.set(nonce, forKey: kDBLinkNonce)
            UserDefaults.standard.synchronize()
            
            UIApplication.shared.open(dAuthURL(nonce), options: [:], completionHandler: nil)
        } else {
            let web = DropboxConnectController(
                URL: self.authURL(),
                tryIntercept: { url in
                    if self.canHandleURL(url) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                        return true
                    } else {
                        return false
                    }
                }
            )
            let navigationController = UINavigationController(rootViewController: web)
            controller.present(navigationController, animated: true, completion: nil)
        }
    }
#else
    // TODO Screens Mac
#endif
    
    private func extractfromDAuthURL(_ url: URL) -> DropboxAuthResult {
        switch url.path {
        case "/connect":
            var results = [String: String]()
            let pairs  = url.query?.components(separatedBy: "&") ?? []
            
            for pair in pairs {
                let kv = pair.components(separatedBy: "=")
                results.updateValue(kv[1], forKey: kv[0])
            }
            let state = results["state"]?.components(separatedBy: "%3A") ?? []
            
            let nonce = UserDefaults.standard.object(forKey: kDBLinkNonce) as? String
            if state.count == 2 && state[0] == "oauth2" && state[1] == nonce! {
                let accessToken = results["oauth_token_secret"]!
                let uid = results["uid"]!
                return .success(DropboxAccessToken(accessToken: accessToken, uid: uid))
            } else {
                return .error(.unknown, "Unable to verify link request")
            }
        default:
            return .error(.accessDenied, "User cancelled Dropbox link")
        }
    }
    
    private func extractFromRedirectURL(_ url: URL) -> DropboxAuthResult {
        var results = [String: String]()
        let pairs  = url.fragment?.components(separatedBy: "&") ?? []
        
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            results.updateValue(kv[1], forKey: kv[0])
        }
        
        if let error = results["error"] {
            let desc = results["error_description"]?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            return .error(OAuth2Error(errorCode: error), desc ?? "")
        } else {
            let accessToken = results["access_token"]!
            let uid = results["uid"]!
            return .success(DropboxAccessToken(accessToken: accessToken, uid: uid))
        }
    }
    
    /**
        Try to handle a redirect back into the application

        - parameter url: The URL to attempt to handle

        - returns `nil` if SwiftyDropbox cannot handle the redirect URL, otherwise returns the `DropboxAuthResult`.
    */
    public func handleRedirectURL(_ url: URL) -> DropboxAuthResult? {
        
        if !self.canHandleURL(url) {
            return nil
        }
        
        let result : DropboxAuthResult
        if url.host == "1" { // dauth
            result = extractfromDAuthURL(url)
        } else {
            result = extractFromRedirectURL(url)
        }
        
        switch result {
        case .success(let token):
            _ = DBKeychain.set(token.uid, value: token.accessToken)
            return result
        default:
            return result
        }
    }
    
    /**
        Retrieve all stored access tokens

        - returns: a dictionary mapping users to their access tokens
    */
    public func getAllAccessTokens() -> [String : DropboxAccessToken] {
        let users = DBKeychain.getAll()
        var ret = [String : DropboxAccessToken]()
        for user in users {
            if let accessToken = DBKeychain.get(user) {
                ret[user] = DropboxAccessToken(accessToken: accessToken, uid: user)
            }
        }
        return ret
    }
    
    /**
        Check if there are any stored access tokens

        -returns: Whether there are stored access tokens
    */
    public func hasStoredAccessTokens() -> Bool {
        return self.getAllAccessTokens().count != 0
    }
    
    /**
        Retrieve the access token for a particular user

        - parameter user: The user whose token to retrieve

        - returns: An access token if present, otherwise `nil`.
    */
    public func getAccessToken(_ user: String) -> DropboxAccessToken? {
        if let accessToken = DBKeychain.get(user) {
            return DropboxAccessToken(accessToken: accessToken, uid: user)
        } else {
            return nil
        }
    }
    /**
        Delete a specific access token

        - parameter token: The access token to delete

        - returns: whether the operation succeeded
    */
    public func clearStoredAccessToken(_ token: DropboxAccessToken) -> Bool {
        return DBKeychain.delete(token.uid)
    }
    /**
        Delete all stored access tokens

        - returns: whether the operation succeeded
    */
    public func clearStoredAccessTokens() -> Bool {
        return DBKeychain.clear()
    }
    /**
        Save an access token

        - parameter token: The access token to save

        - returns: whether the operation succeeded
    */
    public func storeAccessToken(_ token: DropboxAccessToken) -> Bool {
        return DBKeychain.set(token.uid, value: token.accessToken)
    }

    /**
        Utility function to return an arbitrary access token
    
        - returns: the "first" access token found, if any (otherwise `nil`)
    */
    public func getFirstAccessToken() -> DropboxAccessToken? {
        return self.getAllAccessTokens().values.first
    }
}


#if os(iOS)
public class DropboxConnectController : UIViewController, WKNavigationDelegate {
    var webView : WKWebView!
    
    var onWillDismiss: ((_ didCancel: Bool) -> Void)?
    var tryIntercept: ((_ url: URL) -> Bool)?
    
    var cancelButton: UIBarButtonItem?
    
    
    public init() {
        super.init(nibName: nil, bundle: nil)
    }
    
    public init(URL: Foundation.URL, tryIntercept: ((_ url: Foundation.URL) -> Bool)) {
        super.init(nibName: nil, bundle: nil)
        self.startURL = URL
        self.tryIntercept = tryIntercept
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        self.title = "Link to Dropbox"
        self.webView = WKWebView(frame: self.view.bounds)
        self.view.addSubview(self.webView)
        
        self.webView.navigationDelegate = self
        
        self.view.backgroundColor = UIColor.white
        
        self.cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(DropboxConnectController.cancel(_:)))
        self.navigationItem.rightBarButtonItem = self.cancelButton
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !webView.canGoBack {
            if nil != startURL {
                loadURL(startURL!)
            }
            else {
                webView.loadHTMLString("There is no `startURL`", baseURL: nil)
            }
        }
    }
    
   public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Swift.Void) {
        if let url = navigationAction.request.url, let callback = self.tryIntercept {
            if callback(url) {
                self.dismiss(true)
                return decisionHandler(.cancel)
            }
        }
        return decisionHandler(.allow)
    }
    
    
    public var startURL: URL? {
        didSet(oldURL) {
            if nil != startURL && nil == oldURL && isViewLoaded {
                loadURL(startURL!)
            }
        }
    }
    
    public func loadURL(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
    
    func showHideBackButton(_ show: Bool) {
        navigationItem.leftBarButtonItem = show ? UIBarButtonItem(barButtonSystemItem: .rewind, target: self, action: #selector(DropboxConnectController.goBack(_:))) : nil
    }
    
    func goBack(_ sender: AnyObject?) {
        webView.goBack()
    }
    
    func cancel(_ sender: AnyObject?) {
        dismiss(true, animated: (sender != nil))
    }
    
    func dismiss(_ animated: Bool) {
        dismiss(false, animated: animated)
    }
    
    func dismiss(_ asCancel: Bool, animated: Bool) {
        webView.stopLoading()
        
        self.onWillDismiss?(asCancel)
        presentingViewController?.dismiss(animated: animated, completion: nil)
    }
    
}

#endif
