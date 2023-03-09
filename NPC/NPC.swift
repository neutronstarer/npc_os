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
    
    @objc
    public override init(){
        super.init()
    }
    
    deinit {
        disconnect()
    }
    
    @objc
    public func connect(_ send: @escaping Send){
        disconnect()
        queue.sync {
            self.send = send
        }
    }
    
    @objc
    public func disconnect(){
        queue.sync {
            let replies = self.replies.values
            let cancels = self.cancels.values
            replies.forEach { reply in
                _ = reply(nil, "disconnected")
            }
            cancels.forEach { cancel in
                cancel()
            }
            send = nil
        }
    }
    
    /// Register handle by method name.
    @objc
    public func on(_ method: String, handle: Handle?){
        self[method] = handle
    }
    
    /// Register handle by method name.
    @objc
    public subscript(_ method: String) -> Handle? {
        get{
            var handle: Handle?
            queue.sync {
                handle = handlers[method]
            }
            return handle
        }
        set{
            queue.sync {
                handlers[method] = newValue
            }
        }
    }
    /// Emit method without reply.
    @objc
    public func emit(_ method: String, param: Any? = nil) {
        queue.sync {
            let id = self.nextId()
            let m = Message(typ: .emit, id: id, method: method, param: param)
            self.send?(m)
        }
    }
    
    /// Deliver message with reply.
    @objc
    @discardableResult
    public func deliver(_ method: String, param: Any? = nil, timeout: TimeInterval = 0, onReply: Reply? = nil, onNotify: Notify? = nil)->Cancel{
        var cancel: (()->Void)!
        queue.sync {
            guard let send = send else{
                DispatchQueue.main.async {
                    onReply?(nil, "disconnected")
                }
                cancel = {}
                return
            }
            let id = nextId()
            var completed = false
            var timer: DispatchSourceTimer?
            var onReply = onReply
            let reply = {[weak self] (_ param: Any?, _ error: Any?)->Bool in
                // in queue
                if (completed){
                    return false
                }
                completed = true
                timer?.cancel()
                timer = nil
                onReply = nil
                DispatchQueue.main.async {
                    onReply?(param, error)
                }
                guard let self = self else {
                    return true
                }
                self.notifies.removeValue(forKey: id)
                self.replies.removeValue(forKey: id)
                return true
            }
            replies[id] = reply
            if let onNotify = onNotify {
                notifies[id] = {param in
                    if (completed){
                        return
                    }
                    DispatchQueue.main.async {
                        onNotify(param)
                    }
                }
            }
            if timeout > 0 {
                timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
                timer!.schedule(deadline: .now() + .nanoseconds(Int(timeout*1000000000)))
                timer!.setEventHandler(handler: {[weak self] in
                    if reply(nil, "timedout") {
                        let m = Message(typ: .cancel, id: id)
                        self?.send?(m)
                    }
                })
                timer!.resume()
            }
            cancel = {[weak self] in
                self?.queue.async {[weak self] in
                    if reply(nil, "cancelled"){
                        let m = Message(typ: .cancel, id: id)
                        self?.send?(m)
                    }
                }
                
            }
            let m = Message(typ: .deliver, id: id, method: method, param: param)
            send(m)
        }
        return cancel
    }
    
    /// Receive message.
    @objc
    public func receive(_ message: Message){
        queue.async {[weak self] in
            guard let self = self else {
                return
            }
            switch(message.typ){
            case .emit:
                guard let method = message.method, let handle = self.handlers[method] else {
                    debugPrint("[NPC] unhandled message: \(message)")
                    break
                }
                let param = message.param
                DispatchQueue.main.async {
                    let _ = handle(param, {param, error in}, {param in})
                }
            case .deliver:
                var completed = false
                let id = message.id
                guard let method = message.method, let handle = self.handlers[method] else {
                    debugPrint("[NPC] unhandled message: \(message)")
                    let m = Message(typ: .ack, id: id, error: "unimplemented")
                    self.send?(m)
                    break
                }
                let param = message.param
                var cancel: (()->Void)!
                DispatchQueue.main.sync {
                    cancel = handle(param, {[weak self] param, error in
                        /// in queue
                        self?.queue.async {
                            if (completed){
                                return
                            }
                            completed = true
                            self?.cancels.removeValue(forKey: id)
                            let m = Message(typ: .ack, id: id, param: param, error: error)
                            self?.send?(m)
                        }
                    }, {[weak self] param in
                        /// in queue
                        self?.queue.async {
                            if (completed){
                                return
                            }
                            let m = Message(typ: .notify, id: id, param: param)
                            self?.send?(m)
                        }
                    })
                }
                if let cancel = cancel {
                    self.cancels[id] = {[weak self] in
                        /// in queue
                        if (completed){
                            return
                        }
                        completed = true
                        self?.cancels.removeValue(forKey: id)
                        DispatchQueue.main.async {
                            cancel()
                        }
                    }
                }
            case .ack:
                let reply = self.replies[message.id]
                let _ = reply?(message.param, message.error)
            case .notify:
                let notify = self.notifies[message.id]
                notify?(message.param)
            case .cancel:
                let cancel = self.cancels[message.id]
                cancel?()
            }
        }
    }
    
    private func nextId() -> Int{
        if id < 2147483647 {
            id += 1
        }else{
            id = -2147483647
        }
        return id
    }
    
    private var send: Send?
    private var id = -2147483648
    private let queue = DispatchQueue(label: "com.nuetronstarer.npc")
    private lazy var cancels = Dictionary<Int, Cancel>()
    private lazy var notifies = Dictionary<Int, Notify>()
    private lazy var replies = Dictionary<Int, (_ param: Any?, _ error: Any?) -> Bool>()
    private lazy var handlers = Dictionary<String, Handle>()
}
