//
//  ClipsView.swift
//  Clipit
//

import SwiftUI
import AVFoundation
import UIKit

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
        case .all: return "square.grid.3x1.below.line.grid.1x2.fill"
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
    let isSelected: Bool
    @EnvironmentObject private var tutorial: TutorialController
    @EnvironmentObject var recordingVM: RecordingViewModel
    
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
    @State private var waitingForInitialLibraryContent = false
    @State private var isReturningToReelSelection = false
    @State private var scrollOffsetAdjustment: LibraryOffsetAdjustment?
    @State private var scrollPosition = LibraryScrollPositionReader()
    @State private var liftBottomRowForSelection = false
    @State private var layoutTracker = LibraryScrollLayoutTracker()
    @State private var layoutRefreshToken = 0

    private let selectionBarHeight: CGFloat = 44
    private let selectionBottomAnchor = "ClipLibrarySelectionBottom"

    private var selectionSummaryText: String {
        let count = selectedClipIDs.count
        return "\(count) \(count == 1 ? "clip" : "clips") selected"
    }
    
    private var dynamicColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    private var visibleSessions: [Session] {
        let savedSessions: [Session]
        switch selectedFilter {
        case .favorites:
            savedSessions = recordingVM.sessions.filter { session in
                session.clips.contains { $0.isFavorite }
            }
        case .fullRecordings:
            savedSessions = recordingVM.sessions.filter { session in
                guard let url = session.fullVideoURL,
                      FileManager.default.fileExists(atPath: url.path) else { return false }
                return session.clips.contains {
                    $0.highlightIndex == nil && !$0.isReel && !$0.isSecondaryAngle
                }
            }
        default:
            savedSessions = recordingVM.sessions
        }

        guard let session = recordingVM.currentSession,
              session.isProcessing,
              session.endedAt != nil,
              !savedSessions.contains(where: { $0.id == session.id }) else { return savedSessions }

        switch selectedFilter {
        case .all, .fullRecordings:
            return savedSessions + [session]
        case .highlights:
            return session.highlights.isEmpty ? savedSessions : savedSessions + [session]
        case .favorites:
            return session.clips.contains(where: \.isFavorite) ? savedSessions + [session] : savedSessions
        case .reels:
            return savedSessions
        }
    }

    private var orderedVisibleSessions: [Session] {
        visibleSessions.sorted { $0.startedAt < $1.startedAt }
    }

    private var visibleContentIDs: [UUID] {
        selectedFilter == .reels
            ? reelsInChronologicalOrder.map(\.clip.id)
            : orderedVisibleSessions.map(\.id)
    }

    private var reelsInChronologicalOrder: [(clip: Clip, sessionID: UUID, fullVideoURL: URL?, duration: TimeInterval, sessionStartedAt: Date)] {
        recordingVM.sessions.flatMap { session in
            session.clips
                .filter { $0.isReel || $0.displayName.contains("Highlight Reel") || $0.displayName.contains("Set") }
                .map { (clip: $0, sessionID: session.id, fullVideoURL: session.fullVideoURL, duration: session.duration, sessionStartedAt: session.startedAt) }
        }
        .sorted {
            if $0.sessionStartedAt != $1.sessionStartedAt {
                return $0.sessionStartedAt < $1.sessionStartedAt
            }
            return $0.clip.triggeredAt < $1.clip.triggeredAt
        }
    }

    private func scrollToNewest(using proxy: ScrollViewProxy, for filter: ClipFilter? = nil) {
        let filterBeingDisplayed = filter ?? selectedFilter
        let newestContentID = visibleContentIDs.last
        DispatchQueue.main.async {
            guard selectedFilter == filterBeingDisplayed,
                  let newestContentID else { return }
            proxy.scrollTo(newestContentID, anchor: .bottom)
        }
    }

    private func selectFilter(_ filter: ClipFilter) {
        guard filter != selectedFilter else { return }
        layoutTracker.reset()
        withTransaction(Transaction(animation: nil)) {
            selectedFilter = filter
        }
    }

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section(header: stickyTopHeader) {
                                if visibleSessions.isEmpty {
                                    emptyState
                                } else if selectedFilter == .reels {
                                    if reelsInChronologicalOrder.isEmpty {
                                        emptyReelsState
                                    } else {
                                        flattenedReelsGrid
                                            .padding(.top, 8)
                                    }
                                } else {
                                    ForEach(Array(orderedVisibleSessions.enumerated()), id: \.element.id) { index, session in
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
                                        .id(session.id)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: LibraryScrollLayoutPreferenceKey.self,
                                                    value: LibraryScrollLayoutSnapshot(itemFrames: [
                                                        session.id: geometry.frame(in: .named("ClipLibraryScroll"))
                                                    ])
                                                )
                                            }
                                        }

                                        if selectedFilter != .reels && index < orderedVisibleSessions.count - 1 {
                                            Rectangle()
                                                .fill(Color.cosmosBlue)
                                                .frame(height: 5)
                                        }
                                    }
                                }
                            }
                            if isSelectionMode {
                                Color.clear
                                    .frame(height: selectionBarHeight)
                                    .id(selectionBottomAnchor)
                            }
                        }
                        .background {
                            LibraryScrollOffsetAdjuster(
                                adjustment: $scrollOffsetAdjustment,
                                positionReader: scrollPosition
                            )
                                .allowsHitTesting(false)
                        }
                        .background(Color.white)
                    }
                    .coordinateSpace(name: "ClipLibraryScroll")
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: LibraryScrollLayoutPreferenceKey.self,
                                value: LibraryScrollLayoutSnapshot(
                                    viewportSize: geometry.size,
                                    refreshToken: layoutRefreshToken
                                )
                            )
                        }
                    }
                    .onPreferenceChange(LibraryScrollLayoutPreferenceKey.self) { snapshot in
                        layoutTracker.update(
                            snapshot,
                            using: scrollProxy,
                            applyOffsetAdjustment: { scrollOffsetAdjustment = $0 },
                            requestLayoutRefresh: { layoutRefreshToken &+= 1 }
                        )
                    }
                    .onAppear {
                        if isSelected {
                            waitingForInitialLibraryContent = visibleContentIDs.isEmpty
                            if !waitingForInitialLibraryContent {
                                scrollToNewest(using: scrollProxy)
                            }
                        }
                    }
                    .onChange(of: visibleContentIDs) { _, contentIDs in
                        guard isSelected, waitingForInitialLibraryContent,
                              !contentIDs.isEmpty else { return }
                        waitingForInitialLibraryContent = false
                        scrollToNewest(using: scrollProxy, for: selectedFilter)
                    }
                    .onChange(of: isSelected) { _, selected in
                        if selected {
                            waitingForInitialLibraryContent = visibleContentIDs.isEmpty
                            if !waitingForInitialLibraryContent {
                                // TabView can create the Library offscreen during
                                // app startup. Scroll only once its tab is visible.
                                layoutTracker.reset()
                                scrollToNewest(using: scrollProxy)
                            }
                        } else {
                            waitingForInitialLibraryContent = false
                        }
                    }
                    .onChange(of: selectedFilter) { _, newFilter in
                        scrollToNewest(using: scrollProxy, for: newFilter)
                    }
                    .onChange(of: isSelectionMode) { _, selecting in
                        guard selecting, liftBottomRowForSelection else { return }
                        liftBottomRowForSelection = false
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scrollProxy.scrollTo(selectionBottomAnchor, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: tutorial.step) { _, step in
                        if step == .reel { selectFilter(.highlights) }
                    }
                }
                .navigationTitle("ClipIt Library")
                .navigationBarTitleDisplayMode(.large)
                .toolbarTitleDisplayMode(.large)
                .onChange(of: recordingVM.pendingHighlightToOpen) { _, newValue in
                    if newValue != nil {
                        withAnimation { selectFilter(.highlights) }
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
                        },
                        onRename: { clip, name in
                            var updatedClip = clip
                            updatedClip.customName = name
                            recordingVM.updateClip(updatedClip)
                        }
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if !recordingVM.sessions.isEmpty && !isReelSelectionMode {
                            Button(isSelectionMode ? "Cancel" : "Select") {
                                let shouldLift = !isSelectionMode && scrollPosition.isAtBottom
                                withTransaction(Transaction(animation: nil)) {
                                    liftBottomRowForSelection = shouldLift
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
                                withTransaction(Transaction(animation: nil)) {
                                    isReelSelectionMode = false
                                    selectedReelClipIDs.removeAll()
                                }
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(Color.cosmosBlue)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if isSelectionMode {
                        selectionBottomBar
                    }
                }
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
                .sheet(isPresented: $showCreateReelSheet, onDismiss: {
                    if isReturningToReelSelection {
                        isReturningToReelSelection = false
                        selectFilter(.highlights)
                        isReelSelectionMode = true
                    } else {
                        resetReelSelection()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectFilter(.reels)
                        }
                    }
                }) {
                    CreateReelSheet(
                        targetSessionID: getMostRecentSelectedReelSessionID(),
                        selectedClips: getSelectedReelClips(),
                        onBack: {
                            isReturningToReelSelection = true
                            showCreateReelSheet = false
                        }
                    )
                }
            }
            .preferredColorScheme(.light)
            
            if recordingVM.isExtractingHighlights {
                extractionOverlay
            }
        }
        .animation(.easeInOut(duration: 0.3), value: recordingVM.isExtractingHighlights)
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
    
    // MARK: - Sticky Top Filter & Action Bar
    
    private var stickyTopHeader: some View {
        VStack(spacing: 0) {
            if !recordingVM.sessions.isEmpty || tutorial.step == .library || tutorial.step == .reel {
                pillFilterBar
                    .padding(.vertical, 8)
                    .tutorialTarget(.library)
            }
            
            // Keep its space stable in selection mode so the scroll content
            // doesn't shift when its action changes.
            if selectedFilter != .all && (!recordingVM.sessions.isEmpty || tutorial.step == .reel) {
                Group {
                    if isReelSelectionMode {
                        reelSelectionActionBanner
                    } else {
                        createReelQuickBanner
                    }
                }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .opacity(isSelectionMode ? 0 : 1)
                    .allowsHitTesting(!isSelectionMode)
            }
        }
        .background(Color.white)
    }
    
    private var createReelQuickBanner: some View {
        Button {
            withTransaction(Transaction(animation: nil)) {
                selectFilter(.highlights) // 🎯 Automatically routes to Highlights tab
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
        .tutorialTarget(.reel)
    }

    private var reelSelectionActionBanner: some View {
        Button {
            showCreateReelSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "movieclapper.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("Create Reel (\(selectedReelClipIDs.count))")
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
                    colors: [Color.crimsonBlaze, Color.blueMarble],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.blueMarble.opacity(0.4), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(selectedReelClipIDs.isEmpty)
        .opacity(selectedReelClipIDs.isEmpty ? 0.55 : 1)
    }
    
    private var pillFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClipFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    Button {
                        // Reset selection state as needed, but don't animate the
                        // gallery's entire lazy stack while replacing its contents.
                        if isReelSelectionMode && filter != .highlights {
                            resetReelSelection()
                        }
                        selectFilter(filter)
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
        let allReels = reelsInChronologicalOrder
        
        return LazyVGrid(columns: dynamicColumns, spacing: 2) {
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
                    onSelectToggle: { toggleSelection(item.clip.id) },
                    onReelSelectToggle: { toggleReelSelection(item.clip.id) },
                    onDelete: { recordingVM.deleteClip(sessionID: item.sessionID, clipID: item.clip.id) },
                    onOpenPlayer: { playerPresentation = $0 }
                )
                .id(item.clip.id)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: LibraryScrollLayoutPreferenceKey.self,
                            value: LibraryScrollLayoutSnapshot(
                                itemFrames: [item.clip.id: geometry.frame(in: .named("ClipLibraryScroll"))],
                                clipIDs: [item.clip.id]
                            )
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
    
    private var selectionBottomBar: some View {
        HStack {
            Button(action: shareSelectedClips) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 20, weight: .semibold))
            }.disabled(selectedClipIDs.isEmpty)
            Spacer()
            Text(selectionSummaryText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityLabel(selectionSummaryText)
            Spacer()
            Button(action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash").font(.system(size: 20, weight: .semibold))
                    .foregroundColor(selectedClipIDs.isEmpty ? .gray : Color.crimsonBlaze)
            }.disabled(selectedClipIDs.isEmpty)
        }
        .padding(.horizontal, 28)
        .frame(height: selectionBarHeight)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Color(UIColor.separator)), alignment: .top)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack").font(.system(size: 48)).foregroundColor(.gray)
            Text("No Memorable Moments Yet").font(.title3.bold()).foregroundColor(Color.cosmosBlue)
            Text("Head to Record to start capturing highlights.").font(.subheadline).foregroundColor(.gray).multilineTextAlignment(.center)
        }.padding(.top, 100)
    }

    private var emptyReelsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "movieclapper")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("No Reels Yet")
                .font(.title3.bold())
                .foregroundColor(Color.cosmosBlue)
            Text("Create a reel from your highlights to see it here.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
    
    private func resetSelection() {
        withTransaction(Transaction(animation: nil)) {
            isSelectionMode = false
            selectedClipIDs.removeAll()
        }
    }
    
    private func resetReelSelection() {
        withTransaction(Transaction(animation: nil)) {
            isReelSelectionMode = false
            selectedReelClipIDs.removeAll()
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

    private func getMostRecentSelectedReelSessionID() -> UUID? {
        let selectedSessionIDs = Set(getSelectedReelClips().map(\.sessionID))
        return recordingVM.sessions
            .filter { selectedSessionIDs.contains($0.id) }
            .max { $0.startedAt < $1.startedAt }?
            .id
    }

}

private struct LibraryScrollLayoutSnapshot: Equatable {
    var viewportSize: CGSize = .zero
    var refreshToken = 0
    var itemFrames: [UUID: CGRect] = [:]
    var clipIDs = Set<UUID>()
    var parentSessionIDs: [UUID: UUID] = [:]

    init(
        viewportSize: CGSize = .zero,
        refreshToken: Int = 0,
        itemFrames: [UUID: CGRect] = [:],
        clipIDs: Set<UUID> = [],
        parentSessionIDs: [UUID: UUID] = [:]
    ) {
        self.viewportSize = viewportSize
        self.refreshToken = refreshToken
        self.itemFrames = itemFrames
        self.clipIDs = clipIDs
        self.parentSessionIDs = parentSessionIDs
    }
}

private struct LibraryScrollLayoutPreferenceKey: PreferenceKey {
    static var defaultValue = LibraryScrollLayoutSnapshot()

    static func reduce(value: inout LibraryScrollLayoutSnapshot, nextValue: () -> LibraryScrollLayoutSnapshot) {
        let next = nextValue()
        if next.viewportSize != .zero {
            value.viewportSize = next.viewportSize
        }
        value.refreshToken = max(value.refreshToken, next.refreshToken)
        value.itemFrames.merge(next.itemFrames) { _, new in new }
        value.clipIDs.formUnion(next.clipIDs)
        value.parentSessionIDs.merge(next.parentSessionIDs) { _, new in new }
    }
}

private struct LibraryOffsetAdjustment: Equatable {
    let id = UUID()
    let points: CGFloat
}

private final class LibraryScrollLayoutTracker {
    private struct Anchor {
        let id: UUID
        let parentSessionID: UUID?
        let fractionWithinItem: CGFloat
        let fractionWithinViewport: CGFloat
    }

    private var previousSnapshot = LibraryScrollLayoutSnapshot()
    private var pendingAnchor: Anchor?
    private var lastScrollTo = Date.distantPast
    private var lastLayoutChange = Date.distantPast
    private var pendingSince = Date.distantPast
    private var retryWork: DispatchWorkItem?

    func reset() {
        retryWork?.cancel()
        retryWork = nil
        pendingAnchor = nil
        lastScrollTo = .distantPast
    }

    func update(
        _ snapshot: LibraryScrollLayoutSnapshot,
        using proxy: ScrollViewProxy,
        applyOffsetAdjustment: @escaping (LibraryOffsetAdjustment) -> Void,
        requestLayoutRefresh: @escaping () -> Void
    ) {
        let oldSize = previousSnapshot.viewportSize
        // The navigation bar changes the viewport height while scrolling.
        // Rotation changes its width, so only width can begin a restore.
        let widthChanged = oldSize.width > 0 &&
            abs(oldSize.width - snapshot.viewportSize.width) > 20

        if widthChanged {
            if pendingAnchor == nil {
                pendingAnchor = visibleAnchor(in: previousSnapshot)
                pendingSince = Date()
                lastScrollTo = .distantPast
            }
            lastLayoutChange = Date()
        }

        previousSnapshot = snapshot
        guard let pendingAnchor else { return }
        // A clip can disappear while a filter or the library data changes.
        // Never let an orphaned rotation anchor affect a later scroll.
        if Date().timeIntervalSince(pendingSince) > 4 {
            reset()
            return
        }

        if let frame = snapshot.itemFrames[pendingAnchor.id], snapshot.viewportSize.height > 0 {
            let itemPoint = frame.minY + pendingAnchor.fractionWithinItem * frame.height
            let viewportPoint = pendingAnchor.fractionWithinViewport * snapshot.viewportSize.height
            let correction = itemPoint - viewportPoint

            if abs(correction) > 0.75 {
                applyOffsetAdjustment(LibraryOffsetAdjustment(points: correction))
            } else if Date().timeIntervalSince(lastLayoutChange) >= 0.45 {
                reset()
                return
            }
        } else if Date().timeIntervalSince(lastScrollTo) > 0.12 {
            lastScrollTo = Date()
            let anchor = pendingAnchor
            DispatchQueue.main.async { [weak self] in
                guard self?.pendingAnchor?.id == anchor.id else { return }
                withTransaction(Transaction(animation: nil)) {
                    if let sessionID = anchor.parentSessionID {
                        proxy.scrollTo(sessionID, anchor: .center)
                        DispatchQueue.main.async { [weak self] in
                            guard self?.pendingAnchor?.id == anchor.id else { return }
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(anchor.id, anchor: .center)
                            }
                        }
                    } else {
                        proxy.scrollTo(anchor.id, anchor: .center)
                    }
                }
            }
        }

        // Preference changes can stop once UIKit's rotation animation ends.
        // Keep checking briefly without requiring a tap or a drag to wake layout.
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.pendingAnchor != nil else { return }
            requestLayoutRefresh()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func visibleAnchor(in snapshot: LibraryScrollLayoutSnapshot) -> Anchor? {
        let midpoint = snapshot.viewportSize.height * 0.5
        let visible = snapshot.itemFrames
            .filter { $0.value.maxY > 0 && $0.value.minY < snapshot.viewportSize.height }
        let visibleClips = visible.filter { snapshot.clipIDs.contains($0.key) }
        let candidates = visibleClips.isEmpty ? visible : visibleClips

        guard let chosen = candidates.min(by: { lhs, rhs in
            let leftDistance = lhs.value.minY <= midpoint && lhs.value.maxY >= midpoint
                ? 0 : min(abs(lhs.value.minY - midpoint), abs(lhs.value.maxY - midpoint))
            let rightDistance = rhs.value.minY <= midpoint && rhs.value.maxY >= midpoint
                ? 0 : min(abs(rhs.value.minY - midpoint), abs(rhs.value.maxY - midpoint))
            return leftDistance < rightDistance
        }) else { return nil }

        let pointInItem = min(max(midpoint, chosen.value.minY), chosen.value.maxY)
        return Anchor(
            id: chosen.key,
            parentSessionID: snapshot.parentSessionIDs[chosen.key],
            fractionWithinItem: chosen.value.height > 0
                ? (pointInItem - chosen.value.minY) / chosen.value.height : 0.5,
            fractionWithinViewport: snapshot.viewportSize.height > 0
                ? pointInItem / snapshot.viewportSize.height : 0.5
        )
    }
}

/// Moves the underlying scroll view only when the tracked clip moves during
/// rotation. Each request has an identity so an older callback cannot clear a
/// newer correction.
private final class LibraryScrollPositionReader {
    weak var scrollView: UIScrollView?

    var isAtBottom: Bool {
        guard let scrollView else { return false }
        let maximumOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        return maximumOffset - scrollView.contentOffset.y <= 8
    }
}

private final class LibraryScrollMarkerView: UIView {
    var onAttach: (() -> Void)?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.onAttach?() }
    }
}

private struct LibraryScrollOffsetAdjuster: UIViewRepresentable {
    @Binding var adjustment: LibraryOffsetAdjustment?
    let positionReader: LibraryScrollPositionReader

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LibraryScrollMarkerView {
        let marker = LibraryScrollMarkerView(frame: .zero)
        marker.isUserInteractionEnabled = false
        marker.onAttach = { [weak marker, weak positionReader] in
            guard let marker else { return }
            positionReader?.scrollView = Coordinator.scrollView(from: marker)
        }
        return marker
    }

    func updateUIView(_ marker: LibraryScrollMarkerView, context: Context) {
        DispatchQueue.main.async {
            positionReader.scrollView = Coordinator.scrollView(from: marker)
            guard let requestedAdjustment = adjustment else { return }
            guard self.adjustment?.id == requestedAdjustment.id else { return }
            if context.coordinator.adjustScrollOffset(by: requestedAdjustment.points, from: marker) {
                self.adjustment = nil
            }
        }
    }

    final class Coordinator {
        static func scrollView(from marker: UIView) -> UIScrollView? {
            var ancestor = marker.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView { return scrollView }
                ancestor = view.superview
            }
            return nil
        }

        func adjustScrollOffset(by adjustment: CGFloat, from marker: UIView) -> Bool {
            guard let scrollView = Self.scrollView(from: marker) else { return false }
            let maximumOffset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let newY = min(
                maximumOffset,
                max(-scrollView.adjustedContentInset.top, scrollView.contentOffset.y + adjustment)
            )
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: newY),
                animated: false
            )
            return true
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
        
        // Marked highlights already exist in the session, but their video
        // files arrive one by one. Keep their cells empty until playable.
        return list
            .filter { !session.isProcessing || $0.clip.fileURL != nil }
            .sorted { $0.clip.triggeredAt < $1.clip.triggeredAt }
    }

    private var emptyProcessingCells: Int {
        guard session.isProcessing else { return 0 }
        let remainder = filteredClipsWithCategories.count % 3
        return filteredClipsWithCategories.isEmpty ? 3 : (remainder == 0 ? 0 : 3 - remainder)
    }
    
    private var dynamicColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            if selectedFilter != .reels {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            renameDraft = session.name
                            sessionBeingRenamed = session
                        } label: {
                            HStack(spacing: 8) {
                                Text(session.name)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(Color.cosmosBlue)

                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(Color.gochujangRed)
                                    .frame(width: 22, height: 22)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("\(session.formattedDate)  •  \(session.durationLabel)")
                            .font(.caption)
                            .foregroundColor(.cosmosBlue)
                    }
                    
                    Spacer()
                    
                    Group {
                        if isSelectionMode {
                            Button(role: .destructive) { sessionToDelete = session } label: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(Color.crimsonBlaze)
                                    .padding(10)
                                    .background(Color.crimsonBlaze.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .frame(width: 36, height: 36)
                        } else {
                            Color.clear.frame(width: 36, height: 36)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            if session.isProcessing && !clippedHighlights.isEmpty &&
                (selectedFilter == .all || selectedFilter == .highlights) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.crimsonBlaze)
                    Text("Processing highlights…")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            
            if !filteredClipsWithCategories.isEmpty || emptyProcessingCells > 0 {
                LazyVGrid(columns: dynamicColumns, spacing: 2) {
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
                        .id(item.clip.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: LibraryScrollLayoutPreferenceKey.self,
                                    value: LibraryScrollLayoutSnapshot(
                                        itemFrames: [item.clip.id: geometry.frame(in: .named("ClipLibraryScroll"))],
                                        clipIDs: [item.clip.id],
                                        parentSessionIDs: [item.clip.id: session.id]
                                    )
                                )
                            }
                        }
                    }
                    ForEach(0..<emptyProcessingCells, id: \.self) { _ in
                        Color.white
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 4)
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
            } else if clip.fileURL != nil {
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
            .contentShape(Rectangle())
        }
        // Size the complete grid cell as a square so every reel row uses the
        // same dimensions, including a partially filled newest row.
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
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
            Button("Disable Auto-Delete", role: .destructive) {
                recordingVM.disableOriginalVideoAutoDelete(sessionID: sessionID)
            }
            Button("OK", role: .cancel) { }
        } message: {
            if let remainingLabel = originalVideoRemainingLabel {
                Text("Automatic deletion is enabled for this original video. It will be deleted in about \(remainingLabel) to save storage. Disable auto-delete to keep this original video. Your saved highlights and reels will remain in the gallery.")
            } else {
                Text("Automatic deletion is enabled for original videos to save storage. Disable auto-delete to keep this original video. Your saved highlights and reels remain in the gallery.")
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

@MainActor
enum RenameFieldSelection {
    static func selectAllWhenFocused(_ expectedText: String, attemptsRemaining: Int = 8) {
        guard attemptsRemaining > 0 else { return }

        DispatchQueue.main.async {
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow })

            if let keyWindow,
               let input = focusedTextInput(in: keyWindow),
               let fullRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
               input.text(in: fullRange) == expectedText {
                input.selectedTextRange = fullRange
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    selectAllWhenFocused(expectedText, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    private static func focusedTextInput(in view: UIView) -> UITextInput? {
        if view.isFirstResponder, let input = view as? UITextInput {
            return input
        }
        for child in view.subviews {
            if let input = focusedTextInput(in: child) {
                return input
            }
        }
        return nil
    }
}

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
                RenameFieldSelection.selectAllWhenFocused(editedTitle)
            }
        }
        .onChange(of: titleIsFocused) { _, focused in
            if focused {
                RenameFieldSelection.selectAllWhenFocused(editedTitle)
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
                RenameFieldSelection.selectAllWhenFocused(draftName)
            }
        }
        .onChange(of: nameIsFocused) { _, focused in
            if focused {
                RenameFieldSelection.selectAllWhenFocused(draftName)
            }
        }
    }
}
