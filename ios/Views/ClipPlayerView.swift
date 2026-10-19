import SwiftUI
import AVFoundation
import AVKit
import Combine
import UIKit

struct ClipPagerView: View {
    let clips: [Clip]
    let initialClipID: UUID
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
    
    let onDelete: (Clip) -> Void
    let onTrimSaved: (Clip) -> Void
    let onRename: (Clip, String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedClipID: UUID
    @State private var pagedClips: [Clip]
    // Keep this state at the pager level so a horizontal swipe does not bring
    // the controls back after the viewer intentionally hid them.
    @State private var areControlsVisible = true
    @State private var isCurrentClipInteractionLocked = false
    @State private var dragOffset: CGSize = .zero
    @State private var isDraggingVertically = false
    @State private var verticalDismissGestureWasLocked = false
    // Deletion is intentionally staged: Photos first makes the current item
    // feel like it is leaving the canvas, then moves to its neighbor.
    @State private var deletingClipID: UUID?
    @State private var deletionScale: CGFloat = 1.0
    @State private var deletionOpacity: Double = 1.0
    
    init(
        clips: [Clip],
        initialClipID: UUID,
        fullVideoURL: URL? = nil,
        sessionDuration: TimeInterval,
        onDelete: @escaping (Clip) -> Void,
        onTrimSaved: @escaping (Clip) -> Void,
        onRename: @escaping (Clip, String) -> Void
    ) {
        self.clips = clips
        self.initialClipID = initialClipID
        self.fullVideoURL = fullVideoURL
        self.sessionDuration = sessionDuration
        self.onDelete = onDelete
        self.onTrimSaved = onTrimSaved
        self.onRename = onRename
        _selectedClipID = State(initialValue: initialClipID)
        _pagedClips = State(initialValue: clips)
    }
    
    private var backdropOpacity: Double {
        let maxDrag: CGFloat = 300.0
        let currentDrag = max(0, dragOffset.height)
        return Double(1.0 - min(currentDrag / maxDrag, 0.8))
    }
    
    private var scaleFactor: CGFloat {
        let maxDrag: CGFloat = 300.0
        let currentDrag = max(0, dragOffset.height)
        return max(0.85, 1.0 - (currentDrag / maxDrag) * 0.15)
    }

    /// There is only one audible clip player at a time. Stop it explicitly
    /// before this pager leaves the screen so an in-flight dismissal cannot
    /// leave audio playing from a view that is no longer visible.
    private func stopCurrentPlayback() {
        ActivePlayerStore.shared.currentPlayer?.pause()
        ActivePlayerStore.shared.currentPlayer = nil
    }

    var body: some View {
        ZStack {
            // Dark Backdrop
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            // The white canvas becomes visible around the minimized player,
            // rather than briefly exposing the black player backdrop.
            Color.white
                .opacity(deletingClipID == nil ? 0 : 1)
                .ignoresSafeArea()

            // Paging Horizontal View
            TabView(selection: $selectedClipID) {
                ForEach(pagedClips) { clip in
                    ClipPlayerContainer(
                        clip: clip,
                        isActive: clip.id == selectedClipID,
                        fullVideoURL: fullVideoURL,
                        sessionDuration: sessionDuration,
                        showUI: $areControlsVisible,
                        onInteractionLockChanged: { isLocked in
                            if clip.id == selectedClipID {
                                isCurrentClipInteractionLocked = isLocked
                            }
                        },
                        onDelete: { deleteAndAdvance(from: clip) },
                        onTrimSaved: onTrimSaved,
                        onRename: { newName in onRename(clip, newName) }
                    )
                    .tag(clip.id)
                    .scaleEffect(clip.id == deletingClipID ? deletionScale : 1)
                    .opacity(clip.id == deletingClipID ? deletionOpacity : 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: selectedClipID) { _, _ in
                isCurrentClipInteractionLocked = false
                verticalDismissGestureWasLocked = false
            }
            .offset(y: max(0, dragOffset.height))
            .scaleEffect(scaleFactor)
            .ignoresSafeArea()
            // simultaneousGesture lets TabView handle horizontal swipes while handling vertical drags
            .simultaneousGesture(
                DragGesture()
                    .onChanged { gesture in
                        guard !isCurrentClipInteractionLocked else {
                            verticalDismissGestureWasLocked = true
                            isDraggingVertically = false
                            dragOffset = .zero
                            return
                        }
                        let verticalDrag = gesture.translation.height
                        let horizontalDrag = abs(gesture.translation.width)
                        
                        // Check if movement is primarily downward vertical
                        if verticalDrag > 10 && verticalDrag > horizontalDrag * 1.2 {
                            isDraggingVertically = true
                            dragOffset = gesture.translation
                        } else if isDraggingVertically {
                            dragOffset = gesture.translation
                        }
                    }
                    .onEnded { gesture in
                        guard !isCurrentClipInteractionLocked, !verticalDismissGestureWasLocked else {
                            verticalDismissGestureWasLocked = false
                            isDraggingVertically = false
                            dragOffset = .zero
                            return
                        }
                        if isDraggingVertically {
                            if gesture.translation.height > 100 || gesture.predictedEndTranslation.height > 200 {
                                stopCurrentPlayback()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    dismiss()
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                        isDraggingVertically = false
                    }
            )
        }
        .statusBarHidden(true)
        .onDisappear {
            // Covers the back button, deletion, and any parent-driven modal
            // dismissal in addition to the explicit swipe-down path above.
            stopCurrentPlayback()
        }
    }

    private func deleteAndAdvance(from clip: Clip) {
        guard deletingClipID == nil else { return }
        guard let index = pagedClips.firstIndex(where: { $0.id == clip.id }) else { return }
        let nextClip = pagedClips.indices.contains(index + 1)
            ? pagedClips[index + 1]
            : (index > 0 ? pagedClips[index - 1] : nil)

        if let nextClip {
            deletingClipID = clip.id

            // Stage 1: briefly minimize the item against a white surface.
            // Keeping it partially visible makes the following page swipe
            // read as one continuous, Photos-style deletion action.
            withAnimation(.easeOut(duration: 0.18)) {
                deletionScale = 0.82
                deletionOpacity = 0.72
            }

            // Stage 2: retain the existing TabView paging behavior after the
            // outgoing item has clearly begun to leave the screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedClipID = nextClip.id
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
                guard let currentIndex = pagedClips.firstIndex(where: { $0.id == clip.id }) else { return }
                var removalTransaction = Transaction()
                removalTransaction.disablesAnimations = true
                withTransaction(removalTransaction) {
                    _ = pagedClips.remove(at: currentIndex)
                    deletingClipID = nil
                    deletionScale = 1.0
                    deletionOpacity = 1.0
                }
                DispatchQueue.main.async {
                    onDelete(clip)
                }
            }
        } else {
            stopCurrentPlayback()
            onDelete(clip)
            dismiss()
        }
    }
}

// MARK: - Container for Pager
private struct ClipPlayerContainer: View {
    let clip: Clip
    let isActive: Bool
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
    @Binding var showUI: Bool
    let onInteractionLockChanged: (Bool) -> Void
    let onDelete: () -> Void
    let onTrimSaved: (Clip) -> Void
    let onRename: (String) -> Void

    var body: some View {
        ClipPlayerView(
            clip: clip,
            isActive: isActive,
            fullVideoURL: fullVideoURL,
            sessionDuration: sessionDuration,
            showUI: $showUI,
            onInteractionLockChanged: onInteractionLockChanged,
            onDelete: onDelete,
            onTrimSaved: onTrimSaved,
            onRename: onRename
        )
        .id(clip.id)
    }
}

struct ClipPlayerView: View {
    let clip: Clip
    let isActive: Bool
    let videoURL: URL?
    let sessionDuration: TimeInterval
    @Binding var showUI: Bool
    var onInteractionLockChanged: (Bool) -> Void = { _ in }
    let onDelete: (() -> Void)?
    let onTrimSaved: ((Clip) -> Void)?
    var onRename: ((String) -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var playerVM: ClipPlayerViewModel
    
    @State private var showTrimEditor = false
    @State private var didSaveTrim = false
    @State private var showTitleEditor = false
    @State private var wasPlayingBeforeTrim = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameAlert = false
    @State private var editedTitle = ""
    @State private var showDeletionWarning = false
    @State private var editUnavailableMessage = ""
    @State private var wasPlayingBeforeBackground = false
    @State private var shouldResumeAfterTransientInactive = false
    @State private var controlsAutoHideTask: Task<Void, Never>?
    // The root player deliberately fills the entire display, so SwiftUI's
    // GeometryReader sees zero safe-area insets. These values come from the
    // UIKit player view instead and remain correct around the Dynamic Island,
    // Home indicator, and landscape camera housing.
    @State private var renderedVideoRect: CGRect = .zero
    @State private var playerSafeAreaInsets: UIEdgeInsets = .zero

    private var playerBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var chromeButtonBackground: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.06)
    }
    
    private var themeColor: Color {
        if playerVM.clip.isReel {
            return Color.blueMarble      //  Reels (#669BBC)
        } else if playerVM.clip.highlightIndex != nil {
            return Color.crimsonBlaze    //  Highlights (#C1121F)
        } else {
            return Color.cosmosBlue      //  Original Full Videos (#003049)
        }
    }
    
    private var deleteAlertTitle: String {
        if playerVM.clip.isReel {
            return "Delete Reel?"
        } else if playerVM.clip.highlightIndex == nil {
            return "Delete Original Video?"
        } else {
            return "Delete Highlight?"
        }
    }
    
    private var deleteAlertMessage: String {
        if playerVM.clip.isReel {
            return "Are you sure you want to permanently delete this reel?"
        } else if playerVM.clip.highlightIndex == nil {
            return "You will not be able to edit individual highlights after deleting the original recording video."
        } else {
            return "Are you sure you want to permanently delete this highlight?"
        }
    }
    
    private var canTrim: Bool {
        playerVM.clip.highlightIndex != nil && (videoURL != nil || playerVM.clip.fileURL != nil)
    }
    
    private var isEditable: Bool {
        if playerVM.clip.highlightIndex == nil {
            let path = (videoURL ?? playerVM.clip.fileURL)?.path ?? ""
            return !path.isEmpty && FileManager.default.fileExists(atPath: path)
        } else {
            let masterURL = videoURL ?? playerVM.clip.sourceVideoURL
            let path = masterURL?.path ?? ""
            return !path.isEmpty && FileManager.default.fileExists(atPath: path) && playerVM.clip.hasSourceVideoAvailable
        }
    }
    
    init(
        clip: Clip,
        isActive: Bool = true,
        fullVideoURL: URL? = nil,
        sessionDuration: TimeInterval,
        showUI: Binding<Bool> = .constant(true),
        onInteractionLockChanged: @escaping (Bool) -> Void = { _ in },
        onDelete: (() -> Void)? = nil,
        onTrimSaved: ((Clip) -> Void)? = nil,
        onRename: ((String) -> Void)? = nil
    ) {
        self.clip = clip
        self.isActive = isActive
        self.videoURL = fullVideoURL
        self.sessionDuration = sessionDuration
        self._showUI = showUI
        self.onInteractionLockChanged = onInteractionLockChanged
        self.onDelete = onDelete
        self.onTrimSaved = onTrimSaved
        self.onRename = onRename
        
        _playerVM = StateObject(wrappedValue: ClipPlayerViewModel(clip: clip, videoURL: fullVideoURL, autoPlay: isActive))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                playerBackground.ignoresSafeArea()
                
                videoArea
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                if showUI {
                    playerChrome(in: geometry)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .onAppear {
            playerVM.setActive(isActive)
            scheduleControlsAutoHideIfNeeded()
        }
        .onChange(of: isActive) { _, nowActive in
            playerVM.setActive(nowActive)
            if nowActive {
                scheduleControlsAutoHideIfNeeded()
            } else {
                controlsAutoHideTask?.cancel()
            }
        }
        .onChange(of: playerVM.isPlaying) { _, isPlaying in
            if isPlaying {
                scheduleControlsAutoHideIfNeeded()
            } else {
                controlsAutoHideTask?.cancel()
            }
        }
        .onChange(of: scenePhase, performActionOnPhaseChange)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DidFinishImportingVideo"))) { _ in
            playerVM.refreshPlayerAfterImport()
        }
        .onChange(of: clip) { _, newClip in
            playerVM.updateCurrentClip(newClip, newVideoURL: videoURL)
        }
        .onDisappear {
            controlsAutoHideTask?.cancel()
        }
        .modifier(ClipPlayerSheetsAndCoversModifier(
            videoURL: videoURL,
            sessionDuration: sessionDuration,
            onTrimSaved: onTrimSaved,
            onDelete: onDelete,
            showTrimEditor: $showTrimEditor,
            showTitleEditor: $showTitleEditor,
            wasPlayingBeforeTrim: $wasPlayingBeforeTrim,
            didSaveTrim: $didSaveTrim,
            scenePhase: scenePhase,
            playerVM: playerVM
        ))
        .modifier(ClipPlayerAlertsModifier(
            editedTitle: $editedTitle,
            showRenameAlert: $showRenameAlert,
            showDeleteConfirmation: $showDeleteConfirmation,
            showDeletionWarning: $showDeletionWarning,
            editUnavailableMessage: editUnavailableMessage,
            deleteAlertTitle: deleteAlertTitle,
            deleteAlertMessage: deleteAlertMessage,
            playerVM: playerVM,
            onRename: onRename,
            onTrimSaved: onTrimSaved,
            onDelete: onDelete
        ))
    }
    
    private var videoArea: some View {
        ZStack {
            if let player = playerVM.player {
                // Keep the AVPlayerLayer in a direct UIKit view. Previously it
                // lived inside a nested UIHostingController for zoom support;
                // that layer could remain detached after closing the editor,
                // leaving a working audio track over a black video surface.
                ZoomablePlayerView(
                    player: player,
                    isActive: isActive,
                    backgroundColor: colorScheme == .dark ? .black : .white,
                    onSingleTap: {
                        toggleControlsVisibility()
                    },
                    onInteractionLockChanged: onInteractionLockChanged,
                    onLayoutChanged: { videoRect, safeAreaInsets in
                        guard videoRect != renderedVideoRect || safeAreaInsets != playerSafeAreaInsets else { return }
                        renderedVideoRect = videoRect
                        playerSafeAreaInsets = safeAreaInsets
                    }
                )
                .id(playerVM.playerGeneration)
            } else {
                Rectangle()
                    .fill(playerBackground)
                    .ignoresSafeArea()
                    .overlay(
                        VStack(spacing: 12) {
                            if playerVM.isProcessing {
                                ProgressView().tint(.white)
                                Text("Processing clip...")
                                    .font(.subheadline).foregroundColor(Color(white: 0.6))
                            } else {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 36)).foregroundColor(Color(white: 0.4))
                                Text("Clip not available")
                                    .font(.subheadline).foregroundColor(Color(white: 0.4))
                            }
                        }
                    )
            }

            if playerVM.showPlayPauseIndicator {
                Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.8))
                    .transition(.opacity)
                    .id(playerVM.isPlaying ? "pause_indicator" : "play_indicator")
            } else if playerVM.showAudioIndicator {
                Image(systemName: playerVM.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.8))
                    .transition(.opacity)
                    .id(playerVM.isMuted ? "muted_indicator" : "unmuted_indicator")
            }
        }
        .ignoresSafeArea()
    }
    
    private func playerChrome(in geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let videoRect = renderedVideoRect.isEmpty
            ? CGRect(origin: .zero, size: geometry.size)
            : renderedVideoRect
        let videoSideInset = isLandscape ? 48.0 : 24.0
        let leftVideoInset = videoRect.minX + videoSideInset
        let rightVideoInset = geometry.size.width - videoRect.maxX + videoSideInset
        // Keep every playback control inside the visible video width. In
        // landscape this intentionally moves the controls farther inward.
        let playbackSidePadding = max(
            leftVideoInset,
            rightVideoInset,
            max(playerSafeAreaInsets.left, playerSafeAreaInsets.right) + 16
        )
        // The title bar is allowed to use a little more width than the
        // playback controls, especially for long multi-line clip names.
        let topBarSidePadding = max(
            isLandscape ? 28 : 24,
            max(playerSafeAreaInsets.left, playerSafeAreaInsets.right) + 16
        )
        let topPadding = max(playerSafeAreaInsets.top, isLandscape ? 16 : 12)
        let bottomPadding = max(playerSafeAreaInsets.bottom, isLandscape ? 8 : 12)

        return VStack(spacing: 0) {
            topBar(horizontalPadding: topBarSidePadding)
                .padding(.top, topPadding)
                .background(playerBackground)

            Spacer(minLength: 0)

            bottomOverlay(
                horizontalPadding: playbackSidePadding,
                bottomPadding: bottomPadding,
                isLandscape: isLandscape
            )
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private func topBar(horizontalPadding: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: {
                playerVM.stop()
                dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 34, height: 34)
                    // CHANGE: Use dark translucent background instead of white
                    .background(chromeButtonBackground)
                    .clipShape(Circle())
            }
            
            Button(action: {
                editedTitle = playerVM.clip.displayName
                showRenameAlert = true
            }) {
                HStack(spacing: 6) {
                    Text(playerVM.clip.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(themeColor)
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            
            Button(action: {
                handleEditTap()
            }) {
                Text("Edit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isEditable ? themeColor : .gray)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    // CHANGE: Dark translucent background
                    .background(chromeButtonBackground)
                    .clipShape(Capsule())
            }
            .frame(width: 54)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
    }
    
    private func bottomOverlay(
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat,
        isLandscape: Bool
    ) -> some View {
        VStack(spacing: isLandscape ? 10 : 14) {
            playbackControls(horizontalPadding: horizontalPadding)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            scrubber(horizontalPadding: horizontalPadding)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            actionBar(horizontalPadding: horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, bottomPadding)
                .background(playerBackground)
        }
        .padding(.top, isLandscape ? 8 : 16)
    }
    
    private func playbackControls(horizontalPadding: CGFloat) -> some View {
        HStack {
            Button(action: { playerVM.togglePlayback() }) {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundColor(Color.white)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Button(action: { playerVM.toggleMute() }) {
                Image(systemName: playerVM.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
    }
    
    private func scrubber(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 6) {
            VideoScrubberTrack(
                progress: Binding(
                    get: { playerVM.progress },
                    set: { playerVM.progress = $0 }
                ),
                isScrubbing: Binding(
                    get: { playerVM.isScrubbing },
                    set: { playerVM.isScrubbing = $0 }
                ),
                onScrubBegan: {
                    onInteractionLockChanged(true)
                    playerVM.beginScrubbing()
                },
                onScrubChanged: { playerVM.previewScrub(at: $0) },
                onScrubEnded: {
                    playerVM.seekToProgress()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        onInteractionLockChanged(false)
                    }
                }
            )
            .padding(.horizontal, horizontalPadding)
            
            HStack {
                Text(playerVM.currentTimeLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Color(white: 0.75))
                Spacer()
                Text(playerVM.durationLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Color(white: 0.75))
            }
            .padding(.horizontal, horizontalPadding)
        }
    }
    
    private func actionBar(horizontalPadding: CGFloat) -> some View {
        HStack {
            Button {
                if let url = playerVM.clip.fileURL {
                    let clipDate = playerVM.clip.createdAt
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    
                    let exportFilename = ClipFilenameHelper.generateFilename(
                        title: playerVM.clip.displayName,
                        date: clipDate,
                        fileExtension: ext
                    )
                    
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(exportFilename)
                    try? FileManager.default.removeItem(at: tempURL)
                    try? FileManager.default.copyItem(at: url, to: tempURL)
                    
                    presentShareSheet(for: tempURL)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 36, height: 36)
                    .background(chromeButtonBackground)
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Button {
                playerVM.toggleFavorite()
                onTrimSaved?(playerVM.clip)
            } label: {
                Image(systemName: playerVM.clip.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(playerVM.clip.isFavorite ? Color.crimsonBlaze : themeColor)
                    .frame(width: 36, height: 36)
                    .background(chromeButtonBackground)
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Menu {
                ForEach(playerVM.playbackRates, id: \.self) { rate in
                    Button {
                        playerVM.setPlaybackRate(rate)
                    } label: {
                        if playerVM.playbackRate == rate {
                            Label(playerVM.playbackSpeedLabel(for: rate), systemImage: "checkmark")
                        } else {
                            Text(playerVM.playbackSpeedLabel(for: rate))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle")
                    Text(playerVM.playbackSpeedLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .foregroundColor(themeColor)
                .background(chromeButtonBackground)
                .clipShape(Capsule())
            } primaryAction: {
                playerVM.toggleSpeed()
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Playback speed, \(playerVM.playbackSpeedLabel)")
            .accessibilityHint("Tap to cycle speeds, or press and hold to choose a speed")
            
            Spacer()
            
            Button(action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 36, height: 36)
                    .background(chromeButtonBackground)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, horizontalPadding)
    }
    
    // MARK: - Direct UIKit Share Sheet Presentation
    private func presentShareSheet(for url: URL) {
        playerVM.pause()
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        
        topVC.present(activityVC, animated: true)
    }
    
    private func handleEditTap() {
        if playerVM.clip.isReel {
            editUnavailableMessage = "Reels are unable to be edited."
            showDeletionWarning = true
        } else if isEditable {
            wasPlayingBeforeTrim = playerVM.isPlaying
            playerVM.pause()
            showTrimEditor = true
        } else {
            editUnavailableMessage = "You cannot edit this highlight since the full recording was deleted."
            showDeletionWarning = true
        }
    }

    private func toggleControlsVisibility() {
        controlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showUI.toggle()
        }
        scheduleControlsAutoHideIfNeeded()
    }

    private func scheduleControlsAutoHideIfNeeded() {
        controlsAutoHideTask?.cancel()
        guard isActive, showUI, playerVM.isPlaying else { return }

        controlsAutoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, isActive, playerVM.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                showUI = false
            }
        }
    }
    
    private func performActionOnPhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        // Interface rotation briefly transitions the scene through .inactive.
        // AVPlayer may pause during that transition on some devices, even
        // though we never asked it to. Preserve whether the user was watching
        // and explicitly resume once the scene is active again. A video that
        // was manually paused remains paused.
        switch newPhase {
        case .inactive:
            shouldResumeAfterTransientInactive = isActive && playerVM.isPlaying

        case .background:
            wasPlayingBeforeBackground = playerVM.isPlaying
            shouldResumeAfterTransientInactive = false
            playerVM.pause()

        case .active:
            let shouldResume = isActive && (wasPlayingBeforeBackground || shouldResumeAfterTransientInactive)
            wasPlayingBeforeBackground = false
            shouldResumeAfterTransientInactive = false
            if shouldResume {
                DispatchQueue.main.async {
                    self.playerVM.playWhenReady()
                }
            }

        @unknown default:
            break
        }
    }
}

// MARK: - Isolated Sheets and Covers ViewModifier
private struct ClipPlayerSheetsAndCoversModifier: ViewModifier {
    let videoURL: URL?
    let sessionDuration: TimeInterval
    let onTrimSaved: ((Clip) -> Void)?
    let onDelete: (() -> Void)?
    
    @Binding var showTrimEditor: Bool
    @Binding var showTitleEditor: Bool
    @Binding var wasPlayingBeforeTrim: Bool
    @Binding var didSaveTrim: Bool
    
    let scenePhase: ScenePhase
    @ObservedObject var playerVM: ClipPlayerViewModel
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showTrimEditor, onDismiss: {
                let savedTrim = didSaveTrim
                didSaveTrim = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if scenePhase == .active {
                        if savedTrim {
                            // Build a new AVPlayer only after the editor is fully
                            // gone. This gives the edited asset a fresh video
                            // output, matching the reliable reopen behavior
                            // without leaving the clip player.
                            playerVM.reloadEditedClipForPlayback()
                        } else if wasPlayingBeforeTrim {
                            playerVM.playWhenReady()
                        }
                    }
                    wasPlayingBeforeTrim = false
                }
            }) {
                if let url = videoURL ?? playerVM.clip.sourceVideoURL ?? playerVM.clip.fileURL {
                    HighlightTrimView(
                        clip: playerVM.clip,
                        fullVideoURL: url,
                        sessionDuration: sessionDuration,
                        initialPreviewTime: playerVM.clip.highlightIndex == nil ? playerVM.currentPlaybackTime : nil,
                        startsPaused: playerVM.clip.highlightIndex == nil
                    ) { updatedClip in
                        // Save the new URL now, then rebuild the player after
                        // the editor has actually dismissed.
                        playerVM.updateCurrentClip(updatedClip, newVideoURL: videoURL, reloadPlayer: false)
                        didSaveTrim = true
                        onTrimSaved?(updatedClip)
                    }
                } else {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        Text("Video not available").foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showTitleEditor) {
                ClipTitleEditView(clip: playerVM.clip, onDelete: onDelete) { updatedClip in
                    onTrimSaved?(updatedClip)
                    playerVM.updateCurrentClip(updatedClip, newVideoURL: videoURL)
                }
            }
    }
}

// MARK: - Isolated Alerts ViewModifier
private struct ClipPlayerAlertsModifier: ViewModifier {
    @Binding var editedTitle: String
    @Binding var showRenameAlert: Bool
    @Binding var showDeleteConfirmation: Bool
    @Binding var showDeletionWarning: Bool
    let editUnavailableMessage: String
    
    let deleteAlertTitle: String
    let deleteAlertMessage: String
    
    @ObservedObject var playerVM: ClipPlayerViewModel
    
    var onRename: ((String) -> Void)?
    let onTrimSaved: ((Clip) -> Void)?
    let onDelete: (() -> Void)?

    private var deleteBorderColor: Color {
        if playerVM.clip.isReel {
            return .blueMarble
        } else if playerVM.clip.highlightIndex != nil {
            return .crimsonBlaze
        } else {
            return .cosmosBlue
        }
    }
    
    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $showRenameAlert) {
            RenameClipSheet(
                editedTitle: $editedTitle,
                onSave: { newTitle in
                    playerVM.clip.customName = newTitle
                    playerVM.clip.customTitle = newTitle
                    onRename?(newTitle)
                    onTrimSaved?(playerVM.clip)
                },
                onDismiss: {
                    showRenameAlert = false
                }
            )
            .presentationDetents([.height(290)])
            .presentationDragIndicator(.visible)
        }
        .clipItDeleteConfirmation(
            isPresented: $showDeleteConfirmation,
            title: deleteAlertTitle,
            message: deleteAlertMessage,
            borderColor: deleteBorderColor,
            onDelete: {
                // Pause immediately, but keep the AVPlayer/view alive until
                // the pager has moved away so its unavailable placeholder is
                // never exposed between clips.
                playerVM.pause()
                onDelete?()
            }
        )
        .alert("Edit Unavailable", isPresented: $showDeletionWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(editUnavailableMessage)
        }
    }
}

struct CustomVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    
    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    
    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // Always reassign, even if `player` is the same instance as before.
        // AVPlayerLayer can silently stop rendering frames (audio keeps
        // playing) after its host view is scrolled off/on-screen inside a
        // TabView(.page) — reassigning nudges it to reconnect the video
        // output. Skipping this when the reference "hasn't changed" is what
        // causes the black-screen-with-audio bug when paging back to a
        // previously-visited clip.
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = .resizeAspect
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Direct zoomable player surface

/// Owns the AVPlayerLayer and its zoom gestures in one UIKit hierarchy. This
/// avoids putting an AVPlayerLayer inside another UIHostingController, which
/// can leave the video output black after a full-screen cover is dismissed.
private struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer
    let isActive: Bool
    let backgroundColor: UIColor
    let onSingleTap: () -> Void
    let onInteractionLockChanged: (Bool) -> Void
    let onLayoutChanged: (CGRect, UIEdgeInsets) -> Void

    init(
        player: AVPlayer,
        isActive: Bool,
        backgroundColor: UIColor,
        onSingleTap: @escaping () -> Void,
        onInteractionLockChanged: @escaping (Bool) -> Void,
        onLayoutChanged: @escaping (CGRect, UIEdgeInsets) -> Void
    ) {
        self.player = player
        self.isActive = isActive
        self.backgroundColor = backgroundColor
        self.onSingleTap = onSingleTap
        self.onInteractionLockChanged = onInteractionLockChanged
        self.onLayoutChanged = onLayoutChanged
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isActive: isActive,
            onSingleTap: onSingleTap,
            onInteractionLockChanged: onInteractionLockChanged
        )
    }

    func makeUIView(context: Context) -> ZoomablePlayerContainerView {
        let container = ZoomablePlayerContainerView()
        container.setBackgroundColor(backgroundColor)
        container.onLayoutChanged = onLayoutChanged
        container.attach(player: player)

        context.coordinator.install(container: container)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = true
        container.addGestureRecognizer(pinch)
        context.coordinator.pinchGesture = pinch

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.isEnabled = false
        container.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        container.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        container.addGestureRecognizer(singleTap)

        return container
    }

    func updateUIView(_ uiView: ZoomablePlayerContainerView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onInteractionLockChanged = onInteractionLockChanged
        uiView.setBackgroundColor(backgroundColor)
        uiView.onLayoutChanged = onLayoutChanged
        uiView.attach(player: player)
        context.coordinator.setActive(isActive)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var containerView: ZoomablePlayerContainerView?
        weak var pinchGesture: UIPinchGestureRecognizer?
        weak var panGesture: UIPanGestureRecognizer?

        private(set) var isActive: Bool
        var onSingleTap: () -> Void
        var onInteractionLockChanged: (Bool) -> Void

        private var currentScale: CGFloat = 1
        private var currentTranslation: CGPoint = .zero
        private let maxScale: CGFloat = 5

        private var pinchStartScale: CGFloat = 1
        private var pinchStartTranslation: CGPoint = .zero
        private var pinchStartLocation: CGPoint = .zero
        private var isPinching = false
        // A pinch ends as soon as either finger lifts. Keep the current image
        // position and make the remaining finger begin panning from zero
        // movement, rather than treating its absolute screen position as a
        // new translation.
        private var awaitsPanHandoffBaseline = false

        init(
            isActive: Bool,
            onSingleTap: @escaping () -> Void,
            onInteractionLockChanged: @escaping (Bool) -> Void
        ) {
            self.isActive = isActive
            self.onSingleTap = onSingleTap
            self.onInteractionLockChanged = onInteractionLockChanged
        }

        private var isZoomed: Bool {
            currentScale > 1.01
        }

        func install(container: ZoomablePlayerContainerView) {
            containerView = container
            if isActive {
                container.setPagingLocked(false)
                onInteractionLockChanged(false)
            }
        }

        func setActive(_ active: Bool) {
            guard active != isActive else {
                if active {
                    updateInteractionLock()
                }
                return
            }

            let wasActive = isActive
            isActive = active
            if wasActive && !active {
                resetZoom(animated: false)
            } else if active {
                updateInteractionLock()
            }
        }

        private func updateInteractionLock() {
            guard isActive else { return }
            let locked = isPinching || isZoomed
            containerView?.setPagingLocked(locked)
            onInteractionLockChanged(locked)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard isActive, let containerView else { return }

            if isZoomed {
                resetZoom(animated: true)
            } else {
                let targetScale: CGFloat = 3.5
                let tap = pointRelativeToCenter(gesture.location(in: containerView))
                currentScale = targetScale
                currentTranslation = CGPoint(
                    x: tap.x * (1 - targetScale),
                    y: tap.y * (1 - targetScale)
                )
                clampTranslation()
                panGesture?.isEnabled = true
                updateInteractionLock()
                applyTransform(animated: true)
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard isActive, let containerView else { return }

            switch gesture.state {
            case .began:
                isPinching = true
                pinchStartScale = currentScale
                pinchStartTranslation = currentTranslation
                pinchStartLocation = pointRelativeToCenter(gesture.location(in: containerView))

                // This happens as soon as the second touch makes the pinch
                // begin. It cancels any pager pan that started on finger one
                // and keeps paging disabled until both touches finish.
                updateInteractionLock()

            case .changed:
                // UIKit can deliver a final `.changed` after one touch has
                // already lifted. At that point the reported pinch center
                // jumps to the remaining finger, which used to move the video
                // unexpectedly. Only a true two-finger update may alter zoom.
                guard gesture.numberOfTouches >= 2 else { return }

                let rawScale = pinchStartScale * gesture.scale
                currentScale = rubberBandedScale(rawScale)

                let currentLocation = pointRelativeToCenter(gesture.location(in: containerView))
                let contentPoint = CGPoint(
                    x: (pinchStartLocation.x - pinchStartTranslation.x) / pinchStartScale,
                    y: (pinchStartLocation.y - pinchStartTranslation.y) / pinchStartScale
                )
                currentTranslation = CGPoint(
                    x: currentLocation.x - contentPoint.x * currentScale,
                    y: currentLocation.y - contentPoint.y * currentScale
                )
                clampTranslation()
                applyTransform(animated: false)

            case .ended, .cancelled:
                isPinching = false
                if currentScale <= 1.05 {
                    resetZoom(animated: true)
                } else {
                    currentScale = min(currentScale, maxScale)
                    clampTranslation()
                    awaitsPanHandoffBaseline = gesture.numberOfTouches == 1
                    panGesture?.isEnabled = true
                    updateInteractionLock()
                    // Preserve the exact final pinch position. Animating here
                    // makes the subsequent one-finger handoff feel like a
                    // snap instead of continuous movement.
                    applyTransform(animated: false)
                }
            default:
                break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard isActive, let containerView, isZoomed, !isPinching else { return }

            switch gesture.state {
            case .began:
                // A pan recognizer can begin while one finger remains down
                // from a finished pinch. Clear its accumulated translation so
                // the video stays where the pinch left it.
                gesture.setTranslation(.zero, in: containerView)
                awaitsPanHandoffBaseline = false

            case .changed:
                if awaitsPanHandoffBaseline {
                    gesture.setTranslation(.zero, in: containerView)
                    awaitsPanHandoffBaseline = false
                    return
                }
                let translation = gesture.translation(in: containerView)
                currentTranslation = CGPoint(
                    x: currentTranslation.x + translation.x,
                    y: currentTranslation.y + translation.y
                )
                gesture.setTranslation(.zero, in: containerView)
                clampTranslation()
                applyTransform(animated: false)
            case .ended, .cancelled:
                clampTranslation()
                applyTransform(animated: true)
            default:
                break
            }
        }

        private func pointRelativeToCenter(_ point: CGPoint) -> CGPoint {
            guard let containerView else { return .zero }
            return CGPoint(
                x: point.x - containerView.bounds.midX,
                y: point.y - containerView.bounds.midY
            )
        }

        private func rubberBandedScale(_ rawScale: CGFloat) -> CGFloat {
            if rawScale < 1 {
                return max(0.82, 1 - (1 - rawScale) * 0.32)
            }
            if rawScale > maxScale {
                return min(maxScale + 0.35, maxScale + (rawScale - maxScale) * 0.18)
            }
            return rawScale
        }

        private func translationLimits() -> CGPoint {
            guard let containerView else { return .zero }
            let videoRect = containerView.videoView.playerLayer.videoRect
            let baseWidth = videoRect.width > 0 ? videoRect.width : containerView.bounds.width
            let baseHeight = videoRect.height > 0 ? videoRect.height : containerView.bounds.height
            return CGPoint(
                x: max(0, (baseWidth * currentScale - containerView.bounds.width) / 2),
                y: max(0, (baseHeight * currentScale - containerView.bounds.height) / 2)
            )
        }

        private func clampTranslation() {
            let limits = translationLimits()
            currentTranslation.x = min(max(currentTranslation.x, -limits.x), limits.x)
            currentTranslation.y = min(max(currentTranslation.y, -limits.y), limits.y)
        }

        private func applyTransform(animated: Bool) {
            guard let videoView = containerView?.videoView else { return }
            let transform = CGAffineTransform(
                a: currentScale,
                b: 0,
                c: 0,
                d: currentScale,
                tx: currentTranslation.x,
                ty: currentTranslation.y
            )

            if animated {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0.2,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    videoView.transform = transform
                }
            } else {
                videoView.layer.removeAllAnimations()
                videoView.transform = transform
            }
        }

        private func resetZoom(animated: Bool) {
            isPinching = false
            awaitsPanHandoffBaseline = false
            currentScale = 1
            currentTranslation = .zero
            panGesture?.isEnabled = false
            if isActive {
                updateInteractionLock()
            } else {
                containerView?.setPagingLocked(false)
                onInteractionLockChanged(false)
            }
            applyTransform(animated: animated)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === panGesture {
                return isActive && isZoomed && !isPinching
            }
            return isActive
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // A pinch must be allowed to recognize even if the pager's pan saw
            // finger one first. The pinch's .began handler immediately cancels
            // and locks that pager recognizer for the rest of the two-finger
            // interaction.
            if gestureRecognizer === pinchGesture || otherGestureRecognizer === pinchGesture {
                return true
            }
            return false
        }
    }
}

private final class ZoomablePlayerContainerView: UIView {
    let videoView = PlayerContainerView()
    var onLayoutChanged: ((CGRect, UIEdgeInsets) -> Void)?
    private weak var pagingPanGesture: UIPanGestureRecognizer?
    private var isPagingLocked = false
    private var hasExplicitPagingState = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        videoView.backgroundColor = .black
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // TabView's page style is backed by a UIScrollView. It is attached
        // after this view during presentation, so resolve it on the next run
        // loop and apply any zoom lock already in effect.
        DispatchQueue.main.async { [weak self] in
            self?.applyPagingLock()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportLayout()
    }

    func setBackgroundColor(_ color: UIColor) {
        backgroundColor = color
        videoView.backgroundColor = color
        videoView.playerLayer.backgroundColor = color.cgColor
    }

    func attach(player: AVPlayer) {
        guard videoView.playerLayer.player !== player else { return }
        videoView.playerLayer.player = nil
        videoView.playerLayer.player = player
        DispatchQueue.main.async { [weak self] in
            self?.reportLayout()
        }
    }

    private func reportLayout() {
        // AVPlayerLayer computes videoRect during its layout pass. Reporting
        // on the following main-loop turn makes this reliable after rotation
        // and after a new player item is attached.
        let rect = videoView.playerLayer.videoRect
        let reportedRect = rect.isEmpty ? bounds : rect
        onLayoutChanged?(reportedRect, safeAreaInsets)
    }

    func setPagingLocked(_ locked: Bool) {
        isPagingLocked = locked
        hasExplicitPagingState = true
        applyPagingLock()
    }

    private func applyPagingLock() {
        if pagingPanGesture == nil {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    pagingPanGesture = scrollView.panGestureRecognizer
                    break
                }
                ancestor = view.superview
            }
        }

        guard let pagingPanGesture else { return }

        // This is the root arbitration rule: the pager only accepts one touch.
        // When finger two arrives, UIKit cancels a pager pan that may have
        // already begun on finger one, allowing the pinch to own both touches.
        pagingPanGesture.maximumNumberOfTouches = 1

        guard hasExplicitPagingState else { return }
        if isPagingLocked {
            if pagingPanGesture.isEnabled {
                pagingPanGesture.isEnabled = false
            }
        } else if !pagingPanGesture.isEnabled {
            pagingPanGesture.isEnabled = true
        }
    }
}

final class ActivePlayerStore {
    static let shared = ActivePlayerStore()
    weak var currentPlayer: AVPlayer?
}

@MainActor
final class ClipPlayerViewModel: ObservableObject {
    @Published var clip: Clip
    @Published var videoURL: URL?

    @Published var player: AVPlayer?
    @Published private(set) var playerGeneration = UUID()
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    @Published var currentTimeLabel: String = "0:00"
    @Published var durationLabel: String = "0:00"
    @Published var showPlayPauseIndicator: Bool = false
    @Published var showAudioIndicator: Bool = false
    @Published var isScrubbing: Bool = false
    @Published var playbackRate: Float = 1.0

    let playbackRates: [Float] = [1.0, 0.5, 0.25, 1.5, 2.0]

    var playbackSpeedLabel: String {
        playbackSpeedLabel(for: playbackRate)
    }

    func playbackSpeedLabel(for rate: Float) -> String {
        switch rate {
        case 0.5: return "0.5x Slo-Mo"
        case 0.25: return "0.25x Super Slo-Mo"
        case 1.5: return "1.5x"
        case 2.0: return "2.0x"
        default: return "1.0x"
        }
    }

    private var timeObserver: Any?
    private var processingTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var audioFlashTask: Task<Void, Never>?
    private var pendingAutoplayTask: Task<Void, Never>?
    private var wasPlayingBeforeScrubbing = false

    // Tracks whether this page is the one currently selected in the pager.
    // Used to guard async seek/play completions so a stale callback from a
    // page you've since swiped away from can't resurrect playback or steal
    // focus from the page you're actually looking at.
    private var isActive: Bool = false
    private var pendingDeactivationTask: Task<Void, Never>?

    init(clip: Clip, videoURL: URL? = nil, autoPlay: Bool = true) {
        self.clip = clip
        self.videoURL = videoURL
        self.isActive = autoPlay
        setupPlayer(autoPlay: autoPlay)
        
        let initialURL = clip.fileURL ?? videoURL
        if initialURL == nil || !FileManager.default.fileExists(atPath: initialURL?.path ?? "") {
            self.isProcessing = true
            
            processingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let currentURL = self.clip.fileURL ?? self.videoURL
                    if let updatedURL = currentURL, FileManager.default.fileExists(atPath: updatedURL.path) {
                        self.setupPlayer(autoPlay: autoPlay)
                        break
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
        }
    }

    func setupPlayer(autoPlay: Bool = true) {
        stop()

        guard let url = clip.fileURL ?? videoURL, FileManager.default.fileExists(atPath: url.path) else {
            isProcessing = true
            return
        }

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.isMuted = isMuted

        self.isProcessing = false
        self.player = avPlayer
        self.playerGeneration = UUID()
        
        if autoPlay {
            playWhenReady()
        } else {
            avPlayer.pause()
            isPlaying = false
        }

        Task { [weak self] in
            if let duration = try? await item.asset.load(.duration), duration.isNumeric {
                self?.durationLabel = self?.formatTime(duration.seconds) ?? "0:00"
            }
        }

        notificationTask = Task { [weak self, item] in
            let sequence = NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime, object: item)
            for await _ in sequence {
                guard let self else { break }
                await self.player?.seek(to: .zero)
                self.player?.pause()
                self.isPlaying = false
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        let playerForObserver = avPlayer

        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak playerForObserver] time in
            Task { @MainActor [weak self, weak playerForObserver] in
                guard let self, let playerForObserver, !self.isScrubbing else { return }
                let durationSeconds = playerForObserver.currentItem?.duration.seconds ?? 1
                guard durationSeconds > 0, durationSeconds.isFinite else { return }
                
                self.progress = time.seconds / durationSeconds
                self.currentTimeLabel = self.formatTime(time.seconds)
            }
        }
    }
    
    /// Single entry point the view should call on `.onAppear` / `.onChange(of: isActive)`.
    /// Keeping this as the only way in/out of active state means every async
    /// completion below can check `self.isActive` at the moment it actually
    /// fires, instead of trusting that nothing changed while it was in flight.
    func setActive(_ active: Bool) {
        if active {
            if let pendingDeactivationTask {
                pendingDeactivationTask.cancel()
                self.pendingDeactivationTask = nil
                isActive = true
                return
            }
            guard !isActive else { return }
            isActive = true
            rewindAndPlay()
        } else {
            guard isActive else { return }
            isActive = false
            pendingDeactivationTask?.cancel()
            pendingDeactivationTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, !self.isActive else { return }
                self.pendingDeactivationTask = nil
                self.pauseAndResetToBeginning()
            }
        }
    }

    func pauseAndResetToBeginning() {
        player?.pause()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if ActivePlayerStore.shared.currentPlayer === player {
            ActivePlayerStore.shared.currentPlayer = nil
        }
        isPlaying = false
        progress = 0
        currentTimeLabel = "0:00"
    }

    func rewindAndPlay() {
        if player == nil || player?.currentItem == nil {
            setupPlayer(autoPlay: true)
            return
        }
        // Capture the player we're seeking so a completion that fires after
        // setupPlayer() swaps in a different instance can't act on it.
        let targetPlayer = player
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.player === targetPlayer else { return }
                self.playWhenReady()
            }
        }
    }
    
    func play() {
        guard let player else { return }

        if let current = ActivePlayerStore.shared.currentPlayer, current !== player {
            current.pause()
        }
        player.play()
        player.rate = playbackRate
        ActivePlayerStore.shared.currentPlayer = player
        isPlaying = true
    }

    /// Start once AVFoundation has made the item's media available. This waits
    /// on the item itself rather than a view-layer callback, which may not fire
    /// after a full-screen editor is dismissed.
    func playWhenReady() {
        guard let targetPlayer = player,
              let item = targetPlayer.currentItem else { return }

        isActive = true
        pendingAutoplayTask?.cancel()

        if item.status == .readyToPlay {
            play()
            return
        }

        pendingAutoplayTask = Task { [weak self] in
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }

                if item.status == .readyToPlay {
                    guard let self, self.player === targetPlayer else { return }
                    self.play()
                    return
                }

                if item.status == .failed {
                    return
                }

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The editor changes the asset backing this highlight. Recreate both the
    /// AVPlayer and its SwiftUI-hosted AVPlayerLayer after dismissal so the
    /// replacement video is shown immediately instead of retaining a stale,
    /// black output surface.
    func reloadEditedClipForPlayback() {
        setupPlayer(autoPlay: true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    var currentPlaybackTime: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    func stop() {
        pendingDeactivationTask?.cancel()
        pendingDeactivationTask = nil
        isActive = false
        processingTask?.cancel()
        processingTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        flashTask?.cancel()
        flashTask = nil
        pendingAutoplayTask?.cancel()
        pendingAutoplayTask = nil
        
        if ActivePlayerStore.shared.currentPlayer === player {
            ActivePlayerStore.shared.currentPlayer = nil
        }

        player?.pause()
        isPlaying = false

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }

        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
        flashIndicator()
    }

    func toggleMute() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
        flashAudioIndicator()
    }

    func toggleSpeed() {
        let currentIndex = playbackRates.firstIndex(of: playbackRate) ?? 0
        setPlaybackRate(playbackRates[(currentIndex + 1) % playbackRates.count])
    }

    func setPlaybackRate(_ rate: Float) {
        guard playbackRates.contains(rate) else { return }
        playbackRate = rate

        guard let player = player else { return }
        
        if isPlaying {
            player.rate = playbackRate
        } else {
            player.pause()
        }
    }
    
    // Favorite clips
    func toggleFavorite() {
        clip.isFavorite.toggle()
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        let target = max(0, current + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    /// Apple Photos-style scrubbing: pause normal playback while a finger is
    /// down, but continuously seek to the finger's current position so each
    /// frame is visible before the user releases.
    func beginScrubbing() {
        guard !isScrubbing else { return }
        wasPlayingBeforeScrubbing = isPlaying
        player?.pause()
        isPlaying = false
        isScrubbing = true
    }

    func previewScrub(at normalizedProgress: Double) {
        guard let player,
              let total = player.currentItem?.duration.seconds,
              total > 0, total.isFinite else { return }

        let clampedProgress = min(max(normalizedProgress, 0), 1)
        let targetSeconds = clampedProgress * total
        progress = clampedProgress
        currentTimeLabel = formatTime(targetSeconds)

        // Exact seeks make the current frame follow the scrubber rather than
        // waiting until the drag ends. AVFoundation supersedes stale pending
        // seeks as the finger moves, so this naturally favors the latest spot.
        player.seek(
            to: CMTime(seconds: targetSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func seekToProgress() {
        guard let player,
              let total = player.currentItem?.duration.seconds,
              total > 0, total.isFinite else { return }
        
        let target = CMTime(seconds: progress * total, preferredTimescale: 600)
        let targetRate = self.playbackRate
        let shouldResumePlay = wasPlayingBeforeScrubbing
        
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isScrubbing = false
                self.wasPlayingBeforeScrubbing = false
                if shouldResumePlay {
                    self.player?.play()
                    self.player?.rate = targetRate
                    self.isPlaying = true
                } else {
                    self.player?.pause()
                    self.isPlaying = false
                }
            }
        }
    }

    private func flashIndicator() {
        flashTask?.cancel()
        showPlayPauseIndicator = true
        
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            self?.showPlayPauseIndicator = false
        }
    }

    private func flashAudioIndicator() {
        audioFlashTask?.cancel()
        showAudioIndicator = true

        audioFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            self?.showAudioIndicator = false
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    
    func updateCurrentClip(
        _ newClip: Clip,
        newVideoURL: URL? = nil,
        playWhenReady: Bool = false,
        reloadPlayer: Bool = true
    ) {
        let urlChanged = self.clip.fileURL != newClip.fileURL || self.videoURL != newVideoURL
        self.clip = newClip
        if let newVideoURL { self.videoURL = newVideoURL }
        
        if urlChanged && reloadPlayer {
            self.stop()
            setupPlayer(autoPlay: false)
            if playWhenReady {
                self.playWhenReady()
            }
        }
    }
    
    func refreshPlayerAfterImport() {
        setupPlayer()
    }
}

// MARK: - Custom Scrubber (bigger, guaranteed hitbox vs. native Slider)

/// A slim visual track with a much larger invisible touch band, so the
/// scrubber is easy to grab anywhere near the track — not just precisely on
/// the thin line or tiny thumb. Also uses `.highPriorityGesture` with
/// `minimumDistance: 0` so it reliably wins the touch over the pager's
/// own horizontal swipe-between-clips gesture.
private struct VideoScrubberTrack: View {
    @Binding var progress: Double
    @Binding var isScrubbing: Bool
    var onScrubBegan: () -> Void
    var onScrubChanged: (Double) -> Void
    var onScrubEnded: () -> Void
    
    private let trackHeight: CGFloat = 4
    private let hitAreaHeight: CGFloat = 44 // Apple's recommended minimum tap target
    private let thumbDiameter: CGFloat = 14
    private let thumbDiameterActive: CGFloat = 22
    
    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let clampedProgress = min(max(progress, 0), 1)
            let thumbX = width * CGFloat(clampedProgress)
            let thumbSize = isScrubbing ? thumbDiameterActive : thumbDiameter
            
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(height: trackHeight)
                
                Capsule()
                    .fill(Color.white)
                    .frame(width: thumbX, height: trackHeight)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(x: thumbX - thumbSize / 2)
            }
            .frame(height: hitAreaHeight)
            // The visible track is only 4pt tall, but the whole 44pt band is tappable/draggable.
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: isScrubbing)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            onScrubBegan()
                        }
                        isScrubbing = true
                        let clampedX = min(max(0, value.location.x), width)
                        progress = Double(clampedX / width)
                        onScrubChanged(progress)
                    }
                    .onEnded { _ in
                        onScrubEnded()
                    }
            )
        }
        .frame(height: hitAreaHeight)
    }
}
