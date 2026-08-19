//
//  CallMonitor.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/9/26.
//

import Foundation
import CallKit
import Combine

/// Watches for phone calls via CallKit to reflect Call state in UI.
class CallMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published var isOnCall: Bool = false
    private let callObserver = CXCallObserver()
    private weak var recordingVM: RecordingViewModel?
    
    init(recordingVM: RecordingViewModel? = nil) {
        self.recordingVM = recordingVM
        super.init()
        callObserver.setDelegate(self, queue: nil)
        checkInitialState()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.checkInitialState()
        }
    }
    
    func setupViewModel(_ vm: RecordingViewModel) {              // ← ADD THIS METHOD
            self.recordingVM = vm
        }
    
    /// A call counts as "active" if connected or dialing out.
    private func isPickedUpOrDialed(_ call: CXCall) -> Bool {
        let isPickedUpIncoming = !call.isOutgoing && call.hasConnected && !call.hasEnded
        let isOutgoingDialed = call.isOutgoing && !call.hasEnded
        return isPickedUpIncoming || isOutgoingDialed
    }
    
    private func checkInitialState() {
        let activePickedUpCalls = callObserver.calls.filter(isPickedUpOrDialed)
        self.isOnCall = !activePickedUpCalls.isEmpty
    }
    
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let activePickedUpCalls = self.callObserver.calls.filter(self.isPickedUpOrDialed)
            self.isOnCall = !activePickedUpCalls.isEmpty
        }
    }
}
