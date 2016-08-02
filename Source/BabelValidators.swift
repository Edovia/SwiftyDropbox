import Foundation

// The objects in this file are used by generated code and should not need to be invoked manually.

var _assertFunc: (Bool,String) -> Void = { cond, message in precondition(cond, message) }

public func setAssertFunc( _ assertFunc: (Bool, String) -> Void) {
    _assertFunc = assertFunc
}


public func arrayValidator<T>(minItems : Int? = nil, maxItems : Int? = nil, itemValidator: (T) -> Void) -> (Array<T>) -> Void {
    return {(value: Array<T>) -> Void in
        if let min = minItems {
            _assertFunc(value.count >= min, "\(value) must have at least \(min) items")
        }
        
        if let max = maxItems {
            _assertFunc(value.count <= max, "\(value) must have at most \(max) items")
        }
        
        for el in value {
            itemValidator(el)
        }
    }
}

public func stringValidator(minLength : Int? = nil, maxLength : Int? = nil, pattern: String? = nil) -> (String) -> Void {
    return {(value: String) -> Void in
        let length = value.characters.count
        if let min = minLength {
            _assertFunc(length >= min, "\"\(value)\" must be at least \(min) characters")
        }
        if let max = maxLength {
            _assertFunc(length <= max, "\"\(value)\" must be at most \(max) characters")
        }
        
        if let pat = pattern {
            // patterns much match entire input sequence
            let re = try! NSRegularExpression(pattern: "\\A(?:\(pat))\\z", options: NSRegularExpression.Options())
            let matches = re.matches(in: value, options: NSRegularExpression.MatchingOptions(), range: NSMakeRange(0, length))
            _assertFunc(matches.count > 0, "\"\(value) must match pattern \"\(re.pattern)\"")
        }
    }
}

public func comparableValidator<T: Comparable>(minValue : T? = nil, maxValue : T? = nil) -> (T) -> Void {
    return {(value: T) -> Void in
        if let min = minValue {
            _assertFunc(min <= value, "\(value) must be at least \(min)")
        }
        
        if let max = maxValue {
            _assertFunc(max >= value, "\(value) must be at most \(max)")
        }
    }
}

public func nullableValidator<T>(_ internalValidator : (T) -> Void) -> (T?) -> Void {
    return {(value: T?) -> Void in
        if let v = value {
            internalValidator(v)
        }
    }
}

public func binaryValidator(minLength : Int?, maxLength: Int?, _ value: Data) -> Void {
    let length = value.count
    if let min = minLength {
        _assertFunc(length >= min, "\"\(value)\" must be at least \(min) bytes")
    }
    if let max = maxLength {
        _assertFunc(length <= max, "\"\(value)\" must be at most \(max) bytes")
    }
}
