import SwiftUI
import AVFoundation

struct RecordView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    @ObservedObject var bleVM: BLEViewModel
    @Binding var selectedTab: Int
    @State private var orientation = UIDevice.current.orientation
    
    // Call Monitor Interruption Interface
    @StateObject private var callMonitor = CallMonitor()
    @State private var showCallInterruptionOverlay = false
    
    // Clip saved banner
    @State private var showClipSavedBanner = false
    @State private var clipSavedText = ""
    @State private var clipSavedIsFavorite = false
    @State private var clipSavedHideTask: DispatchWorkItem?
    
    // Pinch-to-zoom
    @State private var lastZoomFactor: CGFloat = 1.0
    
    // Tap-to-focus + inline brightness slider
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusIndicator = false
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
    @Environment(\.scenePhase) var scenePhase
    
    private var exposureBiasBinding: Binding<Double> {
        Binding(
            get: { Double(recordingVM.cameraManager.exposureBias) },
            set: { recordingVM.cameraManager.setExposureBias(Float($0)) }
        )
    }
    
    var body: some View {
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
                FocusIndicatorView()
                    .position(pt)
                    .allowsHitTesting(false)
                    .zIndex(2)
                    .id(focusID)
            }
            
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                let isLandscapeRight = orientation == .landscapeRight
                let isLandscapeLeft = !isLandscapeRight // Default landscape mode to left
                let isIPad = UIDevice.current.userInterfaceIdiom == .pad
                
                ZStack {
                    // Gesture Capture Layer
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let zoomSensitivity: CGFloat = 1.6
                                    let dynamicDelta = value.magnitude
                                    let baseZoom = recordingVM.cameraManager.zoomFactor
                                    let targetZoom = lastZoomFactor == 1.0
                                        ? baseZoom * dynamicDelta
                                        : baseZoom + ((value - lastZoomFactor) * zoomSensitivity)
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
                    
                    // 🎛️ Dynamic Orientation Layout Switcher
                    if isLandscape {
                        landscapeOverlayView(
                            isLandscapeLeft: isLandscapeLeft,
                            isIPad: isIPad,
                            layoutHeight: geo.size.height
                        )
                            .zIndex(1)
                    } else {
                        portraitOverlayView
                            .zIndex(1)
                    }
                    
                    // Clip saved notification banner overlay
                    VStack {
                        Spacer()
                        if showClipSavedBanner {
                            HStack(spacing: 12) {
                                Text(clipSavedText)
                                    .font(.system(size: 20, weight: .heavy))
                                    .foregroundColor(.crimsonBlaze)
                                Button {
                                    recordingVM.favoriteLatestTriggeredClip()
                                    clipSavedIsFavorite = true
                                } label: {
                                    Image(systemName: clipSavedIsFavorite ? "heart.fill" : "heart")
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundColor(.crimsonBlaze)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(clipSavedIsFavorite ? "Clip favorited" : "Favorite clip")
                            }
                                .padding(.horizontal, 22)
                                .padding(.vertical, 24)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(color: Color.black.opacity(0.25), radius: 10, y: 4)
                                .transition(.opacity)
                        }
                        Spacer()
                    }
                    .animation(.easeInOut(duration: 0.25), value: showClipSavedBanner)
                    .zIndex(2)
                }
                .animation(.easeInOut(duration: 0.25), value: isLandscape)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                // The interface and its controls stay in the orientation in
                // which this recording began, even as the phone is moved.
                guard recordingVM.recordingState != .active else { return }
                let newOrientation = UIDevice.current.orientation
                if newOrientation.isValidInterfaceOrientation { orientation = newOrientation }
            }
            
            // Phone call interruption overlay
            callInterruptionOverlayView
            
            // 🎯 Centered "Saving Your Clips!" popup
            if recordingVM.isExtractingHighlights {
                HighlightExtractionProgressView(
                    currentCount: recordingVM.currentExtractionProgress,
                    totalCount: recordingVM.totalExtractionCount
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: recordingVM.isExtractingHighlights)
        .keepScreenAwake()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: orientation)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showCameraControls)
        .sheet(isPresented: $showMultiCamSheet) {
            MultiCamConnectionSheet(multipeerManager: multipeerManager)
        }
        .onReceive(bleVM.clipTrigger) { _ in
            triggerClipIt()
        }
        .onReceive(bleVM.startRecordTrigger) { _ in
            startRecording()
        }
        .onReceive(bleVM.stopRecordTrigger) { _ in
            stopRecording()
        }
        .onReceive(bleVM.toggleRecordTrigger) { _ in
            handleRecordTap()
        }
        .onReceive(bleVM.remoteCommandReadyTrigger) { _ in
            sendCurrentRecordingStateToRemote()
        }
        .onAppear {
            callMonitor.setupViewModel(recordingVM)
            recordingVM.cameraManager.startIfNeeded()
            if !bleVM.bleState.isConnected { bleVM.startScanning() }
            
            multipeerManager.onHighlightReceived = { [weak recordingVM] url in
                Task { @MainActor in
                    recordingVM?.attachImportedHighlight(fileURL: url)
                }
            }
        }
        .onDisappear {
            // The Device tab owns the active scan while it is visible.
            if selectedTab != 2 {
                bleVM.stopScanning()
            }
        }
        .onChange(of: recordingVM.showCallEndedOverlay) { _, shouldShow in
            if shouldShow {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showCallInterruptionOverlay = true
                }
                recordingVM.showCallEndedOverlay = false
            }
        }
        .onChange(of: multipeerManager.latestCommandReceived) { _, command in
            guard let command = command else { return }
            handleSyncCommand(command)
            multipeerManager.latestCommandReceived = nil
        }
        .onChange(of: recordingVM.bufferLengthSeconds) { _, newValue in
            multipeerManager.sendCommand(.updateSettings(secondsBefore: newValue, secondsAfter: recordingVM.postRollSeconds))
        }
        .onChange(of: recordingVM.postRollSeconds) { _, newValue in
            multipeerManager.sendCommand(.updateSettings(secondsBefore: recordingVM.bufferLengthSeconds, secondsAfter: newValue))
        }
        .onChange(of: recordingVM.justFinishedSessionClips) { _, newURLs in
            guard !newURLs.isEmpty else { return }
            
            if transferClipsOnCompletion {
                print("🎬 Extraction complete! Secondary camera auto-offloading \(newURLs.count) highlights...")
                startOffloadingSecondaryHighlights(urls: newURLs)
                transferClipsOnCompletion = false
                recordingVM.justFinishedSessionClips = []
            }
        }
        .onChange(of: recordingVM.recordingState) { _, newState in
            sendCurrentRecordingStateToRemote()

            if newState == .active {
                if dimScreenDuringRecording {
                    originalBrightness = UIScreen.main.brightness
                    UIScreen.main.brightness = 0.01
                }
            } else {
                let currentOrientation = UIDevice.current.orientation
                if currentOrientation.isValidInterfaceOrientation {
                    orientation = currentOrientation
                }
                if dimScreenDuringRecording {
                    UIScreen.main.brightness = originalBrightness
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active && dimScreenDuringRecording {
                UIScreen.main.brightness = originalBrightness
            }
        }
    }
    
    // MARK: - Multipeer Command Handler

    private func handleSyncCommand(_ command: SyncCommand) {
        switch command {
        case .startRecording:
            if recordingVM.recordingState != .active {
                transferClipsOnCompletion = false
                recordingVM.requestStartSession(multipeerManager: multipeerManager)
            }
        case .stopRecording:
            if recordingVM.recordingState == .active {
                recordingVM.endSession(navigateToClips: false)
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
    }
    
    // MARK: - Landscape Layout View

    @ViewBuilder
    private func landscapeOverlayView(
        isLandscapeLeft: Bool,
        isIPad: Bool,
        layoutHeight: CGFloat
    ) -> some View {
        ZStack {
            // 1. TOP BAR CONTROLS
            VStack {
                ZStack {
                    HStack(alignment: .top) {
                        if isLandscapeLeft {
                        VStack(alignment: .leading, spacing: 6) {
                                connectedBadge
                            }
                            
                            Spacer()
                            
                            StaticZoomControl(cameraManager: recordingVM.cameraManager)
                        } else {
                            StaticZoomControl(cameraManager: recordingVM.cameraManager)
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 6) {
                                connectedBadge
                            }
                        }
                    }

                    recordingTimerBadge
                }
                .padding(.horizontal, 36)
                .padding(.top, 24)

                // Status banners
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
                    .padding(.top, 10)
                }

                Spacer()
            }

            // 2. Settings button
            VStack {
                HStack {
                    if isLandscapeLeft {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showCameraControls.toggle()
                            }
                        } label: {
                            timingBadge
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showCameraControls.toggle()
                            }
                        } label: {
                            timingBadge
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(.horizontal, isIPad ? 45 : 36)
                // Phone has a compact, side-mounted control column. On iPad,
                // place the timing button at roughly 70% of the screen height:
                // below the record button and above the custom bottom tab bar.
                .padding(.top, isIPad ? layoutHeight * 0.70 : 280)

                Spacer()
            }

            // 3. CENTER STACK: Record & ClipIt Button
            HStack {
                if isLandscapeLeft {
                    Spacer()
                    RecordControlGroup(
                        isRecording: recordingVM.recordingState == .active,
                        onRecordTap: { handleRecordTap() },
                        onClipItTap: { triggerClipIt() },
                        clipItOffset: CGSize(width: -120, height: 0)
                    )
                    .padding(.trailing, 45)
                } else {
                    RecordControlGroup(
                        isRecording: recordingVM.recordingState == .active,
                        onRecordTap: { handleRecordTap() },
                        onClipItTap: { triggerClipIt() },
                        clipItOffset: CGSize(width: 120, height: 0)
                    )
                    .padding(.leading, 45)
                    Spacer()
                }
            }

            // 4. SETTINGS DRAWER OVERLAY
            if showCameraControls {
                cameraControlsPanel(isLandscape: true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Portrait Layout View

    @ViewBuilder
    private var portraitOverlayView: some View {
        ZStack {
            VStack(spacing: 0) {
                topOverlayView(isLandscape: false)
                Spacer()
                bottomOverlay
            }

            if showCameraControls {
                cameraControlsPanel(isLandscape: false)
                    .transition(.scale.combined(with: .opacity))
            }
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
                            .foregroundColor(.crimsonBlaze)
                        
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

        withAnimation(.easeIn(duration: 0.1)) { showFocusIndicator = true }
        focusHideTask?.cancel()
        
        let hideTask = DispatchWorkItem { [weak recordingVM] in
            _ = recordingVM
            withAnimation(.easeOut(duration: 0.3)) {
                self.showFocusIndicator = false
            }
        }
        focusHideTask = hideTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hideTask)
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
            ZStack {
                HStack(alignment: .top) {
                    if !isLandscape {
                        VStack(alignment: .leading, spacing: 6) {
                            connectedBadge
                        }
                    }
                    
                    Spacer()
                }

                recordingTimerBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 45)
            
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
            else if multipeerManager.isSendingFullVideo || multipeerManager.isReceivingFullVideo {
                VStack(spacing: 6) {
                    Text(multipeerManager.isSendingFullVideo ? "Sending Full Recording to Host..." : "Receiving Full Studio Recording...")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                    
                    ProgressView(value: multipeerManager.fullVideoProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(.blueMarble)
                        .frame(maxWidth: 220)
                    
                    Text("\(Int(multipeerManager.fullVideoProgress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.blueMarble)
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
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: "gobackward")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(recordingVM.bufferLengthSeconds)s")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.white)
        }
        .frame(width: 54, height: 54)
        .background(Color.crimsonBlaze.opacity(0.75), in: Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var connectedBadge: some View {
        if bleVM.bleState.isConnected {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)

                Text("ClipIt Button\nConnected")
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
        }
    }
    
    @ViewBuilder
    private var recordingTimerBadge: some View {
        if recordingVM.recordingState == .active {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                    let halfSecond = Int(timeline.date.timeIntervalSinceReferenceDate / 0.5)
                    Circle()
                        .fill(Color.crimsonBlaze)
                        .frame(width: 8, height: 8)
                        .opacity(halfSecond.isMultiple(of: 2) ? 1 : 0)
                }
                .frame(width: 8, height: 8)
                Text(recordingVM.elapsedLabel)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .transition(.opacity)
        }
    }
    
    // MARK: - Camera controls panel

    private func cameraControlsPanel(isLandscape: Bool) -> some View {
        VStack(spacing: isLandscape ? 8 : 16) {
            PrecedingTimeControl(seconds: $recordingVM.bufferLengthSeconds)

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
        .padding(.horizontal, 16)
        .padding(.vertical, isLandscape ? 10 : 16)
        .frame(maxWidth: isLandscape ? 380 : 450)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.bottom, isLandscape ? 0 : 8)
    }

    // MARK: - Bottom overlay (Portrait View Layer)

    @ViewBuilder
    private var bottomOverlay: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showCameraControls.toggle()
                    }
                } label: {
                    timingBadge
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)

                Spacer()
                InteractiveZoomControl(cameraManager: recordingVM.cameraManager)
            }
            .padding(.horizontal, 16)

            RecordControlGroup(
                isRecording: recordingVM.recordingState == .active,
                onRecordTap: { handleRecordTap() },
                onClipItTap: { triggerClipIt() },
                clipItOffset: CGSize(width: 0, height: -120)
            )
            .offset(y: -50)
            .padding(.bottom, -10)
        }
        .padding(.bottom, 20)
        .safeAreaPadding(.bottom, 30)
        .background(
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.65)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
    
    // Helper methods
    private func triggerClipIt() {
        if recordingVM.recordingState == .active {
            recordingVM.triggerClip()
            showClipSavedConfirmation()
            multipeerManager.sendCommand(.triggerClip(clipNumber: 1, uuid: UUID()))
        }
    }

    private func handleRecordTap() {
        if recordingVM.recordingState == .active {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard recordingVM.recordingState != .active else { return }

        transferClipsOnCompletion = false
        recordingVM.requestStartSession(multipeerManager: multipeerManager)
        multipeerManager.sendCommand(.startRecording)
    }

    private func stopRecording() {
        guard recordingVM.recordingState == .active else { return }

        recordingVM.endSession(navigateToClips: false)
        multipeerManager.sendCommand(.stopRecording)

        if multipeerManager.isHost && !multipeerManager.connectedPeers.isEmpty {
            showImportPrompt = true
        }
    }

    private func sendCurrentRecordingStateToRemote() {
        let command = recordingVM.recordingState == .active
            ? "RECORDING_STATE 1"
            : "RECORDING_STATE 0"

        bleVM.sendRemoteCommand(command)
    }
    
    private func showClipSavedConfirmation() {
        clipSavedHideTask?.cancel()
        clipSavedText = "Clip #\(recordingVM.clipCount) saved!"
        clipSavedIsFavorite = recordingVM.latestTriggeredClip?.isFavorite ?? false
        withAnimation(.easeInOut(duration: 0.2)) { showClipSavedBanner = true }
        
        let task = DispatchWorkItem { [weak recordingVM] in
            _ = recordingVM
            withAnimation(.easeOut(duration: 0.5)) { self.showClipSavedBanner = false }
        }
        clipSavedHideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }
    
    // MARK: - Post-Game Network Pipeline

    private func startOffloadingSecondaryHighlights(urls: [URL]) {
        Task { @MainActor in
            multipeerManager.expectedSendingHighlightCount = urls.count
            multipeerManager.sentHighlightCount = 0
            multipeerManager.isSendingHighlightsBatch = true
            multipeerManager.isTransferringFile = true
        }
        
        multipeerManager.sendCommand(.preparingToSendHighlights(total: urls.count))
        sendClipsSequentially(urls: urls)
    }

    private func sendClipsSequentially(urls: [URL]) {
        var queue = urls
        guard !queue.isEmpty else {
            print("🏁 All secondary angles successfully offloaded to primary device!")
            multipeerManager.sendCommand(.finishedSendingHighlights)
            return
        }
        
        let nextClipURL = queue.removeFirst()
        print("MB Offloading secondary angle view: \(nextClipURL.lastPathComponent)")
        
        multipeerManager.sendLargeFile(fileURL: nextClipURL, isFullSessionVideo: false) { success in
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

// MARK: - Static Zoom Control for Landscape (No Drag Slider)

private struct StaticZoomControl: View {
    @ObservedObject var cameraManager: CameraManager

    private var currentUIZoom: CGFloat {
        cameraManager.zoomFactor * 0.5
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                snapTo(uiZoom: 0.5)
            } label: {
                Text(".5x")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 38)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)

            Button {
                snapTo(uiZoom: 1.0)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle()
                                .stroke(isZoomed ? Color.gochujangRed : Color.white.opacity(0.25), lineWidth: isZoomed ? 1.8 : 0.8)
                        )

                    Text(isZoomed ? String(format: "%.1fx", currentUIZoom) : "1.0x")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isZoomed ? Color.gochujangRed : .white)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var isZoomed: Bool {
        abs(currentUIZoom - 1.0) > 0.05
    }

    private func snapTo(uiZoom: CGFloat) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let targetHardware = uiZoom * 2.0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            cameraManager.setZoom(targetHardware)
        }
    }
}

// MARK: - Record Control Group (Stacked ClipIt & Record Buttons)

private struct RecordControlGroup: View {
    let isRecording: Bool
    let onRecordTap: () -> Void
    let onClipItTap: () -> Void
    
    let clipItOffset: CGSize

    var body: some View {
        ZStack(alignment: .center) {
            Button(action: onClipItTap) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.crimsonBlaze : Color.white.opacity(0.2))
                        .frame(width: 125, height: 125)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(isRecording ? 0.4 : 0.2), lineWidth: 2)
                        )
                        .shadow(color: isRecording ? Color.crimsonBlaze.opacity(0.6) : .clear, radius: 10, y: 4)

                    Text("ClipIt")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(isRecording ? .white : .white.opacity(0.5))
                }
            }
            .offset(clipItOffset)
            .disabled(!isRecording)
            .buttonStyle(.plain)

            RecordButton(isRecording: isRecording, action: onRecordTap)
        }
        .frame(width: 80, height: 80)
    }
}

// MARK: - Interactive Zoom Control for Portrait

private struct InteractiveZoomControl: View {
    @ObservedObject var cameraManager: CameraManager

    @State private var isDragging = false
    @State private var dragStartY: CGFloat = 0
    @State private var initialHardwareZoom: CGFloat = 2.0
    @State private var lastHapticThreshold: Int = -1

    private var currentUIZoom: CGFloat {
        cameraManager.zoomFactor * 0.5
    }

    private var currentDisplayString: String {
        String(format: "%.1f", currentUIZoom)
    }

    private var normalizedZoomProgress: CGFloat {
        let minZ = cameraManager.minZoom
        let maxZ = cameraManager.maxZoom
        return (cameraManager.zoomFactor - minZ) / (maxZ - minZ)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isDragging {
                VStack(spacing: 8) {
                    Text("\(currentDisplayString)x")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundColor(.varden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .clipShape(Capsule())

                    GeometryReader { geo in
                        let trackHeight = geo.size.height
                        let thumbY = trackHeight * (1.0 - normalizedZoomProgress)

                        ZStack(alignment: .top) {
                            Capsule()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 6, height: trackHeight)

                            Capsule()
                                .fill(Color.varden)
                                .frame(width: 6, height: trackHeight - thumbY)
                                .offset(y: thumbY)

                            Circle()
                                .fill(Color.varden)
                                .frame(width: 18, height: 18)
                                .shadow(color: .black.opacity(0.4), radius: 3)
                                .position(x: geo.size.width / 2, y: thumbY)
                        }
                    }
                    .frame(width: 24, height: 120)
                }
                .padding(.bottom, 64)
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                if currentUIZoom != 0.5 || isDragging {
                    Button {
                        snapTo(uiZoom: 0.5)
                    } label: {
                        Text(".5x")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 42, height: 36)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                CircleButtonView(
                    displayString: "\(currentDisplayString)x",
                    isActive: abs(currentUIZoom - 1.0) > 0.05
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isDragging {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                                    isDragging = true
                                }
                                dragStartY = value.location.y
                                initialHardwareZoom = cameraManager.zoomFactor
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }

                            let deltaY = dragStartY - value.location.y
                            let zoomShiftUI = deltaY / 100.0
                            let targetHardwareZoom = initialHardwareZoom + (zoomShiftUI * 2.0)
                            let clampedHardware = targetHardwareZoom.clamped(to: cameraManager.minZoom...cameraManager.maxZoom)

                            cameraManager.setZoom(clampedHardware)

                            let hapticStep = Int((clampedHardware * 0.5) * 2)
                            if hapticStep != lastHapticThreshold {
                                lastHapticThreshold = hapticStep
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                        .onEnded { value in
                            let totalDragDistance = abs(dragStartY - value.location.y)

                            if totalDragDistance < 6 {
                                snapTo(uiZoom: 1.0)
                            }

                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                isDragging = false
                            }
                        }
                )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: currentUIZoom)
    }

    private func snapTo(uiZoom: CGFloat) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let targetHardware = uiZoom * 2.0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            cameraManager.setZoom(targetHardware)
        }
    }
}

private struct CircleButtonView: View {
    let displayString: String
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .frame(width: 54, height: 54)
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.varden : Color.white.opacity(0.25), lineWidth: isActive ? 1.8 : 0.8)
                )

            Text(displayString)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isActive ? .varden : .white)
        }
    }
}

// MARK: - Preceding Time Control (ClipIt Save Time)

private struct PrecedingTimeControl: View {
    @Binding var seconds: Int

    private let minSeconds: Double = 5
    private let maxSeconds: Double = 60
    private let step: Double = 5
    private let baselineSeconds: Double = 15
    private let quickOptions: [Int] = [5, 10, 15, 20, 30, 60]
    private let trackHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            header
            slider
            quickSnapRow
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text("ClipIt Highlight Length")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
        }
    }

    private var slider: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat((Double(seconds) - minSeconds) / (maxSeconds - minSeconds))
            let baselineFrac = CGFloat((baselineSeconds - minSeconds) / (maxSeconds - minSeconds))
            let fillWidth = w * (baselineFrac + frac * (1 - baselineFrac))
            let thumbX = min(max(fillWidth, trackHeight / 2), w - 2)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .frame(width: w, height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.crimsonBlaze, Color.crimsonBlaze.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: trackHeight)

                Text("\(seconds)s")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.leading, 14)

                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)

                    HStack(spacing: 2.5) {
                        Capsule().fill(Color.crimsonBlaze.opacity(0.6)).frame(width: 2, height: 14)
                        Capsule().fill(Color.crimsonBlaze.opacity(0.6)).frame(width: 2, height: 14)
                        Capsule().fill(Color.crimsonBlaze.opacity(0.6)).frame(width: 2, height: 14)
                    }
                }
                .position(x: thumbX, y: trackHeight / 2)
            }
            .frame(width: w, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), w)
                        let targetFrac = Double(x / w)
                        let f = max(0, (targetFrac - Double(baselineFrac)) / (1 - Double(baselineFrac)))
                        let sec = minSeconds + f * (maxSeconds - minSeconds)
                        let snapped = (sec / step).rounded() * step
                        seconds = Int(min(max(snapped, minSeconds), maxSeconds))
                    }
            )
        }
        .frame(height: trackHeight)
    }

    private var quickSnapRow: some View {
        HStack(spacing: 6) {
            ForEach(quickOptions, id: \.self) { option in
                let isSelected = seconds == option

                Button {
                    withAnimation(.snappy) { seconds = option }
                } label: {
                    Text("\(option)s")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.8))
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(isSelected ? Color.crimsonBlaze : Color.crimsonBlaze.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
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
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                
                if isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.crimsonBlaze)
                        .frame(width: 32, height: 32)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(Color.crimsonBlaze)
                        .frame(width: 62, height: 62)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
    }
}

// MARK: - FocusIndicatorView (Apple Camera Style)

private struct FocusIndicatorView: View {
    @State private var scale: CGFloat = 1.3
    private let boxSize: CGFloat = 70

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.varden, lineWidth: 1.2)

            Rectangle()
                .fill(Color.varden)
                .frame(width: 1.5, height: 7)
                .frame(maxHeight: .infinity, alignment: .top)

            Rectangle()
                .fill(Color.varden)
                .frame(width: 1.5, height: 7)
                .frame(maxHeight: .infinity, alignment: .bottom)

            Rectangle()
                .fill(Color.varden)
                .frame(width: 7, height: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.varden)
                .frame(width: 7, height: 1.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: boxSize, height: boxSize)
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                scale = 1.0
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

private func getBatteryColor(for level: Int) -> Color {
    switch level {
    case ...20:  return .red
    case 21...50: return .orange
    default:      return .green
    }
}

private func getBatteryIcon(for level: Int) -> String {
    switch level {
    case ...10:   return "battery.0percent"
    case 11...35:  return "battery.25percent"
    case 36...65:  return "battery.50percent"
    case 66...85:  return "battery.75percent"
    default:       return "battery.100percent"
    }
}
