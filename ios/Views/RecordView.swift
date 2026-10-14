import SwiftUI
import AVFoundation
import CoreMotion
import Combine

struct RecordView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @ObservedObject var bleVM: BLEViewModel
    @Binding var selectedTab: Int
    var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil
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
    @State private var isCameraTransitioning = false
    @State private var cameraSwitchCoverVisible = false
    @State private var cameraTransitionTask: Task<Void, Never>?
    
    // Preview layer ref for focus point conversion
    @State private var previewLayerRef: AVCaptureVideoPreviewLayer? = nil
    
    // Hashable variable for tap focus
    @State private var focusID = UUID()
    @State private var localQuality: CameraManager.VideoQuality? = nil
    
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
                .overlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.72))
                        .opacity(cameraSwitchCoverVisible ? 1 : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            
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
                        .allowsHitTesting(!isCameraTransitioning)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    guard !recordingVM.cameraManager.isSwitchingCamera else { return }
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

                    CameraLevelIndicator(
                        orientation: orientation,
                        isLandscape: isLandscape,
                        isActive: selectedTab == 0
                    )
                    .allowsHitTesting(false)
                    .zIndex(0.5)
                    
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
                        if let commandError = bleVM.commandError {
                            Label(commandError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(Color.crimsonBlaze, in: Capsule())
                                .padding(.horizontal, 24)
                        }
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
        .onAppear {
            callMonitor.setupViewModel(recordingVM)
            recordingVM.cameraManager.startIfNeeded()
            if !bleVM.bleState.isConnected { bleVM.startScanning() }
            
        }
        .onDisappear {
            cameraTransitionTask?.cancel()
            cameraTransitionTask = nil
            cameraSwitchCoverVisible = false
            isCameraTransitioning = false
            // Auto-reconnect belongs to BLEViewModel, not the Record tab.
            // Leaving Record must not cancel an in-progress recovery scan.
            if !bleVM.autoReconnect && selectedTab != 2 {
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
        .onChange(of: recordingVM.recordingState) { _, newState in
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
        .onChange(of: recordingVM.clipCount) { _, count in
            if count > 0 && recordingVM.recordingState == .active {
                showClipSavedConfirmation()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active && dimScreenDuringRecording {
                UIScreen.main.brightness = originalBrightness
            }
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

                            HStack(spacing: 10) {
                                StaticZoomControl(cameraManager: recordingVM.cameraManager)
                                cameraFlipButton
                            }
                        } else {
                            HStack(spacing: 10) {
                                cameraFlipButton
                                StaticZoomControl(cameraManager: recordingVM.cameraManager)
                            }
                            
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
                        isRecording: recordingVM.cameraConfirmedRecording,
                        onRecordTap: { handleRecordTap() },
                        onClipItTap: { triggerClipIt() },
                        clipItOffset: CGSize(width: -120, height: 0)
                    )
                    .padding(.trailing, 45)
                } else {
                    RecordControlGroup(
                        isRecording: recordingVM.cameraConfirmedRecording,
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
                    onPreviewLayerReady?(layer)
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
                    cameraFlipButton
                }

                recordingTimerBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 45)

        }
        .transition(.opacity)
    }

    private var cameraFlipButton: some View {
        let cameraManager = recordingVM.cameraManager
        let canSwitch = cameraManager.supportsCameraFlip && recordingVM.recordingState == .idle &&
            cameraManager.isRunning && !cameraManager.isSwitchingCamera && !isCameraTransitioning

        return Button {
            switchCameraWithTransition()
        } label: {
            Image(systemName: "camera.rotate")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 54, height: 54)
                .background(Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
        .opacity(canSwitch ? 1 : 0.5)
        .accessibilityLabel(cameraManager.isUsingFrontCamera ? "Switch to back camera" : "Switch to front camera")
        .accessibilityHint("Available between recordings")
    }

    private func switchCameraWithTransition() {
        guard !isCameraTransitioning, recordingVM.recordingState == .idle else { return }
        isCameraTransitioning = true
        withAnimation(.easeIn(duration: 0.18)) {
            cameraSwitchCoverVisible = true
        }

        cameraTransitionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 190_000_000)
            guard !Task.isCancelled, selectedTab == 0 else { return }

            let switched = await withCheckedContinuation { continuation in
                recordingVM.cameraManager.flipCamera { success in
                    continuation.resume(returning: success)
                }
            }
            guard !Task.isCancelled else { return }

            // CameraManager waits for the first frame from the replacement
            // camera; allow one display beat before fading the cover away.
            if switched { try? await Task.sleep(nanoseconds: 80_000_000) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                cameraSwitchCoverVisible = false
            }
            try? await Task.sleep(nanoseconds: 240_000_000)
            isCameraTransitioning = false
            cameraTransitionTask = nil
        }
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
        .tutorialTarget(.timing)
    }

    @ViewBuilder
    private var connectedBadge: some View {
        if bleVM.bleState.isConnected || bleVM.hasConnectedButtonThisLaunch {
            let connected = bleVM.bleState.isConnected
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.red)
                    .frame(width: 7, height: 7)

                Text(connected ? "ClipIt Button\nConnected" : "ClipIt Button\nDisconnected")
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
        if recordingVM.cameraConfirmedRecording {
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
                isRecording: recordingVM.cameraConfirmedRecording,
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

        recordingVM.requestStartSession()
    }

    private func stopRecording() {
        guard recordingVM.recordingState == .active else { return }

        recordingVM.endSession(navigateToClips: false)
    }

    private func showClipSavedConfirmation() {
        clipSavedHideTask?.cancel()
        // Extraction happens after recording stops, so this is a marker,
        // not a saved video file yet.
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
    
}

// MARK: - Static Zoom Control for Landscape (No Drag Slider)

private struct StaticZoomControl: View {
    @ObservedObject var cameraManager: CameraManager

    private var currentUIZoom: CGFloat {
        cameraManager.displayZoomFactor
    }

    var body: some View {
        HStack(spacing: 8) {
            if !cameraManager.isUsingFrontCamera {
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
            }

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
                                .stroke(isZoomed ? Color.blueMarble : Color.white.opacity(0.25), lineWidth: isZoomed ? 1.8 : 0.8)
                        )

                    Text(isZoomed ? String(format: "%.1fx", currentUIZoom) : "1.0x")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(isZoomed ? Color.blueMarble : .white)
                }
            }
            .buttonStyle(.plain)
            .tutorialTarget(.zoom)
        }
    }

    private var isZoomed: Bool {
        abs(currentUIZoom - 1.0) > 0.05
    }

    private func snapTo(uiZoom: CGFloat) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let targetHardware = cameraManager.hardwareZoomFactor(for: uiZoom)
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
                // Measure the visible circle before the button is offset away
                // from the record control. Measuring the outer offset button
                // reports its original layout slot instead.
                .tutorialTarget(.clipIt)
            }
            .offset(clipItOffset)
            .disabled(!isRecording)
            .buttonStyle(.plain)

            RecordButton(isRecording: isRecording, action: onRecordTap)
                .tutorialTarget(.record)
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
        cameraManager.displayZoomFactor
    }

    private var currentDisplayString: String {
        String(format: "%.1f", currentUIZoom)
    }

    private var normalizedZoomProgress: CGFloat {
        let minZ = cameraManager.minZoom
        let maxZ = cameraManager.maxZoom
        return maxZ > minZ ? (cameraManager.zoomFactor - minZ) / (maxZ - minZ) : 0
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
                if !cameraManager.isUsingFrontCamera && (currentUIZoom != 0.5 || isDragging) {
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
                .tutorialTarget(.zoom)
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
                            let targetHardwareZoom = initialHardwareZoom +
                                (zoomShiftUI * (cameraManager.isUsingFrontCamera ? 1.0 : 2.0))
                            let clampedHardware = targetHardwareZoom.clamped(to: cameraManager.minZoom...cameraManager.maxZoom)

                            cameraManager.setZoom(clampedHardware)

                            let displayZoom = clampedHardware / (cameraManager.isUsingFrontCamera ? 1.0 : 2.0)
                            let hapticStep = Int(displayZoom * 2)
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
        let targetHardware = cameraManager.hardwareZoomFactor(for: uiZoom)
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

// MARK: - Camera level

private enum CameraLevelTuning {
    static let showAngle = Double.pi / 9             // x degrees
    static let levelTolerance = Double.pi / 120      // 1.5 degrees
    static let levelExitTolerance = Double.pi / 72   // 2.5 degrees; avoids flicker
    static let alignedHoldDuration = 0.16
    static let fadeDuration = 0.22
    static let motionUpdateInterval = 1.0 / 60.0
    static let smoothingFraction = 0.3
    static let minimumGravityProjection = 0.2
}

private struct CameraLevelIndicator: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var motion = CameraLevelMotion()

    let orientation: UIDeviceOrientation
    let isLandscape: Bool
    let isActive: Bool

    private let centerLineWidth: CGFloat = 104
    private let sideLineWidth: CGFloat = 26
    private let lineSpacing: CGFloat = 8

    private var alignedLineWidth: CGFloat {
        centerLineWidth + 2 * sideLineWidth + 2 * lineSpacing
    }

    private var referenceOrientation: UIDeviceOrientation {
        // Geometry describes the actual interface layout; UIDevice orientation
        // is only used when it agrees with that layout (including while recording).
        if isLandscape {
            return orientation == .landscapeRight ? .landscapeRight : .landscapeLeft
        }
        return orientation == .portraitUpsideDown ? .portraitUpsideDown : .portrait
    }

    var body: some View {
        ZStack {
            HStack(spacing: lineSpacing) {
                sideLine
                Capsule()
                    .fill(.white)
                    .frame(width: centerLineWidth, height: 2)
                    .rotationEffect(.radians(-motion.rollRadians))
                sideLine
            }
            .opacity(motion.isAligned ? 0 : 1)

            Capsule()
                .fill(.yellow)
                .frame(width: alignedLineWidth, height: 2)
                .opacity(motion.isAligned ? 1 : 0)
        }
        .frame(width: alignedLineWidth, height: 44)
        .opacity(motion.opacity)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        .accessibilityHidden(true)
        .onAppear(perform: updateMotionActivity)
        .onDisappear { motion.stop() }
        .onChange(of: referenceOrientation) { _, newOrientation in
            motion.setReferenceOrientation(newOrientation)
        }
        .onChange(of: isActive) { _, _ in updateMotionActivity() }
        .onChange(of: scenePhase) { _, _ in updateMotionActivity() }
    }

    private var sideLine: some View {
        Capsule()
            .fill(.white)
            .frame(width: sideLineWidth, height: 2)
    }

    private func updateMotionActivity() {
        if isActive && scenePhase == .active {
            motion.start(referenceOrientation: referenceOrientation)
        } else {
            motion.stop()
        }
    }
}

@MainActor
private final class CameraLevelMotion: ObservableObject {
    @Published private(set) var rollRadians = 0.0
    @Published private(set) var isAligned = false
    @Published private(set) var opacity = 0.0

    private let manager = CMMotionManager()
    private var referenceOrientation: UIDeviceOrientation = .portrait
    private var filteredRoll: Double?
    private var isWithinShowRange = false
    private var fadeWorkItem: DispatchWorkItem?

    func start(referenceOrientation: UIDeviceOrientation) {
        setReferenceOrientation(referenceOrientation)
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }

        manager.deviceMotionUpdateInterval = CameraLevelTuning.motionUpdateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let deviceMotion else { return }
            let x = deviceMotion.gravity.x
            let y = deviceMotion.gravity.y
            Task { @MainActor [weak self] in
                self?.update(gravityX: x, gravityY: y)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        filteredRoll = nil
        isWithinShowRange = false
        isAligned = false
        opacity = 0
    }

    func setReferenceOrientation(_ orientation: UIDeviceOrientation) {
        guard referenceOrientation != orientation else { return }
        referenceOrientation = orientation
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        filteredRoll = nil
        isWithinShowRange = false
        isAligned = false
        opacity = 0
    }

    private func update(gravityX x: Double, gravityY y: Double) {
        guard manager.isDeviceMotionActive else { return }

        // When the phone is nearly flat, the gravity vector has no useful
        // screen-plane direction, so a horizon line would be unstable.
        guard hypot(x, y) >= CameraLevelTuning.minimumGravityProjection else {
            filteredRoll = nil
            hide()
            return
        }

        let screenAngle = atan2(x, -y)
        let referenceAngle: Double
        switch referenceOrientation {
        case .landscapeLeft: referenceAngle = -.pi / 2
        case .landscapeRight: referenceAngle = .pi / 2
        case .portraitUpsideDown: referenceAngle = .pi
        default: referenceAngle = 0
        }

        let rawRoll = wrappedAngle(screenAngle - referenceAngle)
        let smoothedRoll: Double
        if let filteredRoll {
            smoothedRoll = wrappedAngle(
                filteredRoll + CameraLevelTuning.smoothingFraction
                    * wrappedAngle(rawRoll - filteredRoll)
            )
        } else {
            smoothedRoll = rawRoll
        }
        filteredRoll = smoothedRoll

        guard abs(smoothedRoll) <= CameraLevelTuning.showAngle else {
            hide()
            return
        }

        rollRadians = smoothedRoll
        if !isWithinShowRange {
            isWithinShowRange = true
            withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
        }

        let tolerance = isAligned
            ? CameraLevelTuning.levelExitTolerance
            : CameraLevelTuning.levelTolerance
        if abs(smoothedRoll) <= tolerance {
            if !isAligned {
                isAligned = true
                opacity = 1
                scheduleAlignedFade()
            }
        } else if isAligned {
            isAligned = false
            fadeWorkItem?.cancel()
            fadeWorkItem = nil
            withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
        }
    }

    private func hide() {
        guard isWithinShowRange else { return }
        isWithinShowRange = false
        isAligned = false
        fadeWorkItem?.cancel()
        fadeWorkItem = nil
        withAnimation(.easeOut(duration: 0.12)) { opacity = 0 }
    }

    private func scheduleAlignedFade() {
        fadeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isAligned else { return }
            self.fadeWorkItem = nil
            withAnimation(.easeOut(duration: CameraLevelTuning.fadeDuration)) {
                self.opacity = 0
            }
        }
        fadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CameraLevelTuning.alignedHoldDuration,
            execute: workItem
        )
    }

    private func wrappedAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}
