//
//  CallMonitor.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/9/26.
//

import Foundation
import CallKit
import Combine

class CallMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published var isOnCall: Bool = false
    private let callObserver = CXCallObserver()
    
    // We will pass a reference to the view model so the monitor can forcefully stop the camera
    private var recordingVM: RecordingViewModel?
    
    init(recordingVM: RecordingViewModel? = nil) {
        self.recordingVM = recordingVM
        super.init()
        callObserver.setDelegate(self, queue: nil)
        checkInitialState()
    }
    
    /// Helper injection method if initialized without the VM first
    func setupViewModel(_ vm: RecordingViewModel) {
        self.recordingVM = vm
    }
    
    private func checkInitialState() {
        // A call is only considered "picked up/active" if it connected or is an outgoing call we dialed.
        let activePickedUpCalls = callObserver.calls.filter { call in
            // Incoming: It is NOT outgoing, it HAS connected (answered), and HAS NOT ended
            let isPickedUpIncoming = !call.isOutgoing && call.hasConnected && !call.hasEnded
            // Outgoing: We are dialing out, and it HAS NOT ended
            let isOutgoingDialed = call.isOutgoing && !call.hasEnded
            
            return isPickedUpIncoming || isOutgoingDialed
        }
        
        self.isOnCall = !activePickedUpCalls.isEmpty
    }
    
    // CallKit delegate triggers whenever a call state changes (Ringing -> Accepted -> Ended)
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Re-evaluate if any calls on the system are currently connected/answered
            let activePickedUpCalls = callObserver.calls.filter { c in
                let isPickedUpIncoming = !c.isOutgoing && c.hasConnected && !c.hasEnded
                let isOutgoingDialed = c.isOutgoing && !c.hasEnded
                return isPickedUpIncoming || isOutgoingDialed
            }
            
            let isCallNowActive = !activePickedUpCalls.isEmpty
            
            // 🚨 TRIGGER STATE SHIFT
            self.isOnCall = isCallNowActive
            
            // 🎬 CLEAN SHUTDOWN: If a call was just accepted and the app is recording, stop it!
            if isCallNowActive, let vm = self.recordingVM {
                if vm.recordingState == .active {
                    print("📞 Call accepted! Forcefully ending video recording session cleanly...")
                    vm.endSession(navigateToClips: false) // 👈 Set to false to stay on RecordView!
                }
            }
        }
    }
}
