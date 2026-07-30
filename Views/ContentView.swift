import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleVM: BLEViewModel
    @EnvironmentObject var recordingVM: RecordingViewModel
    @State private var selectedTab: Int = 0
    
    // Core App State Engines initialized cleanly at root
    @StateObject var multipeerManager = MultipeerManager()

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                RecordView(bleVM: bleVM, selectedTab: $selectedTab)
                    .tabItem {
                        Label("Record", systemImage: "video.circle.fill")
                    }
                    .tag(0)

                ClipsView()
                    .tabItem {
                        Label("Clips", systemImage: "film.stack")
                    }
                    .tag(1)

                BLEDeviceView()
                    .tabItem {
                        Label("Device", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(2)

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }
            .tint(.red)
            .onChange(of: recordingVM.shouldNavigateToClips) { oldValue, navigating in
                if navigating {
                    selectedTab = 1
                    recordingVM.shouldNavigateToClips = false
                }
            }
            .environmentObject(recordingVM)
            .environmentObject(multipeerManager)
            .onAppear {
                multipeerManager.recordingVM = recordingVM
            }
            // 🌟 CLEAN REVERTED ALERT
            .alert("Transfer Full Recording?", isPresented: $multipeerManager.showFullVideoRequestAlert) {
                Button("Allow") {
                    handleRevertedFullVideoTransfer()
                }
                Button("Deny", role: .cancel) {
                    print("🛑 User denied the full video transfer request.")
                }
            } message: {
                Text("The primary device is requesting to import the full-length high-quality master recording.")
            }
            .lowPowerModeWarning()
            
            // 🌟 GLOBAL IMPORT/EXPORT PROGRESS OVERLAY
            if multipeerManager.isTransferringFile {
                ZStack {
                    // Dim background slightly to pull visual focus to the container
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    Group {
                        if multipeerManager.isSendingHighlightsBatch {
                            // 🌟 Use your exact dedicated Highlight Extraction design layout component!
                            HighlightExtractionProgressView(
                                currentCount: multipeerManager.sentHighlightCount,
                                totalCount: multipeerManager.expectedSendingHighlightCount
                            )
                        } else {
                            // Fallback layout component for full-length master video uploads
                            ImportProgressView(progress: multipeerManager.incomingFileProgress)
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 400) // Keeps it centered nicely on large displays/iPads
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.25), value: multipeerManager.isTransferringFile)
            }
        }
    }
    
    // 🛠️ EXTRACTION HELPER: Takes business logic out of body view to keep compiler fast!
    private func handleRevertedFullVideoTransfer() {
        guard let targetID = multipeerManager.requestedSessionID else {
                print("❌ Error: No target session ID stored in multipeerManager!")
                return
            }

            // Print all available sessions to see why the match is failing
            print("🔍 Looking for Session ID: \(targetID)")
            for s in recordingVM.sessions {
                print("  - Available local session ID: \(s.id)")
            }
        // 🌟 FIX: Look up the exact session requested by the Host
        if let targetID = multipeerManager.requestedSessionID,
           let targetSession = recordingVM.sessions.first(where: { $0.id == targetID }),
           let targetVideoURL = targetSession.fullVideoURL {
            
            print("🚀 Sending exact master recording across raw stream for session \(targetID)...")
            
            // 🌟 FIX: Pass the sessionID to sendLargeFile
            multipeerManager.sendLargeFile(fileURL: targetVideoURL, sessionID: targetID, isFullSessionVideo: true) { success in
                DispatchQueue.main.async {
                    if success {
                        print("✅ Full master session video successfully transmitted to Host!")
                    } else {
                        print("❌ Failed or cancelled transferring full master session video.")
                    }
                }
            }
        } else {
            print("❌ Error: Requested master session recording not found locally to transfer.")
        }
    }
}
