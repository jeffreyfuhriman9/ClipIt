import SwiftUI
import AVFoundation
import AVKit
import Combine

struct ClipPlayerView: View {
    let clip: Clip
    let videoURL: URL?
    let sessionDuration: TimeInterval
    let onDelete: (() -> Void)?
    let onTrimSaved: ((Clip) -> Void)?
    var onRename: ((String) -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playerVM: ClipPlayerViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    
    @State private var showUI = true
    @State private var showTrimEditor = false
    @State private var showTitleEditor = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var wasPlayingBeforeTrim = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameAlert = false
    @State private var editedTitle = ""
    @State private var showImportAlert = false
    @State private var showDeletionWarning = false
    
    private var themeColor: Color {
        // If highlightIndex is nil, it's a full session -> use blue. Otherwise -> use red.
        playerVM.clip.highlightIndex == nil ? .blue : .red
    }
    
    private var deleteAlertTitle: String {
        playerVM.clip.highlightIndex == nil ? "Delete Full Recording?" : "Delete Highlight?"
    }
    
    private var deleteAlertMessage: String {
        if playerVM.clip.highlightIndex == nil {
            return "You will not be able to edit individual highlights after deleting the full recording."
        } else {
            return "Are you sure you want to permanently delete this highlight?"
        }
    }
    
    private var canTrim: Bool {
        playerVM.clip.highlightIndex != nil && (videoURL != nil || playerVM.clip.fileURL != nil)
    }
    
    private var isEditable: Bool {
        if playerVM.clip.highlightIndex == nil {
            // SCENARIO: It's the full recording itself. Check its own file.
            let path = (videoURL ?? playerVM.clip.fileURL)?.path ?? ""
            return !path.isEmpty && FileManager.default.fileExists(atPath: path)
        } else {
            // SCENARIO: It's a highlight. Check for the master source file.
            let masterURL = videoURL ?? playerVM.clip.sourceVideoURL
            let path = masterURL?.path ?? ""
            return !path.isEmpty && FileManager.default.fileExists(atPath: path) && playerVM.clip.hasSourceVideoAvailable
        }
    }
    
    init(
        clip: Clip,
        fullVideoURL: URL? = nil,
        sessionDuration: TimeInterval,
        onDelete: (() -> Void)? = nil,
        onTrimSaved: ((Clip) -> Void)? = nil,
        onRename: ((String) -> Void)? = nil
    ) {
        self.clip = clip
        self.videoURL = fullVideoURL
        self.sessionDuration = sessionDuration
        self.onDelete = onDelete
        self.onTrimSaved = onTrimSaved
        self.onRename = onRename
        
        _playerVM = StateObject(wrappedValue: ClipPlayerViewModel(clip: clip, videoURL: fullVideoURL))
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                videoArea
                    .frame(width: geometry.size.width, height: geometry.size.height)
                
                if showUI {
                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        bottomOverlay
                    }
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
        .onDisappear {
            playerVM.stop()
        }
        .onChange(of: scenePhase, performActionOnPhaseChange)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DidFinishImportingVideo"))) { _ in
            playerVM.refreshPlayerAfterImport()
        }
        .onChange(of: clip) { _, newClip in
            playerVM.updateCurrentClip(newClip, newVideoURL: videoURL)
        }
        // 🌟 Isolated Functional Modifiers
        .modifier(ClipPlayerSheetsAndCoversModifier(
            videoURL: videoURL,
            sessionDuration: sessionDuration,
            onTrimSaved: onTrimSaved,
            onDelete: onDelete,
            showTrimEditor: $showTrimEditor,
            showTitleEditor: $showTitleEditor,
            showShareSheet: $showShareSheet,
            shareURL: $shareURL,
            wasPlayingBeforeTrim: $wasPlayingBeforeTrim,
            scenePhase: scenePhase,
            playerVM: playerVM
        ))
        .modifier(ClipPlayerAlertsModifier(
            editedTitle: $editedTitle,
            showRenameAlert: $showRenameAlert,
            showDeleteConfirmation: $showDeleteConfirmation,
            showImportAlert: $showImportAlert,
            showDeletionWarning: $showDeletionWarning,
            deleteAlertTitle: deleteAlertTitle,
            deleteAlertMessage: deleteAlertMessage,
            playerVM: playerVM,
            multipeerManager: multipeerManager,
            onRename: onRename,
            onTrimSaved: onTrimSaved,
            onDelete: onDelete,
            dismiss: dismiss
        ))
    }
    
private var videoArea: some View {
        ZStack {
            if let player = playerVM.player {
                CustomVideoPlayer(player: player)
                    .onAppear {
                        NotificationCenter.default.post(name: NSNotification.Name("UpdatePlayerGravity"), object: nil)
                    }
            } else {
                Rectangle()
                    .fill(Color(white: 0.08))
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
            }
        }
        // 🌟 THE FIX: Apply zoom & tap directly to the whole window container!
        .zoomable(onSingleTap: {
            withAnimation(.easeInOut(duration: 0.2)) {
                showUI.toggle()
            }
        })
        .ignoresSafeArea()
    }
    
    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Button(action: {
                editedTitle = playerVM.clip.displayName
                showRenameAlert = true
            }) {
                HStack(spacing: 8) {
                    Text(playerVM.clip.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white) // 🌟 Kept white as requested
                    
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(themeColor)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // New Bouncer Edit Button
            // New Bouncer Edit Button
            Button(action: {
                handleEditTap()
            }) {
                Text("Edit")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isEditable ? themeColor : .gray) // 🌟 Extremely efficient line
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
            }        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        // 🌟 Solid Black Bar that pushes to the very top edge of the screen
        .background(Color.black.ignoresSafeArea(edges: .top))
    }
    
    private var bottomOverlay: some View {
        VStack(spacing: 14) {
            
            // 1. These now float directly over the video with a subtle shadow
            playbackControls
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            scrubber
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            // 2. The solid black bar is now ONLY wrapped around the action bar!
            actionBar
                .padding(.top, 16)   // Gives the black bar some space above the buttons
                .padding(.bottom, 4) // Pushes it toward the bottom edge
                .background(Color.black.ignoresSafeArea(edges: .bottom))
        }
        .padding(.top, 16)
    }
    
    private var playbackControls: some View {
        HStack(spacing: 36) {
            Button(action: { playerVM.seek(by: -10) }) {
                Image(systemName: "gobackward.10").font(.system(size: 24, weight: .medium)).foregroundColor(.white)
            }
            Button(action: { playerVM.togglePlayback() }) {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 58)).foregroundColor(.white)
            }
            Button(action: { playerVM.seek(by: 10) }) {
                Image(systemName: "goforward.10").font(.system(size: 24, weight: .medium)).foregroundColor(.white)
            }
        }.padding(.top, 8)
    }
    
    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { playerVM.progress },
                    set: { newValue in playerVM.progress = newValue; playerVM.isScrubbing = true }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in if !isEditing { playerVM.seekToProgress() } }
            )
            .tint(.white).padding(.horizontal, 20)
            
            HStack {
                Text(playerVM.currentTimeLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Color(white: 0.75))
                Spacer()
                Text(playerVM.durationLabel).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Color(white: 0.75))
            }.padding(.horizontal, 24)
        }
    }
    
    private var actionBar: some View {
            HStack {
                Button {
                    if let url = playerVM.clip.fileURL {
                        let clipDate = playerVM.clip.createdAt
                        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                        
                        // 🌟 Standardized ISO Share Filename
                        let exportFilename = ClipFilenameHelper.generateFilename(
                            title: playerVM.clip.displayName,
                            date: clipDate,
                            fileExtension: ext
                        )
                        
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(exportFilename)
                        try? FileManager.default.removeItem(at: tempURL)
                        try? FileManager.default.copyItem(at: url, to: tempURL)
                        
                        shareURL = tempURL
                        showShareSheet = true
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeColor)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                Button(action: { playerVM.toggleSpeed() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                        Text(playerVM.playbackRate == 1.0 ? "1.0x" : playerVM.playbackRate == 0.5 ? "0.5x Slo-Mo" : "0.25x Super Slo-Mo")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .foregroundColor(themeColor)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeColor)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 1)
        }
    
    
    private func handleEditTap() {
        if isEditable {
            // 1. Everything is available, proceed to trim!
            wasPlayingBeforeTrim = playerVM.isPlaying
            playerVM.pause()
            showTrimEditor = true
            
        } else if playerVM.clip.isSecondaryAngle {
            // 2. Not editable, but it's a secondary camera -> Must need import
            showImportAlert = true
            
        } else {
            // 3. Not editable and primary -> Master was deleted
            showDeletionWarning = true
        }
    }
    
    private func performActionOnPhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        if newPhase != .active {
            playerVM.stop()
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
    @Binding var showShareSheet: Bool
    @Binding var shareURL: URL?
    @Binding var wasPlayingBeforeTrim: Bool
    
    let scenePhase: ScenePhase
    @ObservedObject var playerVM: ClipPlayerViewModel
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $showTrimEditor, onDismiss: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if wasPlayingBeforeTrim && scenePhase == .active {
                        playerVM.play()
                    }
                    wasPlayingBeforeTrim = false
                }
            }) {
                if let url = videoURL ?? playerVM.clip.fileURL {
                    HighlightTrimView(
                        clip: playerVM.clip,
                        fullVideoURL: url,
                        sessionDuration: sessionDuration
                    ) { updatedClip in
                        onTrimSaved?(updatedClip)
                        playerVM.updateCurrentClip(updatedClip, newVideoURL: videoURL)
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
            .sheet(isPresented: $showShareSheet) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled(false)
                }
            }
    }
}

// MARK: - Isolated Alerts ViewModifier
private struct ClipPlayerAlertsModifier: ViewModifier {
    @Binding var editedTitle: String
    @Binding var showRenameAlert: Bool
    @Binding var showDeleteConfirmation: Bool
    @Binding var showImportAlert: Bool
    @Binding var showDeletionWarning: Bool
    
    let deleteAlertTitle: String
    let deleteAlertMessage: String
    
    @ObservedObject var playerVM: ClipPlayerViewModel
    var multipeerManager: MultipeerManager
    
    var onRename: ((String) -> Void)?
    let onTrimSaved: ((Clip) -> Void)?
    let onDelete: (() -> Void)?
    let dismiss: DismissAction
    
    func body(content: Content) -> some View {
        content
        .alert("Rename Clip", isPresented: $showRenameAlert) {
            TextField("Hype block,goal,rally,etc!", text: $editedTitle)
                .textInputAutocapitalization(.words)
            
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                let cleanTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    playerVM.clip.customName = cleanTitle
                    playerVM.clip.customTitle = cleanTitle
                    onRename?(cleanTitle)
                    onTrimSaved?(playerVM.clip)
                }
            }
        } message: {
            Text("Give your moment a title!")
        }
        .alert(deleteAlertTitle, isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(deleteAlertMessage)
        }
        // Alert 1: Deletion Warning for Primary Clips
        .alert("Edit Unavailable", isPresented: $showDeletionWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You cannot edit this highlight since the full recording was deleted.")
        }
        // Alert 2: Secondary Import Prompt for Multi-cam files
        .alert("Full Recording Required", isPresented: $showImportAlert) {
            Button("Import Now") {
                print("Initiating full recording transfer for session: \(playerVM.clip.sessionID)")
                // 🌟 Use the correct command from your MultipeerManager
                multipeerManager.sendCommand(.requestFullSessionVideo(sessionID: playerVM.clip.sessionID))
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To edit this highlight, you need to import the full recording from the secondary device. Ensure Multi-Cam is linked!")
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
        uiView.playerLayer.player = player
    }
}

final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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
    @Published var isPlaying: Bool = false
    @Published var isMuted: Bool = false
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    @Published var currentTimeLabel: String = "0:00"
    @Published var durationLabel: String = "0:00"
    @Published var showPlayPauseIndicator: Bool = false
    @Published var isScrubbing: Bool = false
    @Published var playbackRate: Float = 1.0

    private var timeObserver: Any?
    private var processingTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    init(clip: Clip, videoURL: URL? = nil) {
        self.clip = clip
        self.videoURL = videoURL
        setupPlayer()
        
        let initialURL = clip.fileURL ?? videoURL
        if initialURL == nil || !FileManager.default.fileExists(atPath: initialURL?.path ?? "") {
            self.isProcessing = true
            
            processingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let currentURL = self.clip.fileURL ?? self.videoURL
                    if let updatedURL = currentURL, FileManager.default.fileExists(atPath: updatedURL.path) {
                        self.setupPlayer()
                        break
                    }
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
        }
    }

    func setupPlayer() {
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
        
        avPlayer.play()
        avPlayer.rate = playbackRate
        
        ActivePlayerStore.shared.currentPlayer = avPlayer
        isPlaying = true

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
            // 🌟 CONCURRENCY FIX: Wrap in a MainActor Task to satisfy Swift's strict concurrency rules
            Task { @MainActor [weak self, weak playerForObserver] in
                guard let self, let playerForObserver, !self.isScrubbing else { return }
                let durationSeconds = playerForObserver.currentItem?.duration.seconds ?? 1
                guard durationSeconds > 0, durationSeconds.isFinite else { return }
                
                self.progress = time.seconds / durationSeconds
                self.currentTimeLabel = self.formatTime(time.seconds)
            }
        }
    }
    
    func play() {
        if let current = ActivePlayerStore.shared.currentPlayer, current !== player {
            current.pause()
        }
        player?.play()
        player?.rate = playbackRate
        ActivePlayerStore.shared.currentPlayer = player
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        processingTask?.cancel()
        processingTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        flashTask?.cancel()
        flashTask = nil
        
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
    }

    func toggleSpeed() {
        // 1. Cycle the rate
        if playbackRate == 1.0 {
            playbackRate = 0.5
        } else if playbackRate == 0.5 {
            playbackRate = 0.25
        } else {
            playbackRate = 1.0
        }
        
        // 2. Only apply the rate if the player exists
        guard let player = player else { return }
        
        // 3. IMPORTANT: Maintain the current play/pause state
        if isPlaying {
            player.rate = playbackRate
        } else {
            // If paused, we don't want to play.
            // Note: setting player.rate to 0 pauses the video,
            // but we just keep it paused.
            player.pause()
        }
    }
    func seek(by seconds: Double) {
        guard let player else { return }
        let current = player.currentTime().seconds
        let target = max(0, current + seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func seekToProgress() {
        guard let player,
              let total = player.currentItem?.duration.seconds,
              total > 0, total.isFinite else { return }
        
        let target = CMTime(seconds: progress * total, preferredTimescale: 600)
        let targetRate = self.playbackRate
        let shouldResumePlay = self.isPlaying
        
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            // 🌟 CONCURRENCY FIX: AVPlayer completion handlers run in the background.
            // We must hop back to the MainActor to mutate the view model.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isScrubbing = false
                if shouldResumePlay {
                    self.player?.rate = targetRate
                } else {
                    self.player?.pause()
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

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    
    func updateCurrentClip(_ newClip: Clip, newVideoURL: URL? = nil) {
        let urlChanged = self.clip.fileURL != newClip.fileURL || self.videoURL != newVideoURL
        self.clip = newClip
        if let newVideoURL { self.videoURL = newVideoURL }
        
        if urlChanged {
            self.stop()
            setupPlayer()
        }
    }
    
    func refreshPlayerAfterImport() {
        // Re-run the setup logic to point the player at the newly imported file
        setupPlayer()
    }
}

struct ZoomableVideoModifier: ViewModifier {
    var onSingleTap: () -> Void // 🔗 Pass the UI toggle behavior down
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    func body(content: Content) -> some View {
        content
            // 🛠️ FIX 1: Offset BEFORE scale makes panning track your finger perfectly
            .offset(offset)
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let delta = value / lastScale
                        lastScale = value
                        let newScale = scale * delta
                        scale = min(max(newScale, 1.0), 5.0)
                    }
                    .onEnded { _ in
                        lastScale = 1.0
                        if scale <= 1.05 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                scale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1.0 else { return }
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        guard scale > 1.0 else { return }
                        lastOffset = offset
                    }
            )
            // 🛠️ FIX 2: Coordinated tap hierarchy avoids structural gesture blocking
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                }
            }
            .onTapGesture {
                onSingleTap()
            }
    }
}

// Update your global view extension parameters
extension View {
    func zoomable(onSingleTap: @escaping () -> Void) -> some View {
        self.modifier(ZoomableVideoModifier(onSingleTap: onSingleTap))
    }
}
