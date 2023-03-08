import Foundation

/// Cancel.
public typealias Cancel = ()->Void
/// Method Handle.
public typealias Handle = (_ param: Any?, _ reply: @escaping Reply, _ notify: @escaping Notify) -> Cancel?
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
        cleanUp(with: "disconnected")
    }
    
    @objc
    public override init(){
        super.init()
    }
    
    /// Must set this value before work.
    @objc
    public var send: Send!

    /// Register handle by method name.
    @objc
    public func on(_ method: String, handle: Handle?){
        self[method] = handle
    }
    
    /// Register handle by method name.
    public subscript(_ method: String) -> Handle? {
        get{
            _semphore.wait()
            let handle = _handlers[method]
            _semphore.signal()
            return handle
        }
        set{
            _semphore.wait()
            _handlers[method] = newValue
            _semphore.signal()
        }
    }
    /// Emit method without reply.
    @objc
    public func emit(_ method: String, param: Any? = nil){
        _semphore.wait()
        let id = nextId()
        _semphore.signal()
        let m = Message(typ: .emit, id: id, method: method, param: param)
        send(m)
    }
    
    /// Deliver message with reply.
    @objc
    @discardableResult
    public func deliver(_ method: String, param: Any? = nil, timeout: TimeInterval = 0, onReply: Reply? = nil, onNotify: Notify? = nil)->Cancel{
        _semphore.wait()
        let id = nextId()
        var completed = false
        let completedSemphore = DispatchSemaphore(value: 1)
        var timer: DispatchSourceTimer?
        var onReply = onReply
        let reply = {[weak self] (_ param: Any?, _ error: Any?)->Bool in
            completedSemphore.wait()
            if (completed){
                completedSemphore.signal()
                return false
            }
            completed = true
            completedSemphore.signal()
            timer?.cancel()
            timer = nil
            onReply?(param, error)
            onReply = nil
            guard let self = self else {
                return true
            }
            let semphore = self._semphore
            semphore.wait()
            self._notifies.removeValue(forKey: id)
            self._replies.removeValue(forKey: id)
            semphore.signal()
            return true
        }
        _replies[id] = reply
        if let onNotify = onNotify {
            _notifies[id] = {param in
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completedSemphore.signal()
                onNotify(param)
            }
        }
        _semphore.signal()
        if timeout > 0 {
            timer = DispatchSource.makeTimerSource(flags: [], queue: _queue)
            timer!.schedule(deadline: .now() + .nanoseconds(Int(timeout*1000000000)))
            timer!.setEventHandler(handler: {[weak self] in
                if reply(nil, "timedout") {
                    guard let self = self else {
                        return
                    }
                    let m = Message(typ: .cancel, id: id)
                    self.send(m)
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
                self.send(m)
            }
        }
        let m = Message(typ: .deliver, id: id, method: method, param: param)
        send(m)
        return cancel
    }

    /// Receive message.
    @objc
    public func receive(_ message: Message){
        switch(message.typ){
        case .emit:
            guard let method = message.method else{
                debugPrint("[NPC] bad message: \(message)")
                break
            }
            _semphore.wait()
            guard let handle = _handlers[method] else {
                _semphore.signal()
                debugPrint("[NPC] unhandled message: \(message)")
                break
            }
            _semphore.signal()
            let _ = handle(message.param,  {param,error in}, {param in})
        case .deliver:
            var completed = false
            let completedSemphore = DispatchSemaphore(value: 1)
            let id = message.id
            guard let method = message.method else {
                debugPrint("[NPC] bad message: \(message)")
                break
            }
            _semphore.wait()
            guard let handle = _handlers[method] else {
                _semphore.signal()
                debugPrint("[NPC] unhandled message: \(message)")
                let m = Message(typ: .ack, id: id, error: "unimplemented")
                send(m)
                break
            }
            _semphore.signal()
            let cancel = handle(message.param, {[weak self] param, error in
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completed = true
                completedSemphore.signal()
                guard let self = self else {
                    return
                }
                let semphore = self._semphore
                semphore.wait()
                self._cancels.removeValue(forKey: id)
                semphore.signal()
                let m = Message(typ: .ack, id: id, param: param, error: error)
                self.send(m)
            }, {[weak self] param in
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completedSemphore.signal()
                guard let self = self else {
                    return
                }
                let m = Message(typ: .notify, id: id, param: param)
                self.send(m)
            })
            if let cancel = cancel {
                _semphore.wait()
                _cancels[id] = {[weak self] in
                    completedSemphore.wait()
                    if (completed){
                        completedSemphore.signal()
                        return
                    }
                    completed = true
                    completedSemphore.signal()
                    cancel()
                    guard let self = self else {
                        return
                    }
                    let semphore = self._semphore
                    semphore.wait()
                    self._cancels.removeValue(forKey: id)
                    semphore.signal()
                }
                _semphore.signal()
            }
        case .ack:
            _semphore.wait()
            let reply = _replies[message.id]
            _semphore.signal()
            let _ = reply?(message.param, message.error)
        case .notify:
            _semphore.wait()
            let notify = _notifies[message.id]
            _semphore.signal()
            notify?(message.param)
        case .cancel:
            _semphore.wait()
            let cancel = _cancels[message.id]
            _semphore.signal()
            cancel?()
        }
    }
    
    /// Clean up all deliveries with special reason,  used when the connection is down.
    @objc
    public func cleanUp(with reason: Any?){
        _semphore.wait()
        _replies.forEach { (_,value) in
            _ = value(nil,reason)
        }
        _semphore.signal()
    }
    
    private func nextId() -> Int{
        if _id < 0x7fffffff {
            _id += 1
        }else{
            _id = 0
        }
        return _id
    }
    
    private var _id = -1
    private let _semphore = DispatchSemaphore(value: 1)
    private let _queue = DispatchQueue(label: "com.nuetronstarer.npc")
    private lazy var _cancels = Dictionary<Int, Cancel>()
    private lazy var _notifies = Dictionary<Int, Notify>()
    private lazy var _replies = Dictionary<Int, (_ param: Any?, _ error: Any?) -> Bool>()
    private lazy var _handlers = Dictionary<String, Handle>()
}
