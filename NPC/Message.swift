//
//  Message.swift
//  NPC
//
//  Created by neutronstarer on 2023/3/2.
//

import Foundation
/// Message type.
@objc
public enum Typ: Int {
    case emit
    case deliver
    case notify
    case ack
    case cancel
}

/// Message class.
open class Message: NSObject{
    @objc
    public init(typ: Typ, id: Int = 0, method: String? = nil, param: Any? = nil, error: Any? = nil){
        self.typ = typ
        self.id = id
        self.method = method
        self.param = param
        self.error = error
    }
    @objc
    public let typ: Typ
    @objc
    public let id: Int
    @objc
    public let method: String?
    @objc
    public let param: Any?
    @objc
    public let error: Any?
    
    open override var description: String{
        get {
            var v = Dictionary<String, Any>()
            v["typ"] = typ.rawValue
            v["id"] = id
            if let method = method {
                v["method"] = method
            }
            if let param = param {
                v["param"] = param
            }
            if let error = error {
                v["error"] = error
            }
            return v.description
        }
    }
}

/// Cancel.
public typealias Cancel = ()->Void
/// Method Handle.
public typealias Handle = (_ param: Any?, _ notify: @escaping Notify, _ reply: @escaping Reply) -> Cancel?
/// Notify.
public typealias Notify = (_ param: Any?) -> Void
/// Reply.
public typealias Reply = (_ param: Any?, _ error: Any?) -> Void
/// Send message.
public typealias Send = (_ message: Message) -> Void
