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
/// `NPC`  Near Procedure Call.
open class NPC: NSObject {
    /// If `send` is nil, you should extends NPC and override `send(_ message: Message)`.
    @objc
    public init(_ send: Send?){
        super.init()
        if let send = send {
            _send = send
        }else{
            _send = {[weak self] message in
                self?.send(message)
            }
        }
    }
    /// Register handle by method name.
    @objc
    open func on(_ method: String, handle: @escaping Handle){
        _semphore.wait()
        defer{
            _semphore.signal()
        }
        _handlers[method] = handle
    }
    /// Emit method without reply.
    @objc
    open func emit(_ method: String, param: Any? = nil){
        let m = Message(typ: .emit, method: method, param: param)
        _send!(m)
    }
    
    /// Deliver message with reply.
    @objc
    @discardableResult
    open func deliver(_ method: String, param: Any? = nil, timeout: TimeInterval = 0, onNotify: Notify? = nil, onReply: Reply? = nil)->Cancel{
        var completed = false
        let completedSemphore = DispatchSemaphore(value: 1)
        var timer: DispatchSourceTimer?
        _semphore.wait()
        let id = _id
        _id += 1
        let reply = {[weak self] (_ param: Any?, _ error: Any?)->Bool in
            completedSemphore.wait()
            if (completed){
                completedSemphore.signal()
                return false
            }
            completed = true
            completedSemphore.signal()
            timer?.cancel()
            onReply?(param, error)
            guard let self = self else {
                return true
            }
            let semphonre = self._semphore
            semphonre.wait()
            self._notifies.removeValue(forKey: id)
            self._replies.removeValue(forKey: id)
            semphonre.signal()
            return true
        }
        _replies[id] = reply
        if let notify = onNotify {
            _notifies[id] = {param in
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completedSemphore.signal()
                notify(param);
            }
        }
        _semphore.signal()
        if  timeout > 0 {
            timer = DispatchSource.makeTimerSource(flags: [], queue: _queue)
            timer!.schedule(deadline: .now()+timeout)
            timer!.setEventHandler(handler: {[weak self] in
                if reply(nil, "timedout") {
                    guard let self = self else {
                        return
                    }
                    let m = Message(typ: .cancel, id: id)
                    self._send!(m)
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
                self._send!(m)
            }
        }
        let m = Message(typ: .deliver, id: id, method: method, param: param)
        _send!(m)
        return cancel
    }
    
    /// Send message.
    @objc
    open func send(_ message: Message){
        /// override this method
    }
    
    /// Receive message.
    @objc
    open func receive(_ message: Message){
        switch(message.typ){
        case .emit:
            _semphore.wait()
            guard let method = message.method, let handle = _handlers[method] else{
                _semphore.signal()
                break
            }
            _semphore.signal()
            let _ = handle(message.param, {param in}, {param,error in})
            break
        case .deliver:
            var completed = false
            let completedSemphore = DispatchSemaphore(value: 1)
            _semphore.wait()
            let id = message.id
            guard let method = message.method, let handle = _handlers[method] else{
                _semphore.signal()
                break
            }
            _semphore.signal()
            let cancel = handle(message.param, {[weak self] param in
                guard let self = self else {
                    return
                }
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completedSemphore.signal()
                let m = Message(typ: .notify, id: id, param: param)
                self._send!(m)
            }, {[weak self] param ,error in
                guard let self = self else {
                    return
                }
                completedSemphore.wait()
                if (completed){
                    completedSemphore.signal()
                    return
                }
                completed = true
                completedSemphore.signal()
                let semphore = self._semphore
                semphore.wait()
                self._cancels.removeValue(forKey: id)
                semphore.signal()
                let m = Message(typ: .ack, id: id, param: param, error: error)
                self._send!(m)
            })
            if let cancel = cancel {
                _semphore.wait()
                _cancels[id] = {[weak self] in
                    guard let self = self else {
                        return
                    }
                    completedSemphore.wait()
                    if (completed){
                        completedSemphore.signal()
                        return
                    }
                    completed = true
                    completedSemphore.signal()
                    let semphore = self._semphore
                    semphore.wait()
                    self._cancels.removeValue(forKey: id)
                    semphore.signal()
                    cancel()
                }
                _semphore.signal()
            }
            break
        case .ack:
            _semphore.wait()
            let id = message.id
            guard let onReply = _replies[id] else {
                _semphore.signal()
                break
            }
            _semphore.signal()
            let _ = onReply(message.param, message.error)
            break
        case .notify:
            _semphore.wait()
            let id = message.id
            guard  let onNotify = _notifies[id] else {
                _semphore.signal()
                break
            }
            _semphore.signal()
            onNotify(message.param)
            break
        case .cancel:
            _semphore.wait()
            let id = message.id
            guard let cancel = _cancels[id] else {
                _semphore.signal()
                break
            }
            _semphore.signal()
            cancel()
            break
        }
    }
  
    private var _id = 0
    private var _send: Send?
    private let _semphore = DispatchSemaphore(value: 1)
    private let _queue = DispatchQueue(label: "com.nuetronstarer.npc")
    private lazy var _cancels = Dictionary<Int, Cancel>()
    private lazy var _notifies = Dictionary<Int, Notify>()
    private lazy var _replies = Dictionary<Int, (_ param: Any?, _ error: Any?)->Bool>()
    private lazy var _handlers = Dictionary<String, Handle>()
}

/// Message type.
@objc
public enum Typ: Int{
    case emit
    case deliver
    case notify
    case ack
    case cancel
}

/// Message class.
open class Message: NSObject{
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
