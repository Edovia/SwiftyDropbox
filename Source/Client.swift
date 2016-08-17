import Foundation
import Alamofire

public class Box<T> {
	public let unboxed : T
	init (_ v : T) { self.unboxed = v }
}

public class BabelClient {
    var manager : SessionManager
    var baseHosts : [String : String]
    
    func additionalHeaders(_ noauth: Bool) -> [String: String] {
        return [:]
    }
    
    init(manager: SessionManager, baseHosts : [String : String]) {
        self.manager = manager
        self.baseHosts = baseHosts
    }
}

public enum CallError<EType> : CustomStringConvertible {
    case internalServerError(Int, String?, String?)
    case badInputError(String?, String?)
    case rateLimitError
    case httpError(Int?, String?, String?)
    case routeError(Box<EType>, String?)
    case osError(Error?)
    
    public var description : String {
        switch self {
        case let .internalServerError(code, message, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "Internal Server Error \(code)"
            if let m = message {
                ret += ": \(m)"
            }
            return ret
        case let .badInputError(message, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "Bad Input"
            if let m = message {
                ret += ": \(m)"
            }
            return ret
        case .rateLimitError:
            return "Rate limited"
        case let .httpError(code, message, requestId):
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
        case let .routeError(box, requestId):
            var ret = ""
            if let r = requestId {
                ret += "[request-id \(r)] "
            }
            ret += "API route error - \(box.unboxed)"
            return ret
        case let .osError(err):
            if let e = err {
                return "\(e)"
            }
            return "An unknown system error"
        }
    }
}

func utf8Decode(_ data: Data) -> String {
    return NSString(data: data, encoding: String.Encoding.utf8.rawValue)! as String
}

func asciiEscape(_ s: String) -> String {
    var out : String = ""

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


/// Represents a Babel request
///
/// These objects are constructed by the SDK; users of the SDK do not need to create them manually.
///
/// Pass in a closure to the `response` method to handle a response or error.
public class BabelRequest<RType : JSONSerializer, EType : JSONSerializer> {
    let errorSerializer : EType
    let responseSerializer : RType
    let request : Alamofire.Request
    
    init(request: Alamofire.Request,
        responseSerializer: RType,
        errorSerializer: EType)
    {
            self.errorSerializer = errorSerializer
            self.responseSerializer = responseSerializer
            self.request = request
    }
    

    
    func handleResponseError(_ response: HTTPURLResponse?, data: Data?, error: Error?) -> CallError<EType.ValueType> {
        let requestId = response?.allHeaderFields["X-Dropbox-Request-Id"] as? String
        if let code = response?.statusCode {
            switch code {
            case 500...599:
                var message = ""
                if let d = data {
                    message = utf8Decode(d)
                }
                return .internalServerError(code, message, requestId)
            case 400:
                var message = ""
                if let d = data {
                    message = utf8Decode(d)
                }
                return .badInputError(message, requestId)
            case 429:
                 return .rateLimitError
            case 403, 404, 409:
                let json = parseJSON(data!)
                switch json {
                case .dictionary(let d):
                    return .routeError(Box(self.errorSerializer.deserialize(d["error"]!)), requestId)
                default:
                    fatalError("Failed to parse error type")
                }
            case 200:
                return .osError(error)
            default:
                return .httpError(code, "An error occurred.", requestId)
            }
        } else {
            var message = ""
            if let d = data {
                message = utf8Decode(d)
            }
            return .httpError(nil, message, requestId)
        }
    }
}

/// An "rpc-style" request
public class BabelRpcRequest<RType : JSONSerializer, EType : JSONSerializer> : BabelRequest<RType, EType> {
    init(client: BabelClient, host: String, route: String, params: JSON, responseSerializer: RType, errorSerializer: EType) {
        let url = "\(client.baseHosts[host]!)\(route)"
        var headers = ["Content-Type": "application/json"]
        let noauth = (host == "notify")
        for (header, val) in client.additionalHeaders(noauth) {
            headers[header] = val
        }
        
        let request = client.manager.request(url, withMethod: .post, parameters: nil, encoding: .custom({ (convertible, _) -> (URLRequest, NSError?) in
            var mutableRequest = convertible.urlRequest
            mutableRequest.httpBody = dumpJSON(params)
            return (mutableRequest, nil)
        }), headers: headers)
        
        super.init(request: request,
            responseSerializer: responseSerializer,
            errorSerializer: errorSerializer)
        request.resume()
    }
    
    /// Called when a request completes.
    ///
    /// :param: completionHandler A closure which takes a (response, error) and handles the result of the call appropriately.
    public func response(_ completionHandler: @escaping (RType.ValueType?, CallError<EType.ValueType>?) -> Void) -> Self {
        self.request.validate().response {
            (request, response, dataObj, error) -> Void in
            let data = dataObj!
            if error != nil {
                completionHandler(nil, self.handleResponseError(response, data: data, error: error))
            } else {
                completionHandler(self.responseSerializer.deserialize(parseJSON(data)), nil)
            }
        }
        return self
    }
}

public enum BabelUploadBody {
    case data(Foundation.Data)
    case file(URL)
    case stream(InputStream)
}

public class BabelUploadRequest<RType : JSONSerializer, EType : JSONSerializer> : BabelRequest<RType, EType> {

    init(
        client: BabelClient,
        host: String,
        route: String,
        params: JSON, 
        responseSerializer: RType, errorSerializer: EType,
        body: BabelUploadBody) {
            let url = "\(client.baseHosts[host]!)\(route)"
            var headers = [
                "Content-Type": "application/octet-stream",
            ]
            let noauth = (host == "notify")
            for (header, val) in client.additionalHeaders(noauth) {
                headers[header] = val
            }
            
            if let data = dumpJSON(params) {
                let value = asciiEscape(utf8Decode(data))
                headers["Dropbox-Api-Arg"] = value
            }
            
            let request : Alamofire.Request
            
            switch body {
            case let .data(data):
                request = client.manager.upload(data, to: url, withMethod: .post, headers: headers)
            case let .file(file):
                request = client.manager.upload(file, to: url, withMethod: .post, headers: headers)
            case let .stream(stream):
                request = client.manager.upload(stream, to: url, withMethod: .post, headers: headers)
            }
            super.init(request: request,
                       responseSerializer: responseSerializer,
                       errorSerializer: errorSerializer)
            request.resume()
    }

    
    /// Called as the upload progresses.
    ///
    /// :param: closure
    ///         a callback taking three arguments (`bytesWritten`, `totalBytesWritten`, `totalBytesExpectedToWrite`)
    /// :returns: The request, for chaining purposes
    public func progress(_ closure: ((Int64, Int64, Int64) -> Void)? = nil) -> Self {
        self.request.progress(closure: closure)
        return self
    }
    
    /// Called when a request completes.
    ///
    /// :param: completionHandler 
    ///         A callback taking two arguments (`response`, `error`) which handles the result of the call appropriately.
    /// :returns: The request, for chaining purposes.
    public func response(_ completionHandler: @escaping (RType.ValueType?, CallError<EType.ValueType>?) -> Void) -> Self {
        self.request.validate().response {
            (request, response, dataObj, error) -> Void in
            let data = dataObj!
            if error != nil {
                completionHandler(nil, self.handleResponseError(response, data: data, error: error))
            } else {
                completionHandler(self.responseSerializer.deserialize(parseJSON(data)), nil)
            }
        }
        return self
    }

}

public class BabelDownloadRequest<RType : JSONSerializer, EType : JSONSerializer> : BabelRequest<RType, EType> {
    var urlPath : URL?
    init(client: BabelClient, host: String, route: String, params: JSON, responseSerializer: RType, errorSerializer: EType, destination: @escaping (URL, HTTPURLResponse) -> URL) {
        let url = "\(client.baseHosts[host]!)\(route)"
        var headers = [String : String]()
        urlPath = nil

        if let data = dumpJSON(params) {
            let value = asciiEscape(utf8Decode(data))
            headers["Dropbox-Api-Arg"] = value
        }
        
        let noauth = (host == "notify")
        for (header, val) in client.additionalHeaders(noauth) {
            headers[header] = val
        }
        
        weak var _self : BabelDownloadRequest<RType, EType>!
        
        let request = client.manager.download(url, to: { (url, resp) -> URL in
            let ret = destination(url, resp)
            _self.urlPath = ret
            return ret
            },
                                              withMethod: .post, parameters: nil, encoding: .url, headers: headers)

        super.init(request: request, responseSerializer: responseSerializer, errorSerializer: errorSerializer)
        _self = self
        request.resume()
    }
    
    /// Called as the download progresses
    /// 
    /// :param: closure
    ///         a callback taking three arguments (`bytesRead`, `totalBytesRead`, `totalBytesExpectedToRead`)
    /// :returns: The request, for chaining purposes.
    public func progress(_ closure: ((Int64, Int64, Int64) -> Void)? = nil) -> Self {
        self.request.progress(closure: closure)
        return self
    }
    
    /// Called when a request completes.
    ///
    /// :param: completionHandler
    ///         A callback taking two arguments (`response`, `error`) which handles the result of the call appropriately.
    /// :returns: The request, for chaining purposes.
    public func response(_ completionHandler: @escaping ( (RType.ValueType, URL)?, CallError<EType.ValueType>?) -> Void) -> Self {
        
        self.request.validate()
            .response {
            (request, response, dataObj, error) -> Void in
            if error != nil {
                let data = self.urlPath.flatMap { (try? Data(contentsOf: $0)) }
                completionHandler(nil, self.handleResponseError(response, data: data, error: error))
            } else {
                let result = response!.allHeaderFields["Dropbox-Api-Result"] as! String
                let resultData = result.data(using: String.Encoding.utf8, allowLossyConversion: false)!
                let resultObject = self.responseSerializer.deserialize(parseJSON(resultData))
                
                completionHandler( (resultObject, self.urlPath!), nil)
            }
        }
        return self
    }
}
