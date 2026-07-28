//
//  MultipeerManager.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/6/26.
//

import Foundation
import MultipeerConnectivity
import Combine
import UIKit

enum SyncCommand: Codable, Equatable {
    case startRecording
    case stopRecording
    case triggerClip(clipNumber: Int, uuid: UUID)
    case updateSettings(secondsBefore: Int, secondsAfter: Int)
    case requestHighlights
    case finishedSendingHighlights
    case preparingToSendHighlights(total: Int) // Announces the 1/5, 2/5 fraction size!
    case requestFullSessionVideo(sessionID: UUID)
    case startRecordingWithID(sessionID: UUID)
}

final class MultipeerManager: NSObject, ObservableObject {
    private let serviceType = "clipit-sync"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    
    weak var recordingVM: RecordingViewModel?
    
    var onFullVideoRequested: (() -> URL?)?
    
    // keep track of current device's role
    enum DeviceRole {
        case none
        case primary
        case secondary
    }

    @Published var currentRole: DeviceRole = .none
    
    // Published states for your SwiftUI UI to watch
    @Published var connectedPeers: [MCPeerID] = []
    @Published var latestCommandReceived: SyncCommand?
    @Published var isSuccessfullyConnected: Bool = false
    
    // 🌟 FULL VIDEO TRACKING (Percentage 0-100%)
    @Published var incomingFileProgress: Double = 0.0
    @Published var isTransferringFile: Bool = false
    @Published var newlyImportedFullVideoURL: URL?
    
    // 🌟 HIGHLIGHTS BATCH TRACKING (Fraction 1/5, 2/5...)
    @Published var isReceivingHighlightBatch: Bool = false
    @Published var expectedHighlightCount: Int = 0
    @Published var receivedHighlightCount: Int = 0
    @Published var importedVideoURLQueue: [URL] = []
    
    // 🌟 SECONDARY DEVICE ALERT STATE
    @Published var showFullVideoRequestAlert: Bool = false
    private var pendingFullVideoURL: URL?

    @Published var isHost: Bool = false
    
    @Published var isReceivingFullVideo = false
    @Published var isSendingFullVideo = false
    @Published var fullVideoProgress: Double = 0
    
    @Published var isSendingHighlightsBatch: Bool = false
    @Published var sentHighlightCount: Int = 0
    @Published var expectedSendingHighlightCount: Int = 0
    
    @Published var requestedSessionID: UUID?
    @Published var newlyImportedTargetSessionID: UUID? = nil
    
    var onHighlightReceived: ((URL) -> Void)?
    
    // Track progress individually by resource name instead of a single global Task
    private var activeProgressTasks: [String: Task<Void, Never>] = [:]
    
    override init() {
        super.init()
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session?.delegate = self
    }
    
    // MARK: - Connections Management
    
    func startHosting() {
        isHost = true
        stopAllNetworkServices()
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
        print("🚀 ClipIt Master Cam is advertising...")
    }
    
    func startBrowsing() {
        isHost = false
        stopAllNetworkServices()
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        print("🔍 ClipIt Follower Cam is actively scanning...")
    }
    
    func stopAllNetworkServices() {
        session?.disconnect()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
    }
    
    // MARK: - Data Dispatch Systems
    
    func sendCommand(_ command: SyncCommand) {
        guard let session = session, !session.connectedPeers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(command)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("❌ Failed to encode/send sync command: \(error.localizedDescription)")
        }
    }
    
    // 🌟 Helper method called by Primary phone's "Import Now" button
    func sendLargeFile(fileURL: URL, sessionID: UUID? = nil, isFullSessionVideo: Bool, completion: @escaping (Bool) -> Void) {
        guard let session = session, let targetPeer = session.connectedPeers.first else {
            completion(false)
            return
        }
        
        // 🌟 FIX: Bake the sessionID into the filename so the Host knows where to put it!
        let customResourceName: String
        if isFullSessionVideo, let sid = sessionID {
            customResourceName = "FullSession_\(sid.uuidString)_\(fileURL.lastPathComponent)"
        } else if isFullSessionVideo {
            customResourceName = "FullSession_\(fileURL.lastPathComponent)"
        } else {
            customResourceName = fileURL.lastPathComponent
        }
        
        if isFullSessionVideo {
            Task { @MainActor in
                self.isTransferringFile = true
                self.isSendingFullVideo = true
                self.fullVideoProgress = 0.0
                self.incomingFileProgress = 0.0
            }
        }
        
        let outboundProgress = session.sendResource(at: fileURL, withName: customResourceName, toPeer: targetPeer) { error in
            Task { @MainActor in
                if isFullSessionVideo {
                    self.isTransferringFile = false
                    self.isSendingFullVideo = false
                    self.fullVideoProgress = 0.0
                    self.incomingFileProgress = 0.0
                } else {
                    // 🌟 ITEM 2 UI FIX: Only update incremental fractional fractions HERE when a single highlight finishes!
                    self.sentHighlightCount += 1
                    
                    if self.expectedSendingHighlightCount > 0 {
                        // Update progress bar linearly (e.g., 0.33 -> 0.66 -> 1.0)
                        self.incomingFileProgress = Double(self.sentHighlightCount) / Double(self.expectedSendingHighlightCount)
                    }
                    
                    // If everything in this batch has been sent, clean up the UI
                    if self.sentHighlightCount >= self.expectedSendingHighlightCount {
                        self.isSendingHighlightsBatch = false
                        self.isTransferringFile = false
                        self.sentHighlightCount = 0
                        self.expectedSendingHighlightCount = 0
                        self.incomingFileProgress = 0.0
                    }
                }
                completion(error == nil)
            }
        }
        
        // 🌟 THE CRITICAL FIX: Only activate the continuous 100ms 0-100% loop if it is a SINGLE FULL VIDEO.
        // If it's a highlight, skip this loop completely so it doesn't overwrite your "1 of 3" fractional progress!
        if isFullSessionVideo, let progress = outboundProgress {
            Task { @MainActor in
                activeProgressTasks[customResourceName]?.cancel()
                activeProgressTasks[customResourceName] = Task { @MainActor in
                    while !progress.isFinished && !progress.isCancelled {
                        let currentFraction = progress.fractionCompleted
                        
                        self.fullVideoProgress = currentFraction
                        self.incomingFileProgress = currentFraction
                        
                        try? await Task.sleep(nanoseconds: 100_000_000) // update every 100ms
                    }
                    self.activeProgressTasks.removeValue(forKey: customResourceName)
                }
            }
        }
    }
    
    func confirmAndSendFullVideo() {
        guard let url = pendingFullVideoURL else { return }
        sendLargeFile(fileURL: url, isFullSessionVideo: true) { success in
            print("📤 Outbound full video transfer finished with success state: \(success)")
        }
        pendingFullVideoURL = nil // Clear it out
    }
    
    func clearPendingHighlightsBatch() {
        Task { @MainActor in
            self.importedVideoURLQueue.removeAll()
            self.isReceivingHighlightBatch = false
            self.expectedHighlightCount = 0
            self.receivedHighlightCount = 0
        }
    }
}

extension MultipeerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.connectedPeers = session.connectedPeers
            self.isSuccessfullyConnected = !session.connectedPeers.isEmpty
        }
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if let decodedCommand = try? JSONDecoder().decode(SyncCommand.self, from: data) {
            Task { @MainActor in
                self.latestCommandReceived = decodedCommand
                
                // Handle requests and commands in one pass
                switch decodedCommand {
                case .requestFullSessionVideo(let targetID):
                    print("📥 Secondary received request for Session ID: \(targetID)")
                    let exists = self.recordingVM?.sessions.contains(where: { $0.id == targetID }) ?? false
                    if exists {
                        self.requestedSessionID = targetID
                        self.showFullVideoRequestAlert = true
                    } else {
                        print("❌ Error: Host requested ID \(targetID), but it doesn't exist on this device!")
                    }
                    
                case .startRecordingWithID(let externalID):
                    self.recordingVM?.startRecordingRemotely(withID: externalID)
                    
                case .preparingToSendHighlights(let total):
                    self.expectedHighlightCount = total
                    self.receivedHighlightCount = 0
                    self.isReceivingHighlightBatch = true
                    self.importedVideoURLQueue.removeAll()
                    
                case .finishedSendingHighlights:
                    self.isReceivingHighlightBatch = false
                    
                default:
                    break
                }
            }
        }
    }
    
    // MARK: - Delegate Methods
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        let isFullVideo = resourceName.hasPrefix("FullSession_")
        
        Task { @MainActor in
            if isFullVideo {
                self.isTransferringFile = true
                self.isReceivingFullVideo = true // Turn on the receiving state variable
                self.fullVideoProgress = 0.0     // Reset progress
            }
            
            // Key the task to the unique resource name so they don't cancel each other out!
            activeProgressTasks[resourceName]?.cancel()
            
            activeProgressTasks[resourceName] = Task {
                while !progress.isFinished && !progress.isCancelled {
                    await MainActor.run {
                        if isFullVideo {
                            self.incomingFileProgress = progress.fractionCompleted
                            self.fullVideoProgress = progress.fractionCompleted // Update the variable your UI is bound to!
                        }
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                await MainActor.run {
                    if isFullVideo {
                        self.isTransferringFile = false
                        self.isReceivingFullVideo = false // Turn off when cancelled/finished early
                    }
                    self.activeProgressTasks.removeValue(forKey: resourceName)
                }
            }
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // 1. Clean up tracking progress tasks on Main Actor
        Task { @MainActor in
            self.activeProgressTasks[resourceName]?.cancel()
            self.activeProgressTasks.removeValue(forKey: resourceName)
        }
        
        guard let localURL = localURL, error == nil else {
            print("❌ Resource receipt failed or URL invalid: \(String(describing: error))")
            return
        }
        
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let isFullVideo = resourceName.hasPrefix("FullSession_")
        
        // 🌟 DATABASE LINKAGE FIX: Parse the exact Session UUID from the filename!
        // Expected format from Step 3: FullSession_UUID_filename.mp4
        var targetSessionID: UUID? = nil
        if isFullVideo {
            let components = resourceName.components(separatedBy: "_")
            if components.count >= 3, let parsedID = UUID(uuidString: components[1]) {
                targetSessionID = parsedID
                print("🎯 Successfully parsed target session ID from file transfer: \(parsedID)")
            }
        }
        
        let safeFileName = isFullVideo ? "FullMaster_\(targetSessionID?.uuidString ?? UUID().uuidString).mp4" : "Imported_\(UUID().uuidString).mp4"
        let permanentURL = docsDir.appendingPathComponent(safeFileName)
        
        do {
            // Clean out old files if they happen to share the name
            if FileManager.default.fileExists(atPath: permanentURL.path) {
                try? FileManager.default.removeItem(at: permanentURL)
            }
            
            try FileManager.default.moveItem(at: localURL, to: permanentURL)
            
            // UI and State updates on MainActor
            Task { @MainActor in
                if isFullVideo {
                    self.newlyImportedFullVideoURL = permanentURL
                    self.newlyImportedTargetSessionID = targetSessionID // 🌟 Expose the target ID!
                    self.isReceivingFullVideo = false
                    self.fullVideoProgress = 1.0
                    
                } else {
                    self.importedVideoURLQueue.append(permanentURL)
                    self.onHighlightReceived?(permanentURL)
                    self.receivedHighlightCount += 1
                    
                    if self.receivedHighlightCount >= self.expectedHighlightCount {
                        print("📥 Network transfer complete. Accumulated \(self.importedVideoURLQueue.count) clips in queue.")
                    }
                }
                
                // 🌟 SYNTAX FIX: Post the notification safely INSIDE the Main Actor Task after all variables are mutated
                NotificationCenter.default.post(
                    name: NSNotification.Name("DidFinishImportingVideo"),
                    object: nil
                )
            }
        } catch {
            print("❌ Failed to save video asset: \(error)")
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        print("📥 Received a stream request - ignoring since ClipIt uses resource files.")
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate Implementation
extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, self.session)
        print("🤝 Auto-accepted connection request from \(peerID.displayName)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate Implementation
extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard let session = session else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15.0)
        print("🎯 Found Master Cam! Blasting sync connection link...")
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("⚠️ Lost radio contact with: \(peerID.displayName)")
    }
}
