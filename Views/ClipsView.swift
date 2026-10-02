//
//  ClipsView.swift
//  Clipit
//

import SwiftUI
import AVFoundation

// MARK: - Filter Enum

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case highlights = "Highlights"
    case favorites = "Favorites"
    case reels = "Reels"
    case fullRecordings = "Original Video"
    
    var id: String { self.rawValue }
    
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .highlights: return "flame.fill"
        case .reels: return "movieclapper.fill"
        case .fullRecordings: return "play.circle.fill"
        case .favorites: return "heart.fill"
        }
    }
    
    var accentColor: Color {
        switch self {
        case .all:
            return Color.gochujangRed // overview / neutral
        case .highlights:
            return Color.crimsonBlaze // primary highlight energy
        case .reels:
            return Color.blueMarble // reels are assembled from highlights, same red family
        case .fullRecordings:
            return Color.cosmosBlue // raw/original footage, "video quality" tone
        case .favorites:
            return Color.crimsonBlaze
        }
    }
}

// MARK: - Clip Category Type Enum

enum ClipCategoryType {
    case fullRecording
    case highlight
    case reel
    
    var color: Color {
        switch self {
        case .fullRecording:
            return Color.cosmosBlue // raw/original footage
        case .highlight:
            return Color.crimsonBlaze // primary highlight energy
        case .reel:
            return Color.blueMarble // reels are assembled from highlights, same red family
        }
    }
}

/// Kept by the gallery rather than a lazy thumbnail cell. A grid cell may be
/// rebuilt during rotation, but this presentation remains alive so the player
/// does not disappear when portrait switches to landscape.
private struct ClipPlayerPresentation: Identifiable {
    let id = UUID()
    let clips: [Clip]
    let initialClipID: UUID
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
}

// MARK: - Main Clips View

struct ClipsView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    
    @State private var sessionBeingRenamed: Session?
    @State private var renameDraft = ""
    @State private var sessionToDelete: Session?
    @State private var fullRecordingToDelete: Session?
    
    @State private var isSelectionMode = false
    @State private var selectedClipIDs = Set<UUID>()
    @State private var showDeleteConfirmation = false
    
    @State private var isReelSelectionMode = false
    // An array deliberately preserves the order the user taps highlights.
    // That order becomes the first-to-last order in the generated reel.
    @State private var selectedReelClipIDs: [UUID] = []
    
    @State private var selectedFilter: ClipFilter = .all
    
    @State private var shareContainer: ShareContainer?
    @State private var showCreateReelSheet = false
    @State private var playerPresentation: ClipPlayerPresentation?
    
    @State private var isLandscapeSession = false
        
        // 🌟 Dynamically applies 2 columns for landscape, 3 for portrait
        private var dynamicColumns: [GridItem] {
            if isLandscapeSession {
                return [
                    GridItem(.flexible(), spacing: 3),
                    GridItem(.flexible(), spacing: 3)
                ]
            } else {
                return [
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2),
                    GridItem(.flexible(), spacing: 2)
                ]
            }
        }
    
    private var visibleSessions: [Session] {
        guard selectedFilter == .favorites else { return recordingVM.sessions }
        return recordingVM.sessions.filter { session in
            session.clips.contains { $0.isFavorite }
        }
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: stickyTopHeader) {
                            if visibleSessions.isEmpty {
                                emptyState
                            } else if selectedFilter == .reels {
                                flattenedReelsGrid
                                    .padding(.top, 8)
                            } else {
                                ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                                    SessionCardView(
                                        session: session,
                                        selectedFilter: selectedFilter,
                                        renameDraft: $renameDraft,
                                        sessionBeingRenamed: $sessionBeingRenamed,
                                        sessionToDelete: $sessionToDelete,
                                        fullRecordingToDelete: $fullRecordingToDelete,
                                        isSelectionMode: $isSelectionMode,
                                        selectedClipIDs: $selectedClipIDs,
                                        isReelSelectionMode: $isReelSelectionMode,
                                        selectedReelClipIDs: $selectedReelClipIDs,
                                        onOpenPlayer: { playerPresentation = $0 }
                                    )
                                    .padding(.top, 16)
                                    .padding(.bottom, 20)
                                    
                                    if selectedFilter != .reels && index < visibleSessions.count - 1 {
                                        Rectangle()
                                            .fill(Color.cosmosBlue)
                                            .frame(height: 5)
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.white)
                }
                .navigationTitle("ClipIt Library")
                .navigationBarTitleDisplayMode(.large)
                .toolbarTitleDisplayMode(.large)
                .onChange(of: recordingVM.pendingHighlightToOpen) { _, newValue in
                    if newValue != nil {
                        withAnimation { selectedFilter = .highlights }
                    }
                }
                .fullScreenCover(item: $recordingVM.pendingHighlightToOpen) { pendingClip in
                    if let session = recordingVM.sessions.first(where: { $0.id == pendingClip.sessionID }) {
                        let highlightClips = session.clips.filter {
                            $0.highlightIndex != nil && !$0.isReel && !$0.isSecondaryAngle
                        }
                        ClipPagerView(
                            clips: highlightClips,
                            initialClipID: pendingClip.id,
                            fullVideoURL: session.fullVideoURL,
                            sessionDuration: session.duration,
                            onDelete: { _ in recordingVM.deleteClip(sessionID: session.id, clipID: pendingClip.id) },
                            onTrimSaved: { u in recordingVM.updateClip(u) },
                            onRename: { c, n in var u = c; u.customName = n; recordingVM.updateClip(u) }
                        )
                    }
                }
                .fullScreenCover(item: $playerPresentation) { presentation in
                    ClipPagerView(
                        clips: presentation.clips,
                        initialClipID: presentation.initialClipID,
                        fullVideoURL: presentation.fullVideoURL,
                        sessionDuration: presentation.sessionDuration,
                        onDelete: { clip in
                            if clip.highlightIndex == nil {
                                recordingVM.deleteFullRecording(sessionID: clip.sessionID)
                            } else {
                                recordingVM.deleteClip(sessionID: clip.sessionID, clipID: clip.id)
                            }
                        },
                        onTrimSaved: { updatedClip in
                            recordingVM.updateClip(updatedClip)
                            // A Save-as-New trim creates a clip that was not
                            // in this pager's original list. Return to the
                            // gallery only for that intentional navigation.
                            if !presentation.clips.contains(where: { $0.id == updatedClip.id }) {
                                playerPresentation = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    recordingVM.pendingHighlightToOpen = updatedClip
                                }
                            }
                        },
                        onRename: { clip, name in
                            var updatedClip = clip
                            updatedClip.customName = name
                            recordingVM.updateClip(updatedClip)
                        }
                    )
                    .environmentObject(multipeerManager)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !recordingVM.sessions.isEmpty && !isReelSelectionMode {
                            Button(isSelectionMode ? "Cancel" : "Select") {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    isSelectionMode.toggle()
                                    if !isSelectionMode {
                                        selectedClipIDs.removeAll()
                                    }
                                }
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(Color.crimsonBlaze)
                        } else if isReelSelectionMode {
                            Button("Cancel") {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    isReelSelectionMode = false
                                    selectedReelClipIDs.removeAll()
                                }
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(Color.cosmosBlue)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if isSelectionMode {
                        selectionBottomBar
                    } else if isReelSelectionMode {
                        reelSelectionBottomBar
                    }
                }
                .toolbar((isSelectionMode || isReelSelectionMode) ? .hidden : .visible, for: .tabBar)
                .alert("Delete Selected Clips?", isPresented: $showDeleteConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        deleteSelectedClips()
                    }
                } message: {
                    Text("Are you sure you want to delete \(selectedClipIDs.count) clip(s)? This action cannot be undone.")
                }
                .alert(item: $sessionToDelete) { session in
                    Alert(
                        title: Text("Delete \"\(session.name)\"?"),
                        message: Text("This will permanently remove this session and all associated clips."),
                        primaryButton: .destructive(Text("Delete")) {
                            recordingVM.deleteSession(id: session.id)
                            sessionToDelete = nil
                        },
                        secondaryButton: .cancel {
                            sessionToDelete = nil
                        }
                    )
                }
                .sheet(item: $sessionBeingRenamed) { session in
                    RenameSessionSheet(
                        sessionName: session.name,
                        draftName: $renameDraft,
                        onSave: {
                            recordingVM.renameSession(id: session.id, newName: renameDraft)
                            sessionBeingRenamed = nil
                        },
                        onCancel: { sessionBeingRenamed = nil }
                    )
                }
                .sheet(item: $shareContainer, onDismiss: { resetSelection() }) { container in
                    ShareSheet(items: container.urls)
                }
                .onChange(of: selectedFilter) { _, newFilter in
                    if newFilter == .reels {
                        checkReelsOrientation()
                    }
                }
                .sheet(isPresented: $showCreateReelSheet, onDismiss: {
                    resetReelSelection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedFilter = .reels
                    }
                }) {
                    CreateReelSheet(
                        targetSessionID: getSelectedReelClips().first?.sessionID,
                        selectedClips: getSelectedReelClips()
                    )
                }
            }
            .preferredColorScheme(.light)
            
            if recordingVM.isExtractingHighlights {
                extractionOverlay
            }
            if recordingVM.isImportingSecondary {
                importOverlay
            }
        }
        .animation(.easeInOut(duration: 0.3), value: recordingVM.isExtractingHighlights)
        .animation(.default, value: multipeerManager.importedVideoURLQueue)
    }
    
    // MARK: - Overlays
    
    private var extractionOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .crimsonBlaze))
                    .scaleEffect(1.5)
                Text("Extracting Highlights...")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white)
                HighlightExtractionProgressView(
                    currentCount: recordingVM.currentExtractionProgress,
                    totalCount: recordingVM.totalExtractionCount
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
            }
        }
        .transition(.opacity)
        .id("ClipsExtractionOverlay")
    }
    
    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 24) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .crimsonBlaze))
                    .scaleEffect(1.5)
                Text("Importing Angles...")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white)
                HighlightExtractionProgressView(
                    currentCount: multipeerManager.receivedHighlightCount,
                    totalCount: max(1, multipeerManager.expectedHighlightCount)
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
            }
        }
        .transition(.opacity)
        .id("ClipsImportOverlay")
    }
    
    // MARK: - Sticky Top Filter & Action Bar
    
    private var stickyTopHeader: some View {
        VStack(spacing: 0) {
            if !recordingVM.sessions.isEmpty {
                pillFilterBar
                    .padding(.vertical, 8)
            }
            
            // 🎯 Shows the banner on Highlights, Reels, and Original Video tabs
            if selectedFilter != .all && selectedFilter != .favorites && !recordingVM.sessions.isEmpty && !isSelectionMode {
                createReelQuickBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.white)
    }
    
    private var createReelQuickBanner: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedFilter = .highlights // 🎯 Automatically routes to Highlights tab
                isReelSelectionMode = true
                selectedReelClipIDs.removeAll()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Create ClipIt Reel")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [
                        Color.crimsonBlaze,
                        Color.blueMarble
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.blueMarble.opacity(0.4), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
    
    private var pillFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClipFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            // 🎯 Resets and exits selection mode if the user navigates away from Highlights
                            if isReelSelectionMode && filter != .highlights {
                                resetReelSelection()
                            }
                            selectedFilter = filter
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.icon)
                                .font(.system(size: 12, weight: .bold))
                            Text(filter.rawValue)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(isSelected ? .white : filter.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(isSelected ? filter.accentColor : Color.white)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(filter.accentColor, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .background(Color.white)
    }
    
    private var flattenedReelsGrid: some View {
        let allReels: [(clip: Clip, sessionID: UUID, fullVideoURL: URL?, duration: TimeInterval)] = recordingVM.sessions.flatMap { session in
            session.clips
                .filter { $0.isReel || $0.displayName.contains("Highlight Reel") || $0.displayName.contains("Set") }
                .map { (clip: $0, sessionID: session.id, fullVideoURL: session.fullVideoURL, duration: session.duration) }
        }
        
        return LazyVGrid(columns: dynamicColumns, spacing: isLandscapeSession ? 3 : 2) {
            ForEach(allReels, id: \.clip.id) { item in
                UnifiedGridCardView(
                    sessionID: item.sessionID,
                    clip: item.clip,
                    category: .reel,
                    allClips: allReels.map { $0.clip },
                    fullVideoURL: item.fullVideoURL,
                    originalVideoDeletionDate: nil,
                    sessionDuration: item.duration,
                    isSelectionMode: isSelectionMode,
                    isSelected: selectedClipIDs.contains(item.clip.id),
                    isReelSelectionMode: isReelSelectionMode,
                    isReelSelected: selectedReelClipIDs.contains(item.clip.id),
                    reelSelectionNumber: selectedReelClipIDs.firstIndex(of: item.clip.id).map { $0 + 1 },
                    isLandscape: isLandscapeSession,
                    onSelectToggle: { toggleSelection(item.clip.id) },
                    onReelSelectToggle: { toggleReelSelection(item.clip.id) },
                    onDelete: { recordingVM.deleteClip(sessionID: item.sessionID, clipID: item.clip.id) },
                    onOpenPlayer: { playerPresentation = $0 }
                )
            }
        }
        .padding(.horizontal, 4)
        .onAppear {
            checkReelsOrientation()
        }
    }
    
    private var reelSelectionBottomBar: some View {
        let reelColor = Color.blueMarble
        
        return VStack(spacing: 0) {
            Button(action: { showCreateReelSheet = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text("Create Reel (\(selectedReelClipIDs.count))")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(selectedReelClipIDs.isEmpty ? Color.gray.opacity(0.3) : reelColor)
                .cornerRadius(14)
                .shadow(
                    color: selectedReelClipIDs.isEmpty ? .clear : reelColor.opacity(0.5),
                    radius: 8,
                    x: 0,
                    y: 4
                )
            }
            .disabled(selectedReelClipIDs.isEmpty)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color(UIColor.separator)), alignment: .top)
    }
    
    private var selectionBottomBar: some View {
        HStack {
            Button(action: shareSelectedClips) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20, weight: .semibold))
            }.disabled(selectedClipIDs.isEmpty)
            Spacer()
            Button(action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(selectedClipIDs.isEmpty ? .gray : Color.crimsonBlaze)
            }.disabled(selectedClipIDs.isEmpty)
        }
        .padding(.horizontal, 28).padding(.vertical, 12).background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color(UIColor.separator)), alignment: .top)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack").font(.system(size: 48)).foregroundColor(.gray)
            Text("No Memorable Moments Yet").font(.title3.bold()).foregroundColor(Color.cosmosBlue)
            Text("Head to Record to start capturing highlights.").font(.subheadline).foregroundColor(.gray).multilineTextAlignment(.center)
        }.padding(.top, 100)
    }
    
    private func resetSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { isSelectionMode = false; selectedClipIDs.removeAll() }
    }
    
    private func resetReelSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { isReelSelectionMode = false; selectedReelClipIDs.removeAll() }
    }
    
    private func toggleSelection(_ clipID: UUID) {
        if selectedClipIDs.contains(clipID) { selectedClipIDs.remove(clipID) }
        else { selectedClipIDs.insert(clipID) }
    }
    
    private func toggleReelSelection(_ clipID: UUID) {
        if let index = selectedReelClipIDs.firstIndex(of: clipID) {
            selectedReelClipIDs.remove(at: index)
        } else {
            selectedReelClipIDs.append(clipID)
        }
    }
    
    private func deleteSelectedClips() {
        for session in recordingVM.sessions {
            for clip in session.clips where selectedClipIDs.contains(clip.id) {
                recordingVM.deleteClip(sessionID: session.id, clipID: clip.id)
            }
        }
        resetSelection()
    }
    
    private func shareSelectedClips() {
        var urlsToShare: [URL] = []
        for session in recordingVM.sessions {
            for clip in session.clips where selectedClipIDs.contains(clip.id) {
                if let url = clip.fileURL { urlsToShare.append(url) }
            }
        }
        guard !urlsToShare.isEmpty else { return }
        self.shareContainer = ShareContainer(urls: urlsToShare)
    }
    
    private func getSelectedReelClips() -> [Clip] {
        let clipsByID = Dictionary(
            uniqueKeysWithValues: recordingVM.sessions
                .flatMap(\.clips)
                .map { ($0.id, $0) }
        )
        return selectedReelClipIDs.compactMap { clipsByID[$0] }
    }
    
    private func checkReelsOrientation() {
        let allReels = recordingVM.sessions.flatMap { session in
            session.clips.filter { $0.isReel || $0.displayName.contains("Highlight Reel") || $0.displayName.contains("Set") }
        }
        guard let url = allReels.first?.fileURL else { return }
        
        Task {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                
                let isLandscape = size.width > size.height
                let isPortraitTransform = (transform.a == 0 && abs(transform.b) == 1.0)
                let finalLandscape = isPortraitTransform ? !isLandscape : isLandscape
                
                await MainActor.run {
                    self.isLandscapeSession = finalLandscape
                }
            }
        }
    }
}

// MARK: - SessionCardView

private struct SessionCardView: View {
    let session: Session
    let selectedFilter: ClipFilter
    
    @EnvironmentObject var recordingVM: RecordingViewModel
    @Binding var renameDraft: String
    @Binding var sessionBeingRenamed: Session?
    @Binding var sessionToDelete: Session?
    @Binding var fullRecordingToDelete: Session?
    
    @Binding var isSelectionMode: Bool
    @Binding var selectedClipIDs: Set<UUID>
    
    @Binding var isReelSelectionMode: Bool
    @Binding var selectedReelClipIDs: [UUID]
    let onOpenPlayer: (ClipPlayerPresentation) -> Void
    
    private var primaryClips: [Clip] {
        var ordered: [Clip] = []
        ordered.append(contentsOf: clippedHighlights)
        ordered.append(contentsOf: highlightReels)
        if let master = fullRecordingClip {
            ordered.append(master)
        }
        return ordered
    }
    
    private var fullRecordingClip: Clip? { session.clips.first { $0.highlightIndex == nil && !$0.isReel && !$0.isSecondaryAngle } }
    private var clippedHighlights: [Clip] { session.clips.filter { $0.highlightIndex != nil && !$0.isReel && !$0.isSecondaryAngle } }
    private var highlightReels: [Clip] {
        session.clips.filter {
            $0.id != fullRecordingClip?.id && ($0.isReel || $0.displayName.contains("Highlight Reel"))
        }
    }
    
    private var filteredClipsWithCategories: [(clip: Clip, category: ClipCategoryType)] {
        var list: [(clip: Clip, category: ClipCategoryType)] = []
        
        if selectedFilter == .all || selectedFilter == .highlights {
            for clip in clippedHighlights {
                list.append((clip, .highlight))
            }
        }
        
        if selectedFilter == .all || selectedFilter == .reels {
            for clip in highlightReels {
                list.append((clip, .reel))
            }
        }
        
        if (selectedFilter == .all || selectedFilter == .fullRecordings), let master = fullRecordingClip {
            list.append((master, .fullRecording))
        }

        if selectedFilter == .favorites {
            list = primaryClips.filter { $0.isFavorite }.map { clip in
                let category: ClipCategoryType = clip.isReel ? .reel : (clip.highlightIndex == nil ? .fullRecording : .highlight)
                return (clip, category)
            }
        }
        
        return list
    }
    
    // 🌟 1. Detect if the session is landscape
    @State private var isLandscapeSession = false
    
    // 🌟 2. Dynamic grid array (2 cols for landscape, 3 cols for portrait)
    private var dynamicColumns: [GridItem] {
        if isLandscapeSession {
            return [
                GridItem(.flexible(), spacing: 3),
                GridItem(.flexible(), spacing: 3)
            ]
        } else {
            return [
                GridItem(.flexible(), spacing: 2),
                GridItem(.flexible(), spacing: 2),
                GridItem(.flexible(), spacing: 2)
            ]
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if selectedFilter != .reels {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(session.name)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color.cosmosBlue)
                            
                            Button {
                                renameDraft = session.name
                                sessionBeingRenamed = session
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color.gochujangRed)
                                    .frame(width: 22, height: 22)
                                    // CHANGE: Dark translucent background
                                    .background(Color.black.opacity(0.05))
                                    .clipShape(Circle())
                            }
                        }
                        Text("\(session.formattedDate)  •  \(session.durationLabel)")
                            .font(.caption)
                            .foregroundColor(.cosmosBlue)
                    }
                    
                    Spacer()
                    
                    if isSelectionMode {
                        Button(role: .destructive) { sessionToDelete = session } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color.crimsonBlaze)
                                .padding(10)
                                .background(Color.crimsonBlaze.opacity(0.15))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            
            if !filteredClipsWithCategories.isEmpty {
                // 🌟 3. Apply the dynamic columns and spacing
                LazyVGrid(columns: dynamicColumns, spacing: isLandscapeSession ? 3 : 2) {
                    ForEach(filteredClipsWithCategories, id: \.clip.id) { item in
                        UnifiedGridCardView(
                            sessionID: session.id,
                            clip: item.clip,
                            category: item.category,
                            allClips: filteredClipsWithCategories.map { $0.clip },
                            fullVideoURL: session.fullVideoURL,
                            originalVideoDeletionDate: session.originalVideoDeletionDate,
                            sessionDuration: session.duration,
                            isSelectionMode: isSelectionMode,
                            isSelected: selectedClipIDs.contains(item.clip.id),
                            isReelSelectionMode: isReelSelectionMode,
                            isReelSelected: selectedReelClipIDs.contains(item.clip.id),
                            reelSelectionNumber: selectedReelClipIDs.firstIndex(of: item.clip.id).map { $0 + 1 },
                            isLandscape: isLandscapeSession,
                            onSelectToggle: { toggleSelection(item.clip.id) },
                            onReelSelectToggle: { toggleReelSelection(item.clip.id) },
                            onDelete: {
                                if item.category == .fullRecording {
                                    recordingVM.deleteFullRecording(sessionID: session.id)
                                } else {
                                    recordingVM.deleteClip(sessionID: session.id, clipID: item.clip.id)
                                }
                            },
                            onOpenPlayer: onOpenPlayer
                        )
                    }
                }
                .padding(.horizontal, 4)
                .onAppear {
                    checkOrientation()
                }
            }
        }
    }
    
    // 🌟 Detects if the video was shot in landscape
    private func checkOrientation() {
        guard let url = primaryClips.first?.fileURL else { return }
        Task {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                
                // ✏️ Added parentheses so they safely unwrap to non-optionals
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                
                let isLandscape = size.width > size.height
                let isPortraitTransform = (transform.a == 0 && abs(transform.b) == 1.0)
                let finalLandscape = isPortraitTransform ? !isLandscape : isLandscape
                
                await MainActor.run { self.isLandscapeSession = finalLandscape }
            }
        }
    }
    
    private func toggleSelection(_ clipID: UUID) {
        if selectedClipIDs.contains(clipID) { selectedClipIDs.remove(clipID) }
        else { selectedClipIDs.insert(clipID) }
    }
    
    private func toggleReelSelection(_ clipID: UUID) {
        if let index = selectedReelClipIDs.firstIndex(of: clipID) {
            selectedReelClipIDs.remove(at: index)
        } else {
            selectedReelClipIDs.append(clipID)
        }
    }
}

// MARK: - UnifiedGridCardView

private struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.3), value: configuration.isPressed)
    }
}

/// Thumbnail rendering is expensive. Keeping a small in-memory cache prevents
/// cards that return to the viewport from decoding the same video frame again.
private actor GalleryThumbnailRenderLimiter {
    static let shared = GalleryThumbnailRenderLimiter()
    private var activeRenders = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if activeRenders < 2 {
            activeRenders += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        } else {
            activeRenders -= 1
        }
    }
}

private enum GalleryThumbnailCache {
    nonisolated(unsafe) static let images = NSCache<NSURL, UIImage>()

    static func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    static func renderMidpoint(for url: URL) async -> UIImage? {
        if let cached = image(for: url) { return cached }

        // Fast scrolling can expose many cards at once. Limit the costly
        // frame decodes so they cannot contend with the scrolling renderer.
        await GalleryThumbnailRenderLimiter.shared.acquire()
        if let cached = image(for: url) {
            await GalleryThumbnailRenderLimiter.shared.release()
            return cached
        }

        let image: UIImage? = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return nil }

            let seconds = duration.seconds > 0 ? duration.seconds / 2 : 0.5
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 435)

            guard let cgImage = try? generator.copyCGImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600),
                actualTime: nil
            ) else { return nil }

            let image = UIImage(cgImage: cgImage)
            images.setObject(image, forKey: url as NSURL)
            return image
        }.value
        await GalleryThumbnailRenderLimiter.shared.release()
        return image
    }
}

private struct UnifiedGridCardView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    let sessionID: UUID
    let clip: Clip
    let category: ClipCategoryType
    let allClips: [Clip]
    let fullVideoURL: URL?
    let originalVideoDeletionDate: Date?
    let sessionDuration: TimeInterval
    
    let isSelectionMode: Bool
    let isSelected: Bool
    
    let isReelSelectionMode: Bool
    let isReelSelected: Bool
    let reelSelectionNumber: Int?
    /// The session determines this once. Individual thumbnails must not alter
    /// their card height as they load, which otherwise shifts the scroll view.
    let isLandscape: Bool
    
    let onSelectToggle: () -> Void
    let onReelSelectToggle: () -> Void
    let onDelete: () -> Void
    let onOpenPlayer: (ClipPlayerPresentation) -> Void
    
    @State private var thumbnail: UIImage? = nil
    @State private var showOriginalVideoRetentionInfo = false

    private var originalVideoTimeRemaining: TimeInterval? {
        guard category == .fullRecording, let deletionDate = originalVideoDeletionDate else { return nil }
        // Read the published clock so the card refreshes every minute, but use
        // the actual current time so a newly displayed card never starts from
        // a stale refresh timestamp.
        _ = recordingVM.retentionClock
        return max(0, deletionDate.timeIntervalSinceNow)
    }

    private var originalVideoRemainingLabel: String? {
        guard let timeRemaining = originalVideoTimeRemaining else { return nil }
        let day: TimeInterval = 24 * 60 * 60
        let hour: TimeInterval = 60 * 60

        if timeRemaining >= day {
            let days = max(1, Int(ceil(timeRemaining / day)))
            return "\(days)d"
        }

        // Once the countdown is under a day, never show 24h. The transition
        // should be 1d -> 23h.
        let hours = min(23, max(1, Int(ceil(timeRemaining / hour))))
        return "\(hours)h"
    }

    private var originalVideoTimerLeadingPadding: CGFloat {
        // The timer is an overlay, so reserve the same space used by the
        // selection circle and the favorite badge in the card's top row.
        let selectionPadding: CGFloat = (isSelectionMode || isReelSelectionMode) ? 28 : 0
        let favoritePadding: CGFloat = clip.isFavorite ? 34 : 0
        return 8 + selectionPadding + favoritePadding
    }
    
    var body: some View {
        let reelColor = Color.blueMarble
        
        Button {
            if isSelectionMode {
                withAnimation { onSelectToggle() }
            } else if isReelSelectionMode {
                withAnimation { onReelSelectToggle() }
            } else {
                onOpenPlayer(
                    ClipPlayerPresentation(
                        clips: allClips,
                        initialClipID: clip.id,
                        fullVideoURL: fullVideoURL,
                        sessionDuration: sessionDuration
                    )
                )
            }
        } label: {
            GeometryReader { geo in
                ZStack {
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color(white: 0.9))
                        ProgressView()
                            .tint(Color.cosmosBlue)
                    }
                    
                    VStack {
                        LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: geo.size.height * 0.25)
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                            .frame(height: geo.size.height * 0.6)
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            if isSelectionMode {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundColor(isSelected ? category.color : .white)
                                    .background(Circle().fill(Color.black.opacity(isSelected ? 0 : 0.4)))
                            } else if isReelSelectionMode {
                                if let reelSelectionNumber {
                                    Text("\(reelSelectionNumber)")
                                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                                        .foregroundColor(.white)
                                        .frame(width: 23, height: 23)
                                        .background(reelColor)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "circle")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.4)))
                                }
                            }
                            
                            if clip.isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color.crimsonBlaze)
                                    .padding(5)
                                    .background(Color.black.opacity(0.5))
                                    .clipShape(Circle())
                            }
                            
                            Spacer()
                            
                            if !isSelectionMode && !isReelSelectionMode {
                                Text(clip.durationLabel)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.65))
                                    .clipShape(Capsule())
                            }
                        }
                        
                        Spacer()
                        
                        Text(clip.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    }
                    .padding(6)
                }
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isReelSelectionMode && isReelSelected ? reelColor : category.color,
                            lineWidth: (isReelSelectionMode && isReelSelected) ? 6 : 4
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        // ✏️ Optional: increase opacity (e.g., 0.25) to make the background color accent more prominent
                        .fill(category.color.opacity(0.25))
                    )
            }
            // 🌟 1. Dynamic Aspect Ratio (Landscape vs Portrait)
            // Landscape matches the actual 16:9 recorded video ratio so scaledToFill()
            // no longer has to crop the sides to make up the difference.
            .aspectRatio(isLandscape ? 16.0 / 9.0 : 9/16, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle())
        .overlay(alignment: .topLeading) {
            if let remainingLabel = originalVideoRemainingLabel {
                Button {
                    showOriginalVideoRetentionInfo = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        Text(remainingLabel)
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.leading, originalVideoTimerLeadingPadding)
            }
        }
        .alert("Original Video Auto-Delete", isPresented: $showOriginalVideoRetentionInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            if let remainingLabel = originalVideoRemainingLabel {
                Text("Automatic deletion is enabled for this original video. It will be deleted in about \(remainingLabel) to save storage. Your saved highlights and reels will remain in the gallery.")
            } else {
                Text("Automatic deletion is enabled for original videos to save storage. Your saved highlights and reels remain in the gallery.")
            }
        }
        .onAppear { loadMidpointThumbnail() }
        .onChange(of: clip.fileURL) { _, newURL in
            if newURL != nil && thumbnail == nil {
                loadMidpointThumbnail()
            }
        }
        .onChange(of: recordingVM.currentExtractionProgress) {
            if thumbnail == nil {
                loadMidpointThumbnail()
            }
        }
        .onChange(of: recordingVM.isExtractingHighlights) { _, isExtracting in
            if !isExtracting && thumbnail == nil {
                loadMidpointThumbnail()
            }
        }
    }
    
    private func loadMidpointThumbnail() {
        guard let url = clip.fileURL, thumbnail == nil else { return }
        if let cached = GalleryThumbnailCache.image(for: url) {
            thumbnail = cached
            return
        }

        Task(priority: .utility) {
            var retries = 0
            while !FileManager.default.fileExists(atPath: url.path) && retries < 10 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                retries += 1
            }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            if let image = await GalleryThumbnailCache.renderMidpoint(for: url) {
                await MainActor.run {
                    // Do not animate or resize the card when an image
                    // arrives—both cause scrolling to visibly jump.
                    self.thumbnail = image
                }
            }
        }
    }
}

// MARK: - RenameClipSheet

struct RenameClipSheet: View {
    @Binding var editedTitle: String
    let onSave: (String) -> Void
    let onDismiss: () -> Void
    @FocusState private var titleIsFocused: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Rename Clip")
                    .font(.title3.bold())
                    .foregroundColor(Color.cosmosBlue)
                
                Spacer()
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.gray)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            TextField("Hype block, goal, rally, etc!", text: $editedTitle, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .textInputAutocapitalization(.words)
                .submitLabel(.return)
                .focused($titleIsFocused)
                .onSubmit { saveTitle() }
                .font(.system(size: 16, weight: .semibold))
                .padding(12)
                .background(Color(white: 0.95))
                .cornerRadius(12)
                .foregroundColor(.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(white: 0.8), lineWidth: 1)
                )
            
            HStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(white: 0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Button {
                    saveTitle()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.crimsonBlaze)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 15, x: 0, y: 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                titleIsFocused = true
            }
        }
    }

    private func saveTitle() {
        let clean = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            onSave(clean)
        }
        onDismiss()
    }
}

// MARK: - Rename Session Sheet

struct RenameSessionSheet: View {
    let sessionName: String
    @Binding var draftName: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameIsFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Rename Session")
                    .font(.title2.bold())
                    .foregroundColor(Color.cosmosBlue)
                    .padding(.top, 20)
                
                TextField("Session Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium))
                    .submitLabel(.return)
                    .focused($nameIsFocused)
                    .onSubmit { onSave() }
                    .padding(.horizontal, 20)
                
                HStack(spacing: 12) {
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color(white: 0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        onSave()
                    } label: {
                        Text("Save")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.crimsonBlaze)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                
                Spacer()
            }
            .background(Color.white.ignoresSafeArea())
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                nameIsFocused = true
            }
        }
    }
}
