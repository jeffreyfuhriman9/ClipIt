import SwiftUI
import UIKit
import AVFoundation
import Combine

private struct IPadBottomTabBar: View {
    @Binding var selection: Int

    private let tabs: [(title: String, icon: String, tag: Int)] = [
        ("Record", "video.fill", 0),
        ("Clips", "film", 1),
        ("Device", "button.programmable.square", 2),
        ("Settings", "gearshape.fill", 3)
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.tag) { tab in
                Button {
                    selection = tab.tag
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(selection == tab.tag ? Color.crimsonBlaze : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// iPadOS uses its system tab strip at the top of the display. Hide that
/// adaptive strip and supply a bottom bar that matches ClipIt's iPhone layout.
private struct BottomTabBarOnIPad: ViewModifier {
    @Binding var selection: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
                // The standard iPad TabView always supplies its own top tab
                // strip. A page-style container has no built-in strip, so the
                // custom bottom bar below is the only navigation shown.
                .tabViewStyle(.page(indexDisplayMode: .never))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    IPadBottomTabBar(selection: $selection)
                }
        } else {
            content
        }
    }
}

@MainActor
private final class StartupSplashCoordinator: ObservableObject {
    @Published private(set) var isVisible = true

    private var previewObservation: NSKeyValueObservation?
    private var revealTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func watchPreview(_ layer: AVCaptureVideoPreviewLayer) {
        guard isVisible else { return }
        previewObservation?.invalidate()
        previewObservation = layer.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in self?.revealAfterPreviewSettles() }
        }
    }

    func cameraDidStart() {
        guard isVisible, timeoutTask == nil else { return }
        // Do not trap the user behind the splash if the preview never arrives.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func revealAfterPreviewSettles() {
        guard isVisible, revealTask == nil else { return }
        revealTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        guard isVisible else { return }
        previewObservation?.invalidate()
        previewObservation = nil
        revealTask?.cancel()
        revealTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        withAnimation(.easeOut(duration: 0.25)) { isVisible = false }
    }
}

struct ContentView: View {
    @EnvironmentObject var bleVM: BLEViewModel
    @EnvironmentObject var recordingVM: RecordingViewModel
    @AppStorage("hasSeenGuidedTour") private var hasSeenGuidedTour = false
    @StateObject private var tutorial = TutorialController()
    @StateObject private var startupSplash = StartupSplashCoordinator()
    @State private var selectedTab: Int = 0
    @State private var cameraActuallyRecording = false


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
                RecordView(
                    bleVM: bleVM,
                    selectedTab: $selectedTab,
                    onPreviewLayerReady: { startupSplash.watchPreview($0) }
                )
                    .toolbarBackground(.hidden, for: .tabBar)
                    .toolbarColorScheme(.dark, for: .tabBar)
                    .tabItem {
                        Label("Record", systemImage: "video")
                    }
                    .tag(0)

                // 🎬 CLIPS TAB: Solid white bar + standard dark icons
                ClipsView(isSelected: selectedTab == 1)
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem {
                        Label("Library", systemImage: "film")
                    }
                    .tag(1)

                // 📡 DEVICE TAB: Solid white bar + standard dark icons
                BLEDeviceView()
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem {
                        Label("Device", systemImage: "button.programmable.square")
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
            .modifier(BottomTabBarOnIPad(selection: $selectedTab))
            .tint(.crimsonBlaze) // Selected tab remains Red across all screens
            .onChange(of: recordingVM.shouldNavigateToClips) { oldValue, navigating in
                if navigating {
                    selectedTab = 1
                    recordingVM.shouldNavigateToClips = false
                }
            }
            .environmentObject(recordingVM)
            .environmentObject(tutorial)
            .onAppear {
                if !hasSeenGuidedTour && tutorial.step == nil {
                    tutorial.start()
                }
            }
            .onChange(of: tutorial.step) { _, step in
                selectedTab = step?.tab ?? 0
            }
            if tutorial.step != nil {
                TutorialOverlay()
                    .environmentObject(tutorial)
                    .zIndex(10)
            }

            if startupSplash.isVisible {
                Color("StartupSplashBackground")
                    .overlay {
                        // Match the system launch screen's asset size instead
                        // of enlarging and cropping it when SwiftUI takes over.
                        Image("ClipItLaunch2026")
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .zIndex(20)
                    .transition(.opacity)
            }
        }
        .onReceive(recordingVM.cameraManager.$isRunning) { running in
            if running { startupSplash.cameraDidStart() }
        }
        .onReceive(recordingVM.cameraManager.$error) { error in
            if let error {
                startupSplash.dismiss()
                bleVM.reportCommandError(error.localizedDescription)
                if recordingVM.recordingState == .active {
                    recordingVM.discardSession()
                    cameraActuallyRecording = false
                    bleVM.sendRemoteCommand("COMMAND_FAILED")
                    sendActualCameraState()
                }
            }
        }
        // Keep button actions alive even when Record is not the selected tab.
        .onReceive(bleVM.clipTrigger) { _ in
            _ = handleButtonCommand(.clip)
        }
        .onReceive(bleVM.startRecordTrigger) { _ in
            _ = handleButtonCommand(.start)
        }
        .onReceive(bleVM.stopRecordTrigger) { _ in
            _ = handleButtonCommand(.stop)
        }
        .onReceive(bleVM.toggleRecordTrigger) { _ in
            _ = handleButtonCommand(recordingVM.recordingState == .active ? .stop : .start)
        }
        .onReceive(bleVM.reliableCommandTrigger) { command in
            if command.kind == .clip, let age = command.ageMilliseconds {
                let pressedAt = Date().addingTimeInterval(-Double(age) / 1000)
                let result = recordingVM.registerRecoveredButtonClip(at: pressedAt)
                print("[ClipIt Recovery] sequence=\(command.sequence) ageMs=\(age) result=\(result) recording=\(recordingVM.recordingState) camera=\(recordingVM.cameraConfirmedRecording)")
                switch result {
                case .saved:
                    bleVM.reportClipTransferStatus("Registered button tap \(command.sequence); the clip will appear after processing.")
                    bleVM.acknowledge(command, accepted: true)
                case .retryLater:
                    bleVM.reportClipTransferStatus("Received button tap \(command.sequence); waiting for its recording.")
                    bleVM.retryWhenRecordingIsReady(command)
                case .noRecording:
                    bleVM.reportClipTransferStatus("Received button tap \(command.sequence), but no matching video was found.")
                    bleVM.acknowledge(command, accepted: false)
                    bleVM.reportCommandError("A button tap could not be saved because no recording has been started.")
                }
            } else {
                bleVM.acknowledge(command, accepted: handleButtonCommand(command.kind))
            }
        }
        .onReceive(bleVM.remoteCommandReadyTrigger) { _ in
            sendActualCameraState()
        }
        .onReceive(recordingVM.cameraManager.recordingStarted) { _ in
            cameraActuallyRecording = recordingVM.recordingState == .active
            sendActualCameraState()
        }
        .onChange(of: recordingVM.recordingState) { _, state in
            if state != .active {
                cameraActuallyRecording = false
                sendActualCameraState()
            }
        }
        .onReceive(recordingVM.cameraManager.recordingFailed) { reason in
            cameraActuallyRecording = false
            recordingVM.discardSession()
            bleVM.reportCommandError(reason)
            bleVM.sendRemoteCommand("COMMAND_FAILED")
            sendActualCameraState()
        }
    }

    private func sendActualCameraState() {
        bleVM.sendRemoteCommand("RECORDING_STATE \(cameraActuallyRecording ? 1 : 0)")
    }

    private func handleButtonCommand(_ kind: ReliableButtonCommand.Kind) -> Bool {
        switch kind {
        case .clip:
            guard recordingVM.recordingState == .active, cameraActuallyRecording else { return false }
            recordingVM.triggerClip()
            return true
        case .start:
            guard recordingVM.recordingState == .idle,
                  recordingVM.currentSession == nil,
                  recordingVM.cameraManager.permissionGranted,
                  recordingVM.cameraManager.isRunning else { return false }
            recordingVM.requestStartSession()
            return true
        case .stop:
            guard recordingVM.recordingState == .active else { return false }
            recordingVM.endSession(navigateToClips: false)
            return true
        }
    }
}
