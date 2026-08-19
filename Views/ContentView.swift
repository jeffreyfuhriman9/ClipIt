import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleVM: BLEViewModel
    @EnvironmentObject var recordingVM: RecordingViewModel
    @State private var selectedTab: Int = 0
    
    @StateObject var multipeerManager = MultipeerManager()

    init() {
        // Force nav bar title color to cosmosBlue everywhere, and give the bar a
        // solid white background only once scrolled/collapsed. The large-title
        // (scroll-edge, i.e. resting at top) state deliberately stays transparent —
        // giving IT an explicit background color is what triggers iOS 26's
        // large-title-hidden bug. The collapsed/standard state isn't affected by
        // that bug, so it's safe to make solid white there.
        let cosmosBlueUIColor = UIColor(Color.cosmosBlue)

        let scrollEdgeAppearance = UINavigationBarAppearance()
        scrollEdgeAppearance.configureWithDefaultBackground()
        scrollEdgeAppearance.titleTextAttributes = [.foregroundColor: cosmosBlueUIColor]
        scrollEdgeAppearance.largeTitleTextAttributes = [.foregroundColor: cosmosBlueUIColor]

        let standardAppearance = UINavigationBarAppearance()
        standardAppearance.configureWithOpaqueBackground()
        standardAppearance.backgroundColor = .white
        standardAppearance.titleTextAttributes = [.foregroundColor: cosmosBlueUIColor]
        standardAppearance.largeTitleTextAttributes = [.foregroundColor: cosmosBlueUIColor]

        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
        UINavigationBar.appearance().standardAppearance = standardAppearance
        UINavigationBar.appearance().compactAppearance = standardAppearance
        UINavigationBar.appearance().tintColor = cosmosBlueUIColor
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // 🎥 RECORD TAB: Transparent background over dark camera gradient + bright white icons
                RecordView(bleVM: bleVM, selectedTab: $selectedTab)
                    .toolbarBackground(.hidden, for: .tabBar)
                    .toolbarColorScheme(.dark, for: .tabBar)
                    .tabItem {
                        Label("Record", systemImage: "video.circle.fill")
                    }
                    .tag(0)

                // 🎬 CLIPS TAB: Solid white bar + standard dark icons
                ClipsView()
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem {
                        Label("Clips", systemImage: "film.stack")
                    }
                    .tag(1)

                // 📡 DEVICE TAB: Solid white bar + standard dark icons
                BLEDeviceView()
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem {
                        Label("Device", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(2)

                // ⚙️ SETTINGS TAB: Solid white bar + standard dark icons
                SettingsView()
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(3)
            }
            .tint(.crimsonBlaze) // Selected tab remains Red across all screens
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
            
            if multipeerManager.isTransferringFile {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    Group {
                        if multipeerManager.isSendingHighlightsBatch {
                            HighlightExtractionProgressView(
                                currentCount: multipeerManager.sentHighlightCount,
                                totalCount: multipeerManager.expectedSendingHighlightCount
                            )
                        } else {
                            ImportProgressView(progress: multipeerManager.incomingFileProgress)
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 400)
                    .transition(.scale.combined(with: .opacity))
                }
                .animation(.easeInOut(duration: 0.25), value: multipeerManager.isTransferringFile)
            }
        }
    }
    
    private func handleRevertedFullVideoTransfer() {
        guard let targetID = multipeerManager.requestedSessionID else {
            print("❌ Error: No target session ID stored in multipeerManager!")
            return
        }

        print("🔍 Looking for Session ID: \(targetID)")
        for s in recordingVM.sessions {
            print("  - Available local session ID: \(s.id)")
        }

        if let targetID = multipeerManager.requestedSessionID,
           let targetSession = recordingVM.sessions.first(where: { $0.id == targetID }),
           let targetVideoURL = targetSession.fullVideoURL {
            
            print("🚀 Sending exact master recording across raw stream for session \(targetID)...")
            
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
