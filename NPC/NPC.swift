import Foundation

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

/// Message class.
public final class Message: NSObject{
    /// Message type.
    @objc
    public enum Typ: Int {
        case emit
        case deliver
        case notify
        case ack
        case cancel
    }
    @objc
    public init(typ: Typ, id: Int, method: String? = nil, param: Any? = nil, error: Any? = nil){
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
    
    public override var description: String{
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

/// `NPC`  Near Procedure Call.
public final class NPC: NSObject {
    
    deinit {
        cleanUpDeliveries(with: "disconnected")
    }
    
    @objc
    public override init(){
        super.init()
    }
    
    /// Must set this value before work.
    @objc
    public var send: Send?

    /// Register handle by method name.
    @objc
    public func on(_ method: String, handle: Handle?){
        self[method] = handle
    }
    
    /// Register handle by method name.
    public subscript(_ method: String) -> Handle? {
        get{
            _semphore.wait()
            defer{
                _semphore.signal()
            }
            return _handlers[method]
        }
        set{
            _semphore.wait()
            defer{
                _semphore.signal()
            }
            _handlers[method] = newValue
        }
    }
    /// Emit method without reply.
    @objc
    public func emit(_ method: String, param: Any? = nil){
        _semphore.wait()
        defer{
            _semphore.signal()
        }
        let m = Message(typ: .emit, id: nextId(), method: method, param: param)
        send!(m)
    }
    
    /// Deliver message with reply.
    @objc
    @discardableResult
    public func deliver(_ method: String, param: Any? = nil, timeout: TimeInterval = 0, onReply: Reply? = nil, onNotify: Notify? = nil)->Cancel{
        _semphore.wait()
        defer{
            _semphore.signal()
        }
        var completed = false
        let completedSemphore = DispatchSemaphore(value: 1)
        var timer: DispatchSourceTimer?
        let id = nextId()
        let reply = {[weak self] (_ param: Any?, _ error: Any?)->Bool in
            completedSemphore.wait()
            defer{
                completedSemphore.signal()
            }
            if (completed){
                return false
            }
            completed = true
            onReply?(param, error)
            timer?.cancel()
            timer = nil
            guard let self = self else {
                return true
            }
            let semphore = self._semphore
            semphore.wait()
            defer{
                semphore.signal()
            }
            self._notifies.removeValue(forKey: id)
            self._replies.removeValue(forKey: id)
            return true
        }
        _replies[id] = reply
        if let onNotify = onNotify {
            _notifies[id] = {param in
                completedSemphore.wait()
                defer{
                    completedSemphore.signal()
                }
                if (completed){
                    return
                }
                onNotify(param);
            }
        }
        if timeout > 0 {
            timer = DispatchSource.makeTimerSource(flags: [], queue: _queue)
            timer!.schedule(deadline: .now() + .nanoseconds(Int(timeout*1000000000)))
            timer!.setEventHandler(handler: {[weak self] in
                if reply(nil, "timedout") {
                    guard let self = self else {
                        return
                    }
                    let m = Message(typ: .cancel, id: id)
                    self.send!(m)
                }
            })
            timer!.resume()
        }
        let cancel = {[weak self] in
            if reply(nil, "cancelled"){
                guard let self = self else {
                    return
                }
                let m = Message(typ: .cancel, id: id)
                self.send!(m)
            }
        }
        let m = Message(typ: .deliver, id: id, method: method, param: param)
        send!(m)
        return cancel
    }
    /// Clean up all deliveries with special reason.
    @objc
    public func cleanUpDeliveries(with reason: Any?){
        _semphore.wait()
        defer{
            _semphore.signal()
        }
        _replies.forEach { (_,value) in
            _ = value(nil,reason)
        }
    }
    
    /// Receive message.
    @objc
    public func receive(_ message: Message){
        switch(message.typ){
        case .emit:
            _semphore.wait()
            defer{
                _semphore.signal()
            }
            guard let method = message.method, let handle = _handlers[method] else{
                break
            }
            let _ = handle(message.param, {param in}, {param,error in})
            break
        case .deliver:
            var completed = false
            let completedSemphore = DispatchSemaphore(value: 1)
            _semphore.wait()
            defer{
                _semphore.signal()
            }
            let id = message.id
            guard let method = message.method, let handle = _handlers[method] else{
                break
            }
            let cancel = handle(message.param, {[weak self] param in
                guard let self = self else {
                    return
                }
                completedSemphore.wait()
                defer{
                    completedSemphore.signal()
                }
                if (completed){
                    return
                }
                let m = Message(typ: .notify, id: id, param: param)
                self.send!(m)
            }, {[weak self] param ,error in
                guard let self = self else {
                    return
                }
                completedSemphore.wait()
                defer{
                    completedSemphore.signal()
                }
                if (completed){
                    return
                }
                completed = true
                let semphore = self._semphore
                semphore.wait()
                defer{
                    semphore.signal()
                }
                self._cancels.removeValue(forKey: id)
                let m = Message(typ: .ack, id: id, param: param, error: error)
                self.send!(m)
            })
            if let cancel = cancel {
                _cancels[id] = {[weak self] in
                    guard let self = self else {
                        return
                    }
                    completedSemphore.wait()
                    defer{
                        completedSemphore.signal()
                    }
                    if (completed){
                        return
                    }
                    completed = true
                    self._cancels.removeValue(forKey: id)
                    cancel()
                }
            }
            break
        case .ack:
            _semphore.wait()
            defer {
                _semphore.signal()
            }
            let id = message.id
            guard let onReply = _replies[id] else {
                break
            }
            let _ = onReply(message.param, message.error)
            break
        case .notify:
            _semphore.wait()
            defer {
                _semphore.signal()
            }
            let id = message.id
            guard  let onNotify = _notifies[id] else {
                break
            }
            onNotify(message.param)
            break
        case .cancel:
            _semphore.wait()
            defer {
                _semphore.signal()
            }
            let id = message.id
            guard let cancel = _cancels[id] else {
                break
            }
            cancel()
            break
        }
    }
    private func nextId() -> Int{
        if _id < Int.max {
            _id += 1
        }else{
            _id = 0
        }
        return _id
    }
    private var _id = 0
    private let _semphore = DispatchSemaphore(value: 1)
    private let _queue = DispatchQueue(label: "com.nuetronstarer.npc")
    private lazy var _cancels = Dictionary<Int, Cancel>()
    private lazy var _notifies = Dictionary<Int, Notify>()
    private lazy var _replies = Dictionary<Int, (_ param: Any?, _ error: Any?) -> Bool>()
    private lazy var _handlers = Dictionary<String, Handle>()
}
