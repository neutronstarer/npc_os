//
//  ViewController.swift
//  Example iOS
//
//  Created by neutronstarer on 2021/12/17.
//

import UIKit
import NPC

class ViewController: UIViewController {

    @IBOutlet weak var textFeild: UITextField!
    
    @IBOutlet weak var label: UILabel!
    
    @IBOutlet weak var button: UIButton!
    
    var cancel: Cancel?
    
    lazy var n0: NPC = {[weak self] in
        let v = NPC()
        v.send = {[weak self] message in
            debugPrint("0_SEND: \(message)")
            self?.n1.receive(message)
        }
        self?.config(v)
        return v
    }()
    
    lazy var n1: NPC = {[weak self] in
        let v = NPC()
        v.send = {[weak self] message in
            debugPrint("1_SEND: \(message)")
            self?.n0.receive(message)
        }
        self?.config(v)
        return v
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
    }

    @IBAction func click(_ sender: Any) {
        if let cancel = cancel {
            cancel()
            self.cancel = nil
            self.button.setTitle("Download", for: .normal)
            return
        }
        self.button.setTitle("Cancel", for: .normal)
        self.cancel = n0.deliver("download", param: "/path", timeout: Double(textFeild.text ?? "0") ?? 0, onReply: {[weak self] param, error in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async {
                self.cancel = nil
                self.button.setTitle("Download", for: .normal)
                if let error = error as? String {
                    self.label.text = error
                    return
                }
                if let param = param as? String {
                    self.label.text = param
                    return
                }
            }
        },onNotify: {[weak self] param in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async {
                self.label.text = param as? String
            }
        })
    }
    
    
    private func config(_ npc: NPC){
        npc.on("download") { param, notify, reply in
            var i = 0
            var completed = false
            let timer = DispatchSource.makeTimerSource()
            timer.setEventHandler {
                i += 1
                if i<10 {
                    notify("progress=\(i)/10")
                    return
                }
                if completed {
                    return
                }
                completed = true
                timer.cancel()
                reply("did download to \(param ?? "")", nil)
            }
            timer.schedule(deadline: .now()+1, repeating: 1)
            timer.resume()
            return {
                if (completed){
                    return
                }
                completed = true
                timer.cancel()
            }
        }
    }
}

