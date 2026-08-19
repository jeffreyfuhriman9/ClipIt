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
    @State private var dragOffset: CGSize = .zero
    @State private var isDraggingVertically = false
    
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

    var body: some View {
        ZStack {
            // Dark Backdrop
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()
            
            // Paging Horizontal View
            TabView(selection: $selectedClipID) {
                ForEach(clips) { clip in
                    ClipPlayerContainer(
                        clip: clip,
                        isActive: clip.id == selectedClipID,
                        fullVideoURL: fullVideoURL,
                        sessionDuration: sessionDuration,
                        onDelete: { onDelete(clip) },
                        onTrimSaved: onTrimSaved,
                        onRename: { newName in onRename(clip, newName) }
                    )
                    .tag(clip.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: max(0, dragOffset.height))
            .scaleEffect(scaleFactor)
            .ignoresSafeArea()
            // simultaneousGesture lets TabView handle horizontal swipes while handling vertical drags
            .simultaneousGesture(
                DragGesture()
                    .onChanged { gesture in
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
                        if isDraggingVertically {
                            if gesture.translation.height > 100 || gesture.predictedEndTranslation.height > 200 {
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
    }
}

// MARK: - Container for Pager
private struct ClipPlayerContainer: View {
    let clip: Clip
    let isActive: Bool
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
    let onDelete: () -> Void
    let onTrimSaved: (Clip) -> Void
    let onRename: (String) -> Void

    var body: some View {
        ClipPlayerView(
            clip: clip,
            isActive: isActive,
            fullVideoURL: fullVideoURL,
            sessionDuration: sessionDuration,
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
    @State private var wasPlayingBeforeTrim = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameAlert = false
    @State private var editedTitle = ""
    @State private var showImportAlert = false
    @State private var showDeletionWarning = false
    @State private var wasPlayingBeforeBackground = false
    
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
        onDelete: (() -> Void)? = nil,
        onTrimSaved: ((Clip) -> Void)? = nil,
        onRename: ((String) -> Void)? = nil
    ) {
        self.clip = clip
        self.isActive = isActive
        self.videoURL = fullVideoURL
        self.sessionDuration = sessionDuration
        self.onDelete = onDelete
        self.onTrimSaved = onTrimSaved
        self.onRename = onRename
        
        _playerVM = StateObject(wrappedValue: ClipPlayerViewModel(clip: clip, videoURL: fullVideoURL, autoPlay: isActive))
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
        .onAppear {
            playerVM.setActive(isActive)
        }
        .onChange(of: isActive) { _, nowActive in
            playerVM.setActive(nowActive)
        }
        .onChange(of: scenePhase, performActionOnPhaseChange)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DidFinishImportingVideo"))) { _ in
            playerVM.refreshPlayerAfterImport()
        }
        .onChange(of: clip) { _, newClip in
            playerVM.updateCurrentClip(newClip, newVideoURL: videoURL)
        }
        .modifier(ClipPlayerSheetsAndCoversModifier(
            videoURL: videoURL,
            sessionDuration: sessionDuration,
            onTrimSaved: onTrimSaved,
            onDelete: onDelete,
            showTrimEditor: $showTrimEditor,
            showTitleEditor: $showTitleEditor,
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
        ZoomableVideoContainer(onSingleTap: {
            withAnimation(.easeInOut(duration: 0.2)) {
                showUI.toggle()
            }
        }) {
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
        }
        .ignoresSafeArea()
    }
    
    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 34, height: 34)
                    // CHANGE: Use dark translucent background instead of white
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Button(action: {
                editedTitle = playerVM.clip.displayName
                showRenameAlert = true
            }) {
                HStack(spacing: 6) {
                    Text(playerVM.clip.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeColor) // 🎨 Color-coded by clip type!
                    
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(themeColor)
                        .frame(width: 22, height: 22)
                        // CHANGE: Dark translucent background
                        .background(Color.black.opacity(0.05))
                        .clipShape(Circle())
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Button(action: {
                handleEditTap()
            }) {
                Text("Edit")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isEditable ? themeColor : .gray)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    // CHANGE: Dark translucent background
                    .background(Color.black.opacity(0.05))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        // CHANGE: White background
        .background(Color.white.ignoresSafeArea(edges: .top))
    }
    
    private var bottomOverlay: some View {
        VStack(spacing: 14) {
            playbackControls
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            scrubber
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            
            actionBar
                .padding(.top, 8)
                .padding(.bottom, 2)
                .background(Color.white.ignoresSafeArea(edges: .bottom))
        }
        .padding(.top, 16)
    }
    
    private var playbackControls: some View {
        HStack {
            Button(action: { playerVM.togglePlayback() }) {
                Image(systemName: playerVM.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    // CHANGE: Dark icon color
                    .foregroundColor(Color.white)
            }
            
            Spacer()
            
            Button(action: { playerVM.toggleMute() }) {
                Image(systemName: playerVM.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    // CHANGE: Dark icon color
                    .foregroundColor(Color.white)
                    .frame(width: 42, height: 42)
                    // CHANGE: Dark translucent background
                    .background(Color.black.opacity(0.95))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
    
    private var scrubber: some View {
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
                onScrubEnded: { playerVM.seekToProgress() }
            )
            .padding(.horizontal, 20)
            
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
                    .background(Color.black.opacity(0.05))
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
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            Button(action: { playerVM.toggleSpeed() }) {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.needle")
                    Text(playerVM.playbackRate == 1.0 ? "1.0x" : playerVM.playbackRate == 0.5 ? "0.5x Slo-Mo" : "0.25x Super Slo-Mo")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .foregroundColor(themeColor)
                .background(Color.black.opacity(0.05))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            Button(action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 1)
        .background(Color.white.ignoresSafeArea(edges: .bottom))
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
        if isEditable {
            wasPlayingBeforeTrim = playerVM.isPlaying
            playerVM.pause()
            showTrimEditor = true
        } else if playerVM.clip.isSecondaryAngle {
            showImportAlert = true
        } else {
            showDeletionWarning = true
        }
    }
    
    private func performActionOnPhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        // Pause (rather than fully tear down) so the player and its position
        // survive backgrounding — returning to the app resumes right where
        // you left off instead of showing "Clip not available."
        if newPhase == .active {
            if oldPhase != .active && isActive && wasPlayingBeforeBackground {
                playerVM.play()
            }
        } else {
            wasPlayingBeforeBackground = playerVM.isPlaying
            playerVM.pause()
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
                if let url = videoURL ?? playerVM.clip.sourceVideoURL ?? playerVM.clip.fileURL {
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
        .overlay(alignment: .top) {
            if showRenameAlert {
                // Dimmed backdrop behind the top card
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showRenameAlert = false
                        }
                    }
                    .transition(.opacity)
                
                // Top-sliding card
                RenameClipSheet(
                    editedTitle: $editedTitle,
                    onSave: { newTitle in
                        playerVM.clip.customName = newTitle
                        playerVM.clip.customTitle = newTitle
                        onRename?(newTitle)
                        onTrimSaved?(playerVM.clip)
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showRenameAlert = false
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity)) // 👈 Slides down from top
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showRenameAlert)
        .alert(deleteAlertTitle, isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("Edit Unavailable", isPresented: $showDeletionWarning) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You cannot edit this highlight since the full recording was deleted.")
        }
        .alert("Full Recording Required", isPresented: $showImportAlert) {
            Button("Import Now") {
                print("Initiating full recording transfer for session: \(playerVM.clip.sessionID)")
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

    // Tracks whether this page is the one currently selected in the pager.
    // Used to guard async seek/play completions so a stale callback from a
    // page you've since swiped away from can't resurrect playback or steal
    // focus from the page you're actually looking at.
    private var isActive: Bool = false

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
        
        if autoPlay {
            avPlayer.play()
            avPlayer.rate = playbackRate
            ActivePlayerStore.shared.currentPlayer = avPlayer
            isPlaying = true
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
        isActive = active
        if active {
            rewindAndPlay()
        } else {
            pauseAndResetToBeginning()
        }
    }

    func pauseAndResetToBeginning() {
        player?.pause()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
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
                self.play()
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
        isActive = false
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
        if playbackRate == 1.0 {
            playbackRate = 0.5
        } else if playbackRate == 0.5 {
            playbackRate = 0.25
        } else {
            playbackRate = 1.0
        }
        
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

    func seekToProgress() {
        guard let player,
              let total = player.currentItem?.duration.seconds,
              total > 0, total.isFinite else { return }
        
        let target = CMTime(seconds: progress * total, preferredTimescale: 600)
        let targetRate = self.playbackRate
        let shouldResumePlay = self.isPlaying
        
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
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
            setupPlayer(autoPlay: false)   // ← was setupPlayer() — now opens paused
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
                        isScrubbing = true
                        let clampedX = min(max(0, value.location.x), width)
                        progress = Double(clampedX / width)
                    }
                    .onEnded { _ in
                        onScrubEnded()
                    }
            )
        }
        .frame(height: hitAreaHeight)
    }
}

// MARK: - Pinch-to-Zoom Video Container (Apple Photos-style)
// SwiftUI's MagnificationGesture doesn't expose the pinch location, only the
// scale delta, so there's no way to anchor zoom to the touch point in pure
// SwiftUI. This wraps the video in a UIKit pinch/pan handler instead, which
// gives us the actual touch location and lets us fully disable the pan
// recognizer whenever we're not zoomed in — so it never competes with the
// pager's own swipe-to-next-clip gesture.
struct ZoomableVideoContainer<Content: View>: UIViewRepresentable {
    let content: Content
    let onSingleTap: () -> Void
    
    init(onSingleTap: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.onSingleTap = onSingleTap
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
    }
    
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .clear
        
        let hostingController = UIHostingController(rootView: content)
        hostingController.view.backgroundColor = .clear
        let hostedView = hostingController.view!
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        
        context.coordinator.hostingController = hostingController
        context.coordinator.contentView = hostedView
        context.coordinator.containerView = container
        
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        container.addGestureRecognizer(pinch)
        
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 2
        pan.isEnabled = false // Only enabled once zoomed in, so it never steals the pager's swipe.
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
    
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hostingController?.rootView = content
    }
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var hostingController: UIHostingController<Content>?
        weak var contentView: UIView?
        weak var containerView: UIView?
        weak var panGesture: UIPanGestureRecognizer?
        
        let onSingleTap: () -> Void
        private var currentScale: CGFloat = 1.0
        private let minScale: CGFloat = 1.0
        private let maxScale: CGFloat = 5.0
        
        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        // Explicit deinit (instead of letting the compiler synthesize one) works
        // around a Swift 6.3.3 -O optimizer crash (EarlyPerfInliner) that was
        // occurring specifically on the auto-generated deinit for this class,
        // since it's an NSObject subclass nested in a generic type holding
        // weak references typed with that generic parameter.
        deinit {
            panGesture = nil
            hostingController = nil
            contentView = nil
            containerView = nil
        }
        
        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap()
        }
        
        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let contentView else { return }
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
                contentView.transform = .identity
            }
            currentScale = 1.0
            panGesture?.isEnabled = false
        }
        
        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let contentView, let containerView else { return }
            
            switch gesture.state {
            case .began, .changed:
                // Anchor the scale to wherever the pinch is happening, not the center.
                let pinchCenter = gesture.location(in: containerView)
                let anchor = CGPoint(
                    x: pinchCenter.x - containerView.bounds.midX,
                    y: pinchCenter.y - containerView.bounds.midY
                )
                
                var transform = contentView.transform
                transform = transform.translatedBy(x: anchor.x, y: anchor.y)
                transform = transform.scaledBy(x: gesture.scale, y: gesture.scale)
                transform = transform.translatedBy(x: -anchor.x, y: -anchor.y)
                
                var resultingScale = sqrt(transform.a * transform.a + transform.c * transform.c)
                if resultingScale < minScale {
                    transform = transform.scaledBy(x: minScale / resultingScale, y: minScale / resultingScale)
                    resultingScale = minScale
                } else if resultingScale > maxScale {
                    transform = transform.scaledBy(x: maxScale / resultingScale, y: maxScale / resultingScale)
                    resultingScale = maxScale
                }
                
                contentView.transform = transform
                gesture.scale = 1.0
                currentScale = resultingScale
                panGesture?.isEnabled = currentScale > 1.01
                
            case .ended, .cancelled:
                if currentScale <= 1.05 {
                    UIView.animate(withDuration: 0.25) {
                        contentView.transform = .identity
                    }
                    currentScale = 1.0
                    panGesture?.isEnabled = false
                } else {
                    clampContentPosition(animated: true)
                }
            default:
                break
            }
        }
        
        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let contentView, let containerView, currentScale > 1.01 else { return }
            
            switch gesture.state {
            case .changed:
                let translation = gesture.translation(in: containerView)
                contentView.transform = contentView.transform.translatedBy(
                    x: translation.x / currentScale,
                    y: translation.y / currentScale
                )
                gesture.setTranslation(.zero, in: containerView)
            case .ended, .cancelled:
                clampContentPosition(animated: true)
            default:
                break
            }
        }
        
        private func clampContentPosition(animated: Bool) {
            guard let contentView, let containerView else { return }
            
            let scaledWidth = containerView.bounds.width * currentScale
            let scaledHeight = containerView.bounds.height * currentScale
            let maxOffsetX = max(0, (scaledWidth - containerView.bounds.width) / 2 / currentScale)
            let maxOffsetY = max(0, (scaledHeight - containerView.bounds.height) / 2 / currentScale)
            
            let clampedTx = min(max(contentView.transform.tx, -maxOffsetX), maxOffsetX)
            let clampedTy = min(max(contentView.transform.ty, -maxOffsetY), maxOffsetY)
            
            guard clampedTx != contentView.transform.tx || clampedTy != contentView.transform.ty else { return }
            
            var newTransform = contentView.transform
            newTransform.tx = clampedTx
            newTransform.ty = clampedTy
            
            if animated {
                UIView.animate(withDuration: 0.25) { contentView.transform = newTransform }
            } else {
                contentView.transform = newTransform
            }
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
