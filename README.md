# npc_os
Near Procedure Call.

# Usage

### Create instance
```swift
let npc = NPC({message in 
    // send message to near npc
})
```

### register handle
```swift
npc.on("ping") { param, notify, reply in
    // reply content
    reply("pong", nil)
    // return a cancel function which could be nil.
    return nil
}
```

### deliver

```swift
n0.deliver("ping", param: nil, timeout: 0, onNotify: {param in
    // param is notification
}, onReply:{param, error in
    //param is repication
    //error is error-replication
})
```
### More usage is in example app.