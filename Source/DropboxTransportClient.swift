import Foundation
import Alamofire

public class DropboxTransportClient {
    static let version = "3.2.0"
    
    static let manager: SessionManager = {
        let manager = SessionManager(serverTrustPolicyManager: DropboxServerTrustPolicyManager())
        manager.startRequestsImmediately = false
        return manager
    }()
    static let backgroundManager: SessionManager = {
        let backgroundConfig = URLSessionConfiguration.background(withIdentifier: "com.dropbox.SwiftyDropbox")
        let backgroundManager = SessionManager(configuration: backgroundConfig, serverTrustPolicyManager: DropboxServerTrustPolicyManager())
        backgroundManager.startRequestsImmediately = false
        return backgroundManager
    }()

    var accessToken: DropboxAccessToken
    var selectUser: String?
    var baseHosts: [String: String]
    var userAgent: String

    func additionalHeaders(noauth: Bool) -> [String: String] {
        var headers = ["User-Agent": self.userAgent]
        if self.selectUser != nil {
            headers["Dropbox-Api-Select-User"] = self.selectUser
        }
        if (!noauth) {
            headers["Authorization"] = "Bearer \(self.accessToken)"
        }
        return headers
    }
    
    public convenience init(accessToken: DropboxAccessToken, selectUser: String? = nil) {
        let defaultBaseHosts = [
            "api": "https://api.dropbox.com/2",
            "content": "https://api-content.dropbox.com/2",
            "notify": "https://notify.dropboxapi.com/2",
            ]
        
        let defaultUserAgent = "OfficialDropboxSwiftSDKv2/\(DropboxTransportClient.version)"

        self.init(accessToken: accessToken, selectUser: selectUser, baseHosts: defaultBaseHosts, userAgent: defaultUserAgent)
    }
    
    public init(accessToken: DropboxAccessToken, selectUser: String?, baseHosts: [String: String], userAgent: String) {
        self.accessToken = accessToken
        self.selectUser = selectUser
        self.baseHosts = baseHosts
        self.userAgent = userAgent
    }

    public func request<ASerial: JSONSerializer, RSerial: JSONSerializer, ESerial: JSONSerializer>(route: Route<ASerial, RSerial, ESerial>,
                        serverArgs: ASerial.ValueType? = nil) -> RpcRequest<RSerial, ESerial> {
        let host = route.attrs["host"]! ?? "api"
        let url = "\(self.baseHosts[host]!)/\(route.namespace)/\(route.name)"
        let routeStyle: RouteStyle = RouteStyle(rawValue: route.attrs["style"]!!)!
        
        var rawJsonRequest: Data?
        rawJsonRequest = nil

        if let serverArgs = serverArgs {
            let jsonRequestObj = route.argSerializer.serialize(serverArgs)
            rawJsonRequest = SerializeUtil.dumpJSON(json: jsonRequestObj)
        } else {
            let voidSerializer = route.argSerializer as! VoidSerializer
            let jsonRequestObj = voidSerializer.serialize()
            rawJsonRequest = SerializeUtil.dumpJSON(json: jsonRequestObj)
        }

        let headers = getHeaders(routeStyle: routeStyle, jsonRequest: rawJsonRequest, host: host)

        let encoding = ParameterEncoding.custom { convertible, _ in
            var mutableRequest = convertible.urlRequest
            mutableRequest.httpBody = rawJsonRequest
            return (mutableRequest, nil)
        }

        let request = DropboxTransportClient.backgroundManager.request(url, withMethod: .post, parameters: [:], encoding: encoding, headers: headers)
        let rpcRequestObj = RpcRequest(request: request, responseSerializer: route.responseSerializer, errorSerializer: route.errorSerializer)
        
        request.resume()
            
        return rpcRequestObj
    }

    public func request<ASerial: JSONSerializer, RSerial: JSONSerializer, ESerial: JSONSerializer>(route: Route<ASerial, RSerial, ESerial>,
                        serverArgs: ASerial.ValueType, input: UploadBody) -> UploadRequest<RSerial, ESerial> {
        let host = route.attrs["host"]! ?? "api"
        let url = "\(self.baseHosts[host]!)/\(route.namespace)/\(route.name)"
        let routeStyle: RouteStyle = RouteStyle(rawValue: route.attrs["style"]!!)!
        
        let jsonRequestObj = route.argSerializer.serialize(serverArgs)
        let rawJsonRequest = SerializeUtil.dumpJSON(json: jsonRequestObj)
        
        let headers = getHeaders(routeStyle: routeStyle, jsonRequest: rawJsonRequest, host: host)
        
        let request: Alamofire.Request

        switch input {
        case let .Data(data):
            request = DropboxTransportClient.manager.upload(data, to: url, withMethod: .post, headers: headers)
        case let .File(file):
            request = DropboxTransportClient.backgroundManager.upload(file, to: url, withMethod: .post, headers: headers)
        case let .Stream(stream):
            request = DropboxTransportClient.manager.upload(stream, to: url, withMethod: .post, headers: headers)
        }
        let uploadRequestObj = UploadRequest(request: request, responseSerializer: route.responseSerializer, errorSerializer: route.errorSerializer)
        request.resume()
        
        return uploadRequestObj
    }

    public func request<ASerial: JSONSerializer, RSerial: JSONSerializer, ESerial: JSONSerializer>(route: Route<ASerial, RSerial, ESerial>,
                        serverArgs: ASerial.ValueType, overwrite: Bool, destination: @escaping (URL, HTTPURLResponse) -> URL) -> DownloadRequestFile<RSerial, ESerial> {
        let host = route.attrs["host"]! ?? "api"
        let url = "\(self.baseHosts[host]!)/\(route.namespace)/\(route.name)"
        let routeStyle: RouteStyle = RouteStyle(rawValue: route.attrs["style"]!!)!
        
        let jsonRequestObj = route.argSerializer.serialize(serverArgs)
        let rawJsonRequest = SerializeUtil.dumpJSON(json: jsonRequestObj)
        
        let headers = getHeaders(routeStyle: routeStyle, jsonRequest: rawJsonRequest, host: host)

        weak var _self: DownloadRequestFile<RSerial, ESerial>!
        
        let request = DropboxTransportClient.backgroundManager.download(url, to: { (url, resp) -> URL in
            var finalUrl = destination(url, resp)
            
            if 200 ... 299 ~= resp.statusCode {
                if FileManager.default.fileExists(atPath: finalUrl.path) {
                    if overwrite {
                        do {
                            try FileManager.default.removeItem(at: finalUrl as URL)
                        } catch let error as NSError {
                            print("Error: \(error)")
                        }
                    } else {
                        print("Error: File already exists at \(finalUrl.path)")
                    }
                }
            }
            else {
                _self.errorMessage = try! Data(contentsOf: url as URL)
                // Alamofire will "move" the file to the temporary location where it already resides,
                // and where it will soon be automatically deleted
                finalUrl = url
            }
            
            _self.urlPath = finalUrl
            
            return finalUrl
            }, withMethod: .post, parameters: nil, encoding: .url, headers: headers)

        let downloadRequestObj = DownloadRequestFile(request: request, responseSerializer: route.responseSerializer, errorSerializer: route.errorSerializer)
        _self = downloadRequestObj
        
        request.resume()
        
        return downloadRequestObj
    }

    public func request<ASerial: JSONSerializer, RSerial: JSONSerializer, ESerial: JSONSerializer>(route: Route<ASerial, RSerial, ESerial>,
                        serverArgs: ASerial.ValueType) -> DownloadRequestMemory<RSerial, ESerial> {
        let host = route.attrs["host"]! ?? "api"
        let url = "\(self.baseHosts[host]!)/\(route.namespace)/\(route.name)"
        let routeStyle: RouteStyle = RouteStyle(rawValue: route.attrs["style"]!!)!

        let jsonRequestObj = route.argSerializer.serialize(serverArgs)
        let rawJsonRequest = SerializeUtil.dumpJSON(json: jsonRequestObj)

        let headers = getHeaders(routeStyle: routeStyle, jsonRequest: rawJsonRequest, host: host)

        let request = DropboxTransportClient.backgroundManager.request(.POST, url, headers: headers)

        let downloadRequestObj = DownloadRequestMemory(request: request, responseSerializer: route.responseSerializer, errorSerializer: route.errorSerializer)

        request.resume()

        return downloadRequestObj
    }

    private func getHeaders(routeStyle: RouteStyle, jsonRequest: Data?, host: String) -> [String: String] {
        var headers = [String: String]()
        let noauth = (host == "notify")
        
        for (header, val) in self.additionalHeaders(noauth: noauth) {
            headers[header] = val
        }
        
        if (routeStyle == RouteStyle.Rpc) {
            headers["Content-Type"] = "application/json"
        } else if (routeStyle == RouteStyle.Upload) {
            headers["Content-Type"] = "application/octet-stream"
            if let jsonRequest = jsonRequest {
                let value = asciiEscape(s: utf8Decode(data: jsonRequest))
                headers["Dropbox-Api-Arg"] = value
            }
        } else if (routeStyle == RouteStyle.Download) {
            if let jsonRequest = jsonRequest {
                let value = asciiEscape(s: utf8Decode(data: jsonRequest))
                headers["Dropbox-Api-Arg"] = value
            }
        }
        return headers
    }
}

public class Box<T> {
    public let unboxed: T
    init (_ v: T) { self.unboxed = v }
}

public enum CallError<EType>: CustomStringConvertible {
    case InternalServerError(Int, String?, String?)
    case BadInputError(String?, String?)
    case RateLimitError(Auth.RateLimitError, String?)
    case HTTPError(Int?, String?, String?)
    case AuthError(Auth.AuthError, String?)
    case RouteError(Box<EType>, String?)
    case OSError(Error?)
    
    public var description: String {
        switch self {
        case let .InternalServerError(code, message, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "Internal Server Error \(code)"
            if let m = message {
                ret += ": \(m)"
            }
            return ret
        case let .BadInputError(message, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "Bad Input"
            if let m = message {
                ret += ": \(m)"
            }
            return ret
        case let .AuthError(error, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "API auth error - \(error)"
            return ret
        case let .HTTPError(code, message, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "HTTP Error"
            if let c = code {
                ret += "\(c)"
            }
            if let m = message {
                ret += ": \(m)"
            }
            return ret
        case let .RouteError(box, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "API route error - \(box.unboxed)"
            return ret
        case let .RateLimitError(error, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "API rate limit error - \(error)"
            return ret
        case let .OSError(err):
            if let e = err {
                return "\(e)"
            }
            return "An unknown system error"
        }
    }
}

func utf8Decode(data: Data) -> String {
    return NSString(data: data, encoding: String.Encoding.utf8.rawValue)! as String
}

func asciiEscape(s: String) -> String {
    var out: String = ""
    
    for char in s.unicodeScalars {
        var esc = "\(char)"
        if !char.isASCII {
            esc = NSString(format:"\\u%04x", char.value) as String
        } else {
            esc = "\(char)"
        }
        out += esc
        
    }
    return out
}

public enum RouteStyle: String {
    case Rpc = "rpc"
    case Upload = "upload"
    case Download = "download"
    case Other
}

public enum UploadBody {
    case Data(Data)
    case File(NSURL)
    case Stream(InputStream)
}

/// These objects are constructed by the SDK; users of the SDK do not need to create them manually.
///
/// Pass in a closure to the `response` method to handle a response or error.
public class Request<RSerial: JSONSerializer, ESerial: JSONSerializer> {
    let request: Alamofire.Request
    let responseSerializer: RSerial
    let errorSerializer: ESerial
    
    init(request: Alamofire.Request, responseSerializer: RSerial, errorSerializer: ESerial) {
        self.errorSerializer = errorSerializer
        self.responseSerializer = responseSerializer
        self.request = request
    }
    
    public func progress(closure: ((Int64, Int64, Int64) -> Void)? = nil) -> Self {
        self.request.progress()
        return self
    }
    
    public func cancel() {
        self.request.cancel()
    }
    
    func handleResponseError(response: HTTPURLResponse?, data: Data?, error: Error?) -> CallError<ESerial.ValueType> {
        let requestId = response?.allHeaderFields["X-Dropbox-Request-Id"] as? String
        if let code = response?.statusCode {
            switch code {
            case 500...599:
                var message = ""
                if let d = data {
                    message = utf8Decode(data: d)
                }
                return .InternalServerError(code, message, requestId)
            case 400:
                var message = ""
                if let d = data {
                    message = utf8Decode(data: d)
                }
                return .BadInputError(message, requestId)
            case 401:
                let json = SerializeUtil.parseJSON(data: data!)
                switch json {
                case .Dictionary(let d):
                    return .AuthError(Auth.AuthErrorSerializer().deserialize(json: d["error"]!), requestId)
                default:
                    fatalError("Failed to parse error type")
                }
            case 403, 404, 409:
                let json = SerializeUtil.parseJSON(data: data!)
                switch json {
                case .Dictionary(let d):
                    return .RouteError(Box(self.errorSerializer.deserialize(d["error"]!)), requestId)
                default:
                    fatalError("Failed to parse error type")
                }
            case 429:
                let json = SerializeUtil.parseJSON(data: data!)
                switch json {
                case .Dictionary(let d):
                    return .RateLimitError(Auth.RateLimitErrorSerializer().deserialize(json: d["error"]!), requestId)
                default:
                    fatalError("Failed to parse error type")
                }
            case 200:
                return .OSError(error)
            default:
                return .HTTPError(code, "An error occurred.", requestId)
            }
        } else if response == nil {
            return .OSError(error)
        } else {
            var message = ""
            if let d = data {
                message = utf8Decode(data: d)
            }
            return .HTTPError(nil, message, requestId)
        }
    }
}

/// An "rpc-style" request
public class RpcRequest<RSerial: JSONSerializer, ESerial: JSONSerializer>: Request<RSerial, ESerial> {
    public override init(request: Alamofire.Request, responseSerializer: RSerial, errorSerializer: ESerial) {
        super.init(request: request, responseSerializer: responseSerializer, errorSerializer: errorSerializer)
    }

    public func response(completionHandler: @escaping (RSerial.ValueType?, CallError<ESerial.ValueType>?) -> Void) -> Self {
        self.request.validate().response {
            (request, response, dataObj, error) -> Void in
            let data = dataObj!
            if error != nil {
                completionHandler(nil, self.handleResponseError(response: response, data: data, error: error))
            } else {
                completionHandler(self.responseSerializer.deserialize(SerializeUtil.parseJSON(data: data)), nil)
            }
        }
        return self
    }
}

/// An "upload-style" request
public class UploadRequest<RSerial: JSONSerializer, ESerial: JSONSerializer>: Request<RSerial, ESerial> {
    public override init(request: Alamofire.Request, responseSerializer: RSerial, errorSerializer: ESerial) {
        super.init(request: request, responseSerializer: responseSerializer, errorSerializer: errorSerializer)
    }

    public func response(completionHandler: @escaping (RSerial.ValueType?, CallError<ESerial.ValueType>?) -> Void) -> Self {
        self.request.validate().response {
            (request, response, dataObj, error) -> Void in
            let data = dataObj!
            if error != nil {
                completionHandler(nil, self.handleResponseError(response: response, data: data, error: error))
            } else {
                completionHandler(self.responseSerializer.deserialize(SerializeUtil.parseJSON(data: data)), nil)
            }
        }
        return self
    }
}


/// A "download-style" request to a file
public class DownloadRequestFile<RSerial: JSONSerializer, ESerial: JSONSerializer>: Request<RSerial, ESerial> {
    public var urlPath: URL?
    public var errorMessage: Data

    public override init(request: Alamofire.Request, responseSerializer: RSerial, errorSerializer: ESerial) {
        urlPath = nil
        errorMessage = Data()
        super.init(request: request, responseSerializer: responseSerializer, errorSerializer: errorSerializer)
    }

    public func response(completionHandler: @escaping ((RSerial.ValueType, URL)?, CallError<ESerial.ValueType>?) -> Void) -> Self {
        self.request.validate()
            .response {
            (request, response, data, error) -> Void in
            if error != nil {
                completionHandler(nil, self.handleResponseError(response: response, data: self.errorMessage, error: error))
            } else {
                let result = response!.allHeaderFields["Dropbox-Api-Result"] as! String
                let resultData = result.data(using: String.Encoding.utf8, allowLossyConversion: false)!
                let resultObject = self.responseSerializer.deserialize(SerializeUtil.parseJSON(data: resultData))
                
                completionHandler((resultObject, self.urlPath!), nil)
            }
        }
        return self
    }
}

/// A "download-style" request to memory
public class DownloadRequestMemory<RSerial: JSONSerializer, ESerial: JSONSerializer>: Request<RSerial, ESerial> {
    public override init(request: Alamofire.Request, responseSerializer: RSerial, errorSerializer: ESerial) {
        super.init(request: request, responseSerializer: responseSerializer, errorSerializer: errorSerializer)
    }

    public func response(completionHandler: @escaping ((RSerial.ValueType, Data)?, CallError<ESerial.ValueType>?) -> Void) -> Self {
        self.request.validate()
            .response {
                (request, response, data, error) -> Void in
                if error != nil {
                    completionHandler(nil, self.handleResponseError(response: response, data: data, error: error))
                } else {
                    let result = response!.allHeaderFields["Dropbox-Api-Result"] as! String
                    let resultData = result.data(using: String.Encoding.utf8, allowLossyConversion: false)!
                    let resultObject = self.responseSerializer.deserialize(SerializeUtil.parseJSON(data: resultData))

                    completionHandler((resultObject, data!), nil)
                }
        }
        return self
    }
}
