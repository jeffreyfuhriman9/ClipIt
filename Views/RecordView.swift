import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    @ObservedObject var bleVM: BLEViewModel
    @Binding var selectedTab: Int
    @State private var showSettings = false
    @State private var orientation = UIDevice.current.orientation
    
    // Call Monitor Interruption Interface
    @StateObject private var callMonitor = CallMonitor()
    @State private var showCallInterruptionOverlay = false
    
    // Clip saved banner
    @State private var showClipSavedBanner = false
    @State private var clipSavedText = ""
    @State private var clipSavedHideTask: DispatchWorkItem?
    
    // Pinch-to-zoom
    @State private var lastZoomFactor: CGFloat = 1.0
    @State private var uiZoomFactor: CGFloat = 2.0
    
    // Tap-to-focus + inline brightness slider
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusIndicator = false
    @State private var showBrightnessSlider = false
    @State private var focusHideTask: DispatchWorkItem?
    
    // Camera controls panel
    @State private var showCameraControls = false
    
    // Preview layer ref for focus point conversion
    @State private var previewLayerRef: AVCaptureVideoPreviewLayer? = nil
    
    // Hashable variable for tap focus
    @State private var focusID = UUID()
    @State private var localQuality: CameraManager.VideoQuality? = nil
    
    // Variables for multiview phone setup
    @State private var showMultiCamSheet = false
    
    @State private var transferClipsOnCompletion = false
    @State private var showImportPrompt = false
    
    // Dimming screen for recording
    @AppStorage("dimScreenDuringRecording") private var dimScreenDuringRecording = false
    @State private var originalBrightness: CGFloat = 0.5
    @Environment(\.scenePhase) var scenePhase // To detect if the app goes to the background
    
    
    private var exposureBiasBinding: Binding<Double> {
        Binding(
            get: { Double(recordingVM.cameraManager.exposureBias) },
            set: { recordingVM.cameraManager.setExposureBias(Float($0)) }
        )
    }
    
    // 🌟 1. The body now ONLY handles behavior and lifecycle modifiers!
        var body: some View {
            mainContent
                // ✅ ALL Root Layout Pipeline Modifiers attach safely here to the ZStack!
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.25), value: orientation)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showCameraControls)
                .sheet(isPresented: $showMultiCamSheet) {
                    MultiCamConnectionSheet(multipeerManager: multipeerManager)
                }
                .onReceive(bleVM.clipTrigger) { _ in
                    if recordingVM.recordingState == .active {
                        recordingVM.triggerClip()
                        showClipSavedConfirmation()
                        // 📡 Broadcast unique payload to Follower Cam:
                        multipeerManager.sendCommand(.triggerClip(clipNumber: 1, uuid: UUID()))
                    }
                }
                .onReceive(bleVM.toggleRecordTrigger) { _ in
                    handleRecordTap()
                }
                .sheet(isPresented: $showSettings) {
                    RecordSettingsSheet()
                        .environmentObject(recordingVM)
                }
                .onAppear {
                    callMonitor.setupViewModel(recordingVM)
                    recordingVM.cameraManager.startIfNeeded()
                    DispatchQueue.main.async {
                        recordingVM.cameraManager.requestPermissionAndSetup()
                    }
                    if !bleVM.bleState.isConnected { bleVM.startScanning() }
                    
                    multipeerManager.onHighlightReceived = { [weak recordingVM] url in
                        Task { @MainActor in
                            recordingVM?.attachImportedHighlight(fileURL: url)
                        }
                    }
                }
                .onDisappear {
                    bleVM.stopScanning()
                    
                    // Force-restore system sleep capabilities instantly on the main actor thread
                    DispatchQueue.main.async {
                        UIApplication.shared.isIdleTimerDisabled = false
                        print("📱 Safety Trigger: Camera view disappeared. System auto-lock restored.")
                    }
                }
                .onChange(of: callMonitor.isOnCall) { oldValue, isNowOnCall in
                    if isNowOnCall {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            showCallInterruptionOverlay = true
                        }
                    }
                }
                .onChange(of: multipeerManager.latestCommandReceived) { oldCommand, newCommand in
                    guard let command = newCommand else { return }
                    
                    switch command {
                    case .startRecording:
                        if recordingVM.recordingState != .active {
                            transferClipsOnCompletion = false
                            recordingVM.requestStartSession(multipeerManager: multipeerManager)
                        }
                    case .stopRecording:
                        if recordingVM.recordingState == .active {
                            recordingVM.endSession()
                        }
                    case .triggerClip(_, _):
                        if recordingVM.recordingState == .active {
                            recordingVM.triggerClip()
                            showClipSavedConfirmation()
                        }
                    case .updateSettings(let before, let after):
                        withAnimation {
                            recordingVM.bufferLengthSeconds = before
                            recordingVM.postRollSeconds = after
                        }
                    case .requestFullSessionVideo(let sessionID):
                        print("Secondary camera received request for full session video: \(sessionID)")
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            multipeerManager.showFullVideoRequestAlert = true
                        }
                        
                    // ✅ ADD THIS CASE TO RE-ESTABLISH EXHAUSTIVENESS
                    case .startRecordingWithID(let sessionID):
                        print("Secondary camera received command to start recording with specific ID: \(sessionID)")
                        if recordingVM.recordingState != .active {
                            transferClipsOnCompletion = false
                            recordingVM.requestStartSession(multipeerManager: multipeerManager)
                        }

                    case .requestHighlights:
                        if !recordingVM.justFinishedSessionClips.isEmpty {
                            startOffloadingSecondaryHighlights(urls: recordingVM.justFinishedSessionClips)
                            recordingVM.justFinishedSessionClips = []
                        } else {
                            transferClipsOnCompletion = true
                        }
                    case .preparingToSendHighlights(let total):
                        print("Host expecting \(total) highlights coming from secondary camera.")
                        
                    case .finishedSendingHighlights:
                        recordingVM.isImportingSecondary = false
                    }
                    
                    multipeerManager.latestCommandReceived = nil
                }
                .onChange(of: recordingVM.bufferLengthSeconds) { oldValue, newValue in
                    multipeerManager.sendCommand(.updateSettings(secondsBefore: newValue, secondsAfter: recordingVM.postRollSeconds))
                }
                .onChange(of: recordingVM.postRollSeconds) { oldValue, newValue in
                    multipeerManager.sendCommand(.updateSettings(secondsBefore: recordingVM.bufferLengthSeconds, secondsAfter: newValue))
                }
                .onChange(of: recordingVM.justFinishedSessionClips) { oldValue, newURLs in
                    guard !newURLs.isEmpty else { return }
                    
                    if transferClipsOnCompletion {
                        print("🎬 Extraction complete! Secondary camera auto-offloading \(newURLs.count) highlights...")
                        startOffloadingSecondaryHighlights(urls: newURLs)
                        
                        transferClipsOnCompletion = false
                        recordingVM.justFinishedSessionClips = []
                    }
                }
                // 1. Recording State Check (iOS 17+ Syntax)
                .onChange(of: recordingVM.recordingState) { oldState, newState in
                    if newState == .active {
                        if dimScreenDuringRecording {
                            // Save the user's current brightness, then dim it to 1%
                            originalBrightness = UIScreen.main.brightness
                            UIScreen.main.brightness = 0.01
                        }
                    } else {
                        if dimScreenDuringRecording {
                            // Restore it when recording stops
                            UIScreen.main.brightness = originalBrightness
                        }
                    }
                }

                // 2. Scene Phase Check (iOS 17+ Syntax)
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    // SAFETY: If the user swipes home while the screen is dim, put the brightness back to normal!
                    if newPhase != .active && dimScreenDuringRecording {
                        UIScreen.main.brightness = originalBrightness
                    }
                }
        }
        
        // 🌟 2. The visual layout now lives here safely with correct property mapping!
        private var mainContent: some View {
            ZStack {
                cameraPreview
                
                // Shadow Gradient
                LinearGradient(
                    colors: [Color.black.opacity(0.24), Color.clear, Color.black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                
                // Tap-to-focus indicator overlay
                if showFocusIndicator, let pt = focusPoint {
                    FocusIndicatorView(
                        showBrightness: showBrightnessSlider,
                        exposureBias: exposureBiasBinding,
                        onSliderChanged: { rescheduleBrightnessHide() }
                    )
                    .position(pt)
                    .allowsHitTesting(showBrightnessSlider)
                    .zIndex(2)
                    .id(focusID)
                }
                
                GeometryReader { geo in
                    let isLandscape = geo.size.width > geo.size.height
                    let isLandscapeLeft = orientation == .landscapeLeft
                        
                    ZStack {
                        // Gesture Capture Layer
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        let dynamicDelta = value.magnitude
                                        let baseZoom = recordingVM.cameraManager.zoomFactor
                                        let targetZoom = lastZoomFactor == 1.0 ? baseZoom * dynamicDelta : baseZoom + (value - lastZoomFactor)
                                        lastZoomFactor = value
                                        recordingVM.cameraManager.setZoom(targetZoom)
                                    }
                                    .onEnded { _ in
                                        lastZoomFactor = 1.0
                                    }
                            )
                            .onTapGesture { location in
                                if showCameraControls {
                                    withAnimation { showCameraControls = false }
                                }
                                handleTapToFocus(at: location)
                            }
                        
                        // 🎛️ CORE INTERFACE CONTROLS CONTAINER LAYER
                        VStack(spacing: 0) {
                            
                            // 1. Top Bar Items (Always at the top)
                            topOverlayView(isLandscape: isLandscape)
                                .padding(.trailing, isLandscape && isLandscapeLeft ? 120 : 0)
                                .padding(.leading, isLandscape && !isLandscapeLeft ? 120 : 0)
                            
                            Spacer()
                            
                            // 2. Dynamic Adaptive Lower Controls Matrix
                            if isLandscape {
                                HStack(alignment: .center) {
                                    if isLandscapeLeft {
                                        // 📱 Phone left: Badge on LEFT edge, TOP
                                        VStack {
                                            timingBadge.padding(.top, -54)
                                            Spacer()
                                        }
                                        
                                        Spacer()
                                        
                                        if showCameraControls {
                                            VStack {
                                                Spacer()
                                                cameraControlsPanel.padding(.bottom, 75)
                                            }
                                        }
                                        
                                        sideOverlayView(isLandscapeLeft: isLandscapeLeft)
                                        
                                    } else {
                                        // 📱 Phone right: Controls on left edge
                                        sideOverlayView(isLandscapeLeft: isLandscapeLeft)
                                        
                                        if showCameraControls {
                                            VStack {
                                                Spacer()
                                                cameraControlsPanel.padding(.bottom, 75)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        // Badge on RIGHT edge, BOTTOM
                                        VStack {
                                            Spacer()
                                            timingBadge.padding(.bottom, 36)
                                        }
                                    }
                                }
                                .safeAreaPadding(.horizontal)
                                
                            } else {
                                // Default Portrait configuration layout block
                                VStack {
                                    Spacer()
                                    if showCameraControls {
                                        cameraControlsPanel
                                    }
                                    bottomOverlay
                                }
                            }
                        }
                        .zIndex(1)
                        
                        // Clip saved notification banner overlay
                        VStack {
                            Spacer()
                            if showClipSavedBanner {
                                Text(clipSavedText)
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
                                    .transition(.opacity)
                                    .padding(.bottom, isLandscape ? 80 : showCameraControls ? 240 : 175)
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: showClipSavedBanner)
                        .zIndex(2)
                    }
                    .animation(.easeInOut(duration: 0.25), value: isLandscape)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    let newOrientation = UIDevice.current.orientation
                    if newOrientation.isValidInterfaceOrientation { orientation = newOrientation }
                }
                
                // 📞 PHONE CALL INTERRUPTION BOX OVERLAY
                callInterruptionOverlayView
                
                // 🌟 THE FLOATING PROGRESS BARS (Completely Independent)
                // ✅ FIXED: Properties updated to match your exact view model types!
                if recordingVM.isExtractingHighlights {
                    VStack {
                        Spacer() // Pushes it down
                        HighlightExtractionProgressView(
                            currentCount: recordingVM.currentExtractionProgress,
                            totalCount: recordingVM.totalExtractionCount
                        )
                        Spacer()
                    }
                    .zIndex(100)
                    .allowsHitTesting(false)
                }
                
                if recordingVM.isImportingSecondary {
                    VStack {
                        Spacer()
                        // ✅ FIXED: Changed recordingVM.importProgress to multipeerManager.fullVideoProgress
                        ImportProgressView(progress: multipeerManager.fullVideoProgress)
                            .padding(.bottom, orientation.isLandscape ? 40 : 120)
                    }
                    .zIndex(100)
                    .allowsHitTesting(false)
                }
            }
        }
    
    private var adaptiveInterfaceLayer: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isLandscapeLeft = orientation == .landscapeLeft
            
            ZStack {
                // Gesture Capture Layer
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let dynamicDelta = value.magnitude
                                let baseZoom = recordingVM.cameraManager.zoomFactor
                                let targetZoom = lastZoomFactor == 1.0 ? baseZoom * dynamicDelta : baseZoom + (value - lastZoomFactor)
                                lastZoomFactor = value
                                recordingVM.cameraManager.setZoom(targetZoom)
                            }
                            .onEnded { _ in
                                lastZoomFactor = 1.0
                            }
                    )
                    .onTapGesture { location in
                        if showCameraControls {
                            withAnimation { showCameraControls = false }
                        }
                        handleTapToFocus(at: location)
                    }
                
                // 🎛️ CORE INTERFACE CONTROLS CONTAINER LAYER
                VStack(spacing: 0) {
                    
                    // 1. Top Bar Items (Always at the top)
                    topOverlayView(isLandscape: isLandscape)
                        .padding(.trailing, isLandscape && isLandscapeLeft ? 120 : 0)
                        .padding(.leading, isLandscape && !isLandscapeLeft ? 120 : 0)
                    
                    Spacer()
                    
                    // 2. Dynamic Adaptive Lower Controls Matrix
                    if isLandscape {
                        HStack(alignment: .center) {
                            if isLandscapeLeft {
                                // 📱 Phone left: Badge on LEFT edge, TOP
                                VStack {
                                    timingBadge.padding(.top, -54)
                                    Spacer()
                                }
                                
                                Spacer()
                                
                                if showCameraControls {
                                    VStack {
                                        Spacer()
                                        cameraControlsPanel.padding(.bottom, 75)
                                    }
                                }
                                
                                sideOverlayView(isLandscapeLeft: isLandscapeLeft)
                                
                            } else {
                                // 📱 Phone right: Controls on left edge
                                sideOverlayView(isLandscapeLeft: isLandscapeLeft)
                                
                                if showCameraControls {
                                    VStack {
                                        Spacer()
                                        cameraControlsPanel.padding(.bottom, 75)
                                    }
                                }
                                
                                Spacer()
                                
                                // ✅ THE FIX: Badge on RIGHT edge, BOTTOM!
                                VStack {
                                    Spacer() // Pushes the badge all the way down
                                    timingBadge.padding(.bottom, 36)
                                }
                            }
                        }
                        .safeAreaPadding(.horizontal)
                        
                    } else {
                        // Default Portrait configuration layout block
                        VStack {
                            Spacer()
                            if showCameraControls {
                                cameraControlsPanel
                            }
                            bottomOverlay
                        }
                    }
                }
                .zIndex(1)
                
                // Clip saved notification banner overlay
                VStack {
                    Spacer()
                    if showClipSavedBanner {
                        Text(clipSavedText)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 20)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
                            .transition(.opacity)
                            .padding(.bottom, isLandscape ? 80 : showCameraControls ? 240 : 175)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: showClipSavedBanner)
                .zIndex(2)
            }
            .animation(.easeInOut(duration: 0.25), value: isLandscape)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let newOrientation = UIDevice.current.orientation
            if newOrientation.isValidInterfaceOrientation { orientation = newOrientation }
        }
    }
    
    // MARK: - Extracted Subviews
            
        @ViewBuilder
    private var callInterruptionOverlayView: some View {
        if showCallInterruptionOverlay {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(10)
                .overlay(
                    VStack(spacing: 22) {
                        Image(systemName: "phone.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                        
                        Text("Recording Interrupted")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("An incoming phone call was accepted. Your active video recording session has been safely ended and saved to the clips gallery.")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                        
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showCallInterruptionOverlay = false
                            }
                        }) {
                            Text("Ok")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 140, height: 44)
                                .background(Color.white)
                                .clipShape(Capsule())
                                .shadow(color: Color.black.opacity(0.15), radius: 6, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                    }
                    .padding(28)
                    .background(Color(white: 0.15))
                    .cornerRadius(24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .frame(maxWidth: 325)
                    .shadow(color: Color.black.opacity(0.4), radius: 20, y: 10)
                )
                .background(Color.black.ignoresSafeArea())
        }
    }
    
    // MARK: - Tap to focus

    private func handleTapToFocus(at location: CGPoint) {
        focusID = UUID()
        recordingVM.cameraManager.setExposureBias(0.0)
        focusPoint = location
        if let layer = previewLayerRef {
            recordingVM.cameraManager.focusAndExpose(at: location, in: layer)
        }

        withAnimation(.easeIn(duration: 0.15)) { showFocusIndicator = true }
        focusHideTask?.cancel()
        
        // FIX: Resolved strong retention cycle memory leak inside DispatchWorkItem
        let hideTask = DispatchWorkItem { [weak recordingVM] in
            _ = recordingVM // Keeps deployment scope valid without retaining self
            withAnimation(.easeOut(duration: 0.4)) {
                self.showFocusIndicator = false
                self.showBrightnessSlider = false
            }
        }
        focusHideTask = hideTask
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeIn(duration: 0.2)) { showBrightnessSlider = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: hideTask)
    }

    private func rescheduleBrightnessHide() {
        focusHideTask?.cancel()
        let hideTask = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.4)) {
                self.showFocusIndicator = false
                self.showBrightnessSlider = false
            }
        }
        focusHideTask = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hideTask)
    }

    // MARK: - Camera preview

    private var cameraPreview: some View {
        CameraPermissionGate(
            cameraManager: recordingVM.cameraManager,
            onLayerReady: { layer in
                DispatchQueue.main.async {
                    previewLayerRef = layer
                }
            }
        )
        .ignoresSafeArea()
    }

        // MARK: - Top overlay
            @ViewBuilder
            private func topOverlayView(isLandscape: Bool) -> some View {
                VStack(spacing: 10) {
                    HStack(alignment: .top) {
                        // ✅ Instantly shows in Portrait mode because we removed the height restriction!
                        if !isLandscape {
                            timingBadge
                        }
                        
                        Spacer()

                        VStack(alignment: .trailing, spacing: 8) {
                            // Multi-Cam Control Button neatly nested right here!
                            Button(action: { showMultiCamSheet = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: multipeerManager.isSuccessfullyConnected ? "link.circle.fill" : "link.circle")
                                        .font(.system(size: 14))
                                    Text(multipeerManager.isSuccessfullyConnected ? "Multi-Cam Connected" : "Link Multi-Cam")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(multipeerManager.isSuccessfullyConnected ? Color.blue : Color.black.opacity(0.5))
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 45)
                
                    // Sleek Incoming Highlights Tracker
                    if multipeerManager.isReceivingHighlightBatch {
                        VStack(spacing: 4) {
                            Text("Receiving Highlights...")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                            
                            HighlightExtractionProgressView(
                                currentCount: multipeerManager.receivedHighlightCount,
                                totalCount: multipeerManager.expectedHighlightCount
                            )
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 10)
                    }
                    // HUD Block
                    else if multipeerManager.isSendingFullVideo || multipeerManager.isReceivingFullVideo {
                        VStack(spacing: 6) {
                            Text(multipeerManager.isSendingFullVideo ? "Sending Full Recording to Host..." : "Receiving Full Studio Recording...")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                            
                            ProgressView(value: multipeerManager.fullVideoProgress, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(.blue)
                                .frame(maxWidth: 220)
                            
                            Text("\(Int(multipeerManager.fullVideoProgress * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 10)
                    }
                }
                .transition(.opacity)
            }
    
    private var timingBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Before:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("\(recordingVM.bufferLengthSeconds)s")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            HStack(spacing: 6) {
                Text("After:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("\(recordingVM.postRollSeconds)s")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            if recordingVM.recordingState == .active {
                Text("REC \(recordingVM.elapsedLabel)")
                    .foregroundColor(.red)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Camera controls panel

    private var cameraControlsPanel: some View {
        VStack(spacing: 16) {
            ClipItTimingBar(
                beforeSeconds: $recordingVM.bufferLengthSeconds,
                afterSeconds: $recordingVM.postRollSeconds
            )

            HStack {
                Text("Video Quality")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                
                Picker(selection: Binding(
                    get: { localQuality ?? recordingVM.cameraManager.videoQuality },
                    set: { newQuality in
                        localQuality = newQuality
                        recordingVM.cameraManager.setVideoQuality(newQuality)
                    }
                )) {
                    ForEach(CameraManager.VideoQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text((localQuality ?? recordingVM.cameraManager.videoQuality).rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .id("QualityLabel_\((localQuality ?? recordingVM.cameraManager.videoQuality).rawValue)")
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                }
                .pickerStyle(.menu)
                .disabled(recordingVM.recordingState == .active)
            }
            .onAppear {
                localQuality = recordingVM.cameraManager.videoQuality
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: 450)
        .frame(maxHeight: 140, alignment: .center)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
        
    // MARK: - Zoom Switcher & Sub-Elements

    @ViewBuilder
        private var zoomButtons: some View {
            // 💡 FIX: Hardware 2.0 = UI 1.0x. This ensures it stays on the 0.5 button up through 0.9x!
            let isUltraWideActive = uiZoomFactor < 2.0
            
            let displayZoomValue = uiZoomFactor * 0.5
            let displayString = String(format: "%.1f", displayZoomValue)
            
            // --- 0.5x Snap Button ---
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                uiZoomFactor = 1.0
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    recordingVM.cameraManager.setZoom(1.0)
                }
            }) {
                Text(isUltraWideActive ? "\(displayString)x" : "0.5")
                    .font(.system(size: 11, weight: .bold))
                    // 💡 FIX: Reverted to Yellow text instead of black text
                    .foregroundColor(isUltraWideActive ? .yellow : .white)
                    .frame(width: 38, height: 38)
                    // 💡 FIX: Reverted to dark gray transparent background
                    .background(isUltraWideActive ? Color.black.opacity(0.6) : Color.black.opacity(0.35))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(isUltraWideActive ? Color.yellow : Color.white.opacity(0.2), lineWidth: isUltraWideActive ? 1.5 : 0.5)
                    )
            }
            .buttonStyle(.plain)
            
            // --- 1.0x Snap Button ---
            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                uiZoomFactor = 2.0
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    recordingVM.cameraManager.setZoom(2.0)
                }
            }) {
                Text(!isUltraWideActive ? "\(displayString)x" : "1x")
                    .font(.system(size: 11, weight: .bold))
                    // 💡 FIX: Reverted to Yellow text instead of black text
                    .foregroundColor(!isUltraWideActive ? .yellow : .white)
                    .frame(width: 38, height: 38)
                    // 💡 FIX: Reverted to dark gray transparent background
                    .background(!isUltraWideActive ? Color.black.opacity(0.6) : Color.black.opacity(0.35))
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(!isUltraWideActive ? Color.yellow : Color.white.opacity(0.2), lineWidth: !isUltraWideActive ? 1.5 : 0.5)
                    )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private var appleZoomSwitcher: some View {
            Group {
                if orientation.isLandscape {
                    VStack(spacing: 12) {
                        zoomButtons
                    }
                } else {
                    HStack(spacing: 12) {
                        zoomButtons
                    }
                }
            }
            .padding(6)
            .background(Color.black.opacity(0.25))
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 8, y: 3)
            // 💡 THE FIX: Actively listens to the nested camera manager.
            // If you pinch the screen, the yellow rings will cross over automatically!
            .onReceive(recordingVM.cameraManager.$zoomFactor) { newZoom in
                self.uiZoomFactor = newZoom
            }
        }

        @ViewBuilder
        private var controlsSettingsButton: some View {
            CircleButton(
                systemImage: "slider.horizontal.3",
                fill: showCameraControls ? Color.white.opacity(0.3) : Color.black.opacity(0.4)
            ) {
                withAnimation { showCameraControls.toggle() }
            }
            .background(.ultraThinMaterial)
            .clipShape(Circle())
        }

        @ViewBuilder
        private var portraitControlsRow: some View {
            ZStack {
                RecordButton(isRecording: recordingVM.recordingState == .active) {
                    handleRecordTap()
                }
                .id("portrait_record_button")

                HStack {
                    controlsSettingsButton
                    Spacer()
                    clipItButton.frame(width: 90, height: 70)
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 16)
        }

        // MARK: - Bottom overlay (Portrait View Layer)

        @ViewBuilder
        private var bottomOverlay: some View {
            VStack(spacing: 0) {
                appleZoomSwitcher
                    .padding(.bottom, 24)
                
                portraitControlsRow
            }
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.3), Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.bottom, 12)
            .safeAreaPadding(.bottom, 60)
        }

        // MARK: - Side overlay (Landscape View Layer)

        @ViewBuilder
        private func sideOverlayView(isLandscapeLeft: Bool) -> some View {
            HStack(spacing: 24) {
                // Reverses the order of the zoom switch based on rotation!
                if !isLandscapeLeft {
                    controlButtonsColumn
                }
                
                appleZoomSwitcher
                
                if isLandscapeLeft {
                    controlButtonsColumn
                }
            }
            .padding(.horizontal, 16)
        }

        // Extracted column forced to push apart via ZStack max height constraints
        @ViewBuilder
        private var controlButtonsColumn: some View {
            ZStack {
                // ✅ Use negative top padding to force it higher!
                clipItButton
                    .frame(height: 70)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, -25)
                
                // Center locked: Record Button
                RecordButton(isRecording: recordingVM.recordingState == .active) {
                    handleRecordTap()
                }
                .id("landscape_record_button")
                .frame(maxHeight: .infinity, alignment: .center)
                
                // Bottom locked: Settings Wheel
                controlsSettingsButton
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 25)
            }
            .frame(width: 100)
            .frame(maxHeight: .infinity) // Absolute stretch prevents "smushing"
            .padding(.vertical, 10)
        }
    
    private var clipItButton: some View {
        Button {
            if recordingVM.recordingState == .active {
                recordingVM.triggerClip()
                showClipSavedConfirmation()
                // 📡 Broadcast to Follower Cam:
                multipeerManager.sendCommand(.triggerClip(clipNumber: 1, uuid: UUID())) // 👈 Pass a unique UUID
            }        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(recordingVM.recordingState == .active ? Color.red.opacity(0.92) : Color.white.opacity(0.14))
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                VStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.system(size: 26, weight: .bold))
                    Text("ClipIt!").font(.system(size: 22, weight: .heavy))
                }
                .foregroundColor(.white)
            }
            .frame(height: 88)
            .shadow(color: Color.black.opacity(0.25), radius: 12, y: 5)
        }
        .disabled(recordingVM.recordingState != .active)
        .buttonStyle(.plain)
    }

    private func handleRecordTap() {
        if recordingVM.recordingState == .active {
            // Normal recording buttons use navigation
            recordingVM.endSession()
            // 📡 Broadcast to Follower Cam to stop as well:
            multipeerManager.sendCommand(.stopRecording)
            
            // 🎬 MULTI-CAM HOST LOGIC:
            // If we are the Leader and have connected devices, ask to import!
            if multipeerManager.isHost && !multipeerManager.connectedPeers.isEmpty {
                showImportPrompt = true
            }
            
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = false
                print("📱 Recording stopped: Screen idle timer re-enabled.")
            }
            
        } else {
            // 🧼 FIX: Reset transfer pipeline flags for the new session
            transferClipsOnCompletion = false
            
            recordingVM.requestStartSession(multipeerManager: multipeerManager)
            // 📡 Broadcast to Follower Cam to start:
            multipeerManager.sendCommand(.startRecording)
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = true
                print("📱 Recording started: Screen idle timer disabled (Staying Awake).")
            }
        }
    }
    
    private func showClipSavedConfirmation() {
        clipSavedHideTask?.cancel()
        clipSavedText = "Clip saved at \(recordingVM.elapsedLabel)!"
        withAnimation(.easeInOut(duration: 0.2)) { showClipSavedBanner = true }
        
        // FIX: Replaced explicit struct retention capture leak
        let task = DispatchWorkItem { [weak recordingVM] in
            _ = recordingVM
            withAnimation(.easeOut(duration: 0.5)) { self.showClipSavedBanner = false }
        }
        clipSavedHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
    
    // MARK: - Post-Game Network Pipeline

    // 🌟 NEW: Helper function to announce batch size before sending
    private func startOffloadingSecondaryHighlights(urls: [URL]) {
        // 🌟 ITEM 2 UI FIX: Initialize the outbound batch counters on the Main Actor
        // This instantly causes the secondary phone's progress bar overlay to appear!
        Task { @MainActor in
            multipeerManager.expectedSendingHighlightCount = urls.count
            multipeerManager.sentHighlightCount = 0
            multipeerManager.isSendingHighlightsBatch = true
            multipeerManager.isTransferringFile = true
        }
        
        // 1. Tell primary phone we are sending exactly X files
        multipeerManager.sendCommand(.preparingToSendHighlights(total: urls.count))
        
        // 2. Start your existing recursive loop
        sendClipsSequentially(urls: urls)
    }

    /// Recursively transmits files one-by-one to avoid clogging multipeer session pipes
    private func sendClipsSequentially(urls: [URL]) {
        var queue = urls
        guard !queue.isEmpty else {
            print("🏁 All secondary angles successfully offloaded to primary device!")
            multipeerManager.sendCommand(.finishedSendingHighlights)
            return
        }
        
        let nextClipURL = queue.removeFirst()
        print("📤 Offloading secondary angle view: \(nextClipURL.lastPathComponent)")
        
        multipeerManager.sendLargeFile(fileURL: nextClipURL, isFullSessionVideo: false) { success in
            // When this specific file finishes transferring, process the next item in the queue
            DispatchQueue.main.async {
                if success {
                    print("✅ Successfully moved file. Moving onto next clip in queue...")
                } else {
                    print("⚠️ Snag transferring \(nextClipURL.lastPathComponent), skipping to avoid stalling queue.")
                }
                self.sendClipsSequentially(urls: queue)
            }
        }
    }
}

// MARK: - ClipIt Timing Bar

private struct ClipItTimingBar: View {
    @Binding var beforeSeconds: Int
    @Binding var afterSeconds: Int

    private let minSecBefore = 5
    private let minSecAfter = 0
    private let maxSec = 60
    private let step = 5

    private let barH: CGFloat = 44
    private let bracketW: CGFloat = 18
    private let centerBadgeW: CGFloat = 30 // Explicit width of the center "ClipIt" anchor

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let W = geo.size.width
                let half = W / 2
                
                // Establish visual boundaries flanking the center text badge
                let leftEdgeOfCenter = half - (centerBadgeW / 2)
                let rightEdgeOfCenter = half + (centerBadgeW / 2)

                // Linear percentage from 0s to 60s
                let beforeFrac = CGFloat(beforeSeconds) / CGFloat(maxSec)
                let afterFrac = CGFloat(afterSeconds) / CGFloat(maxSec)

                // Calculate exact tracking positions for the brackets
                let leftAvailableTravel = leftEdgeOfCenter - (bracketW / 2)
                let leftX = leftEdgeOfCenter - (beforeFrac * leftAvailableTravel)

                let rightAvailableTravel = (W - (bracketW / 2)) - rightEdgeOfCenter
                let rightX = rightEdgeOfCenter + (afterFrac * rightAvailableTravel)

                ZStack(alignment: .topLeading) {
                    // Track Background
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: W, height: barH)

                    // BEFORE Highlight Area (Blue)
                    Rectangle()
                        .fill(Color.blue.opacity(0.5))
                        .frame(width: max(0, leftEdgeOfCenter - (leftX - bracketW / 2)), height: barH)
                        .offset(x: leftX - bracketW / 2)

                    // AFTER Highlight Area (Red) - Drops to exactly 0 width when afterSeconds == 0
                    Rectangle()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: max(0, (rightX + bracketW / 2) - rightEdgeOfCenter), height: barH)
                        .offset(x: rightEdgeOfCenter)

                    // Center Timeline Anchor
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: barH - 14)
                        Text("ClipIt")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .frame(width: centerBadgeW, height: barH)
                    .position(x: half, y: barH / 2)

                    // LEFT BRACKET
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: 44, height: 44)
                        BracketShape(side: .left)
                            .fill(Color.white)
                            .frame(width: bracketW, height: barH - 1)
                    }
                    .position(x: leftX, y: barH / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("SliderTrack"))
                            .onChanged { value in
                                let dragX = value.location.x
                                let distanceFromCenter = leftEdgeOfCenter - dragX
                                let frac = distanceFromCenter / leftAvailableTravel
                                let sec = Int(frac * CGFloat(maxSec))
                                beforeSeconds = min(max((sec / step) * step, minSecBefore), maxSec)
                            }
                    )

                    // RIGHT BRACKET
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.001))
                            .frame(width: 44, height: 44)
                        BracketShape(side: .right)
                            .fill(Color.white)
                            .frame(width: bracketW, height: barH - 1)
                    }
                    .position(x: rightX, y: barH / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("SliderTrack"))
                            .onChanged { value in
                                let dragX = value.location.x
                                let distanceFromCenter = dragX - rightEdgeOfCenter
                                let frac = distanceFromCenter / rightAvailableTravel
                                let sec = Int(frac * CGFloat(maxSec))
                                afterSeconds = min(max((sec / step) * step, minSecAfter), maxSec)
                            }
                    )

                    // Dynamic Left Text
                    Text("\(beforeSeconds)s")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .position(x: max((leftX - bracketW) / 2, 18), y: barH / 2)

                    // Dynamic Right Text
                    Text("\(afterSeconds)s")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .position(x: min(rightX + (W - rightX) / 2, W - 18), y: barH / 2)
                }
                .coordinateSpace(name: "SliderTrack")
            }
            .frame(height: barH)

            HStack {
                Text("← Before ClipIt")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text("After ClipIt →")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }
}
// MARK: - RecordButton

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                
                // Inner record shape
                if isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 32, height: 32)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 62, height: 62)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Circle()) // 👈 FIX: Makes the entire 76x76 circle area tappable, always!
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
    }
}

// MARK: - Bracket Shape

private struct BracketShape: Shape {
    enum Side {
        case left
        case right
    }

    let side: Side
    private let thickness: CGFloat = 3
    private let capLen: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var p = Path()

        if side == .left {
            p.addRect(CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height))
            p.addRect(CGRect(x: rect.minX, y: rect.minY, width: capLen, height: thickness))
            p.addRect(CGRect(x: rect.minX, y: rect.maxY - thickness, width: capLen, height: thickness))
        } else {
            p.addRect(CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height))
            p.addRect(CGRect(x: rect.maxX - capLen, y: rect.minY, width: capLen, height: thickness))
            p.addRect(CGRect(x: rect.maxX - capLen, y: rect.maxY - thickness, width: capLen, height: thickness))
        }
        return p
    }
}

// MARK: - FocusIndicatorView

private struct FocusIndicatorView: View {
    let showBrightness: Bool
    @Binding var exposureBias: Double
    let onSliderChanged: () -> Void

    @State private var scale: CGFloat = 1.35
    @State private var localExposure: Double = 0.0
    @State private var isDragging = false
    @State private var dragStartExposure: Double = 0.0

    private let boxSize: CGFloat = 68
    private let trackHeight: CGFloat = 110

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.yellow, lineWidth: 1.5)
                .frame(width: boxSize, height: boxSize)
                .scaleEffect(scale)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.2)) { scale = 1.0 }
                    localExposure = exposureBias
                }
            
            if showBrightness {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 44, height: trackHeight + 40)
                    
                    Rectangle()
                        .fill(Color.yellow.opacity(0.6))
                        .frame(width: 1, height: trackHeight)
                    
                    Image(systemName: "sun.max.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.yellow)
                        .offset(y: -CGFloat(localExposure) * (trackHeight / 4.0))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartExposure = localExposure
                            }
                            let dragAmount = -value.translation.height
                            let dragFactor = 4.0 / trackHeight
                            let newExposure = dragStartExposure + (dragAmount * dragFactor)
                            localExposure = min(max(newExposure, -2.0), 2.0)
                            exposureBias = localExposure
                            onSliderChanged()
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
    }
}

// MARK: - Camera permission gate

private struct CameraPermissionGate: View {
    @ObservedObject var cameraManager: CameraManager
    var onLayerReady: (AVCaptureVideoPreviewLayer) -> Void

    var body: some View {
        Group {
            if cameraManager.permissionGranted && cameraManager.isRunning {
                CameraPreviewView(cameraManager: cameraManager, onLayerReady: onLayerReady)
                    .id(cameraManager.isRunning)
            } else if cameraManager.permissionGranted {
                Color.black
            } else {
                Rectangle()
                    .fill(Color(white: 0.06))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "video.slash")
                                .font(.system(size: 36))
                                .foregroundColor(Color.white.opacity(0.45))
                            Text("Camera access required")
                                .font(.caption)
                                .foregroundColor(Color.white.opacity(0.6))
                        }
                    )
            }
        }
    }
}

// MARK: - Shared UI components

private struct CircleButton: View {
    let systemImage: String
    var size: CGFloat = 56
    var disabled: Bool = false
    var fill: Color = Color.white.opacity(0.14)
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundColor(disabled ? Color.white.opacity(0.35) : foreground)
                .frame(width: size, height: size)
                .background(disabled ? Color.white.opacity(0.08) : fill)
                .clipShape(Circle())
        }
        .disabled(disabled)
    }
}
