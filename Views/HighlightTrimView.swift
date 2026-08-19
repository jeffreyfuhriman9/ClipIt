import SwiftUI
import AVKit
import AVFoundation

struct HighlightTrimView: View {
    let clip: Clip
    let fullVideoURL: URL
    let sessionDuration: TimeInterval
    let onSave: (Clip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trimStart: Double
    @State private var trimEnd: Double
    @State private var playheadTime: Double
    @State private var draggingTime: Double?
    @State private var isExporting = false
    @State private var exportProgress: String = ""
    @State private var previewPlayer: AVPlayer?
    @State private var title: String
    @State private var timeObserver: Any?
    @State private var isDraggingTimeline = false
    @State private var isPreviewPlaying = true
    @State private var loadedSourceDuration: Double = 0
    @State private var wasPlayingBeforeDrag = false
    @State private var dragStartTrimStart: Double?
    @State private var dragStartTrimEnd: Double?
    
    // Zoomed Window Drag Anchors
    @State private var dragStartWindowStart: Double?
    @State private var dragStartWindowEnd: Double?
    
    @Environment(\.verticalSizeClass) var verticalSizeClass
    
    init(clip: Clip, fullVideoURL: URL, sessionDuration: TimeInterval, onSave: @escaping (Clip) -> Void) {
        self.clip = clip
        self.fullVideoURL = fullVideoURL
        self.sessionDuration = sessionDuration
        self.onSave = onSave

        let initialStart = clip.sourceStartTime ?? 0
        let initialEnd = clip.sourceEndTime ?? max(clip.duration, 1)

        _trimStart = State(initialValue: initialStart)
        _trimEnd = State(initialValue: max(initialEnd, initialStart + 5.0))
        _playheadTime = State(initialValue: initialStart)
        _draggingTime = State(initialValue: nil)
        _title = State(initialValue: clip.customTitle ?? clip.displayName)
    }

    private var sourceURL: URL {
        clip.sourceVideoURL ?? clip.fileURL ?? fullVideoURL
    }

    private var sourceDuration: Double {
        max(loadedSourceDuration, sessionDuration, clip.duration, 1)
    }

    private var videoDuration: Double {
        sourceDuration
    }
    
    private var clipStart: Double {
        min(trimStart, max(0, trimEnd - 0.5))
    }
    
    private var clipEnd: Double {
        max(trimEnd, min(videoDuration, trimStart + 0.5))
    }

    private var totalLength: Double {
        clipEnd - clipStart
    }

    private var displayedTime: Double {
        draggingTime ?? playheadTime
    }

    private var previewURL: URL {
        sourceURL
    }

    // MARK: - Two-Tier Window Math
    
    private var windowPadding: Double { 15.0 } // 15s padding on left and right
    
    private var activeWindowStart: Double {
        if let locked = dragStartWindowStart { return locked }
        return max(0, trimStart - windowPadding)
    }

    private var activeWindowEnd: Double {
        if let locked = dragStartWindowEnd { return locked }
        return min(videoDuration, trimEnd + windowPadding)
    }

    private var activeWindowSpan: Double {
        max(activeWindowEnd - activeWindowStart, 1.0)
    }

    // MARK: - Main Body

    var body: some View {
        let isLandscape = verticalSizeClass == .compact
        
        NavigationStack {
            ZStack {
                Color.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    previewArea
                        .frame(maxHeight: isLandscape ? .infinity : 420)
                        .layoutPriority(1)

                    timestampInfo
                        .padding(.vertical, isLandscape ? 4 : 10)

                    // TWO-TIER TIMELINE CONTROLS
                    VStack(spacing: 8) {
                        // 1. MACRO OVERVIEW BAR (Full Game context)
                        macroTimeline
                            .frame(height: 18)

                        // 2. MICRO ZOOMED BAR (Fine handle editing)
                        appleStyleTrimControl
                    }
                    .padding(.horizontal, isLandscape ? 48 : 20)
                    .padding(.bottom, isLandscape ? 6 : 14)
                    .padding(.top, isLandscape ? 2 : 6)

                    Divider()
                        .overlay(Color(white: 0.2))

                    if !isLandscape {
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 13))
                            .foregroundColor(.cosmosBlue)
                        Text("Clip duration: \(formatPreciseTime(totalLength))")
                            .font(.subheadline)
                            .foregroundColor(.cosmosBlue)
                    }
                    .padding(.top, isLandscape ? 6 : 0)
                    .padding(.bottom, isLandscape ? 8 : 18)
                }
            }
            .navigationTitle(liveDisplayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.light)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        previewPlayer?.pause()
                        previewPlayer?.replaceCurrentItem(with: nil)
                        previewPlayer = nil
                        dismiss()
                    }
                    .foregroundColor(.cosmosBlue.opacity(0.85))
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isExporting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                            Text(exportProgress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if clip.highlightIndex == nil {
                        // 🌟 ONLY ON FULL RECORDINGS: Dropdown menu with 2 options
                        Menu {
                            Button {
                                exportClip(asNewClip: false)
                            } label: {
                                Label("Save Video", systemImage: "video.badge.checkmark")
                            }

                            Button {
                                exportClip(asNewClip: true)
                            } label: {
                                Label("Save Video as New Clip", systemImage: "video.badge.plus")
                            }
                        } label: {
                            Text("Save")
                                .fontWeight(.semibold)
                                .foregroundColor(.crimsonBlaze)
                        }
                    } else {
                        // Standard clip save (when editing an already extracted highlight)
                        Button("Save") {
                            exportClip(asNewClip: false)
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(.crimsonBlaze)
                    }
                }
            }
        }
        .onAppear {
            loadSourceDurationIfNeeded()
            playheadTime = clipStart
            setupPreview()
        }
        .onChange(of: trimStart) { _, _ in
            if playheadTime < clipStart {
                playheadTime = clipStart
            }
        }
        .onChange(of: trimEnd) { _, _ in
            if playheadTime > clipEnd {
                playheadTime = clipEnd
            }
        }
        .onDisappear {
            removeTimeObserver()
            previewPlayer?.pause()
            previewPlayer?.replaceCurrentItem(with: nil)
            previewPlayer = nil
        }
    }
    
    private var previewArea: some View {
        ZStack {
            Color(white: 0.06)

            if let player = previewPlayer {
                CustomVideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    // MARK: - 1. MACRO TIMELINE (Full Recording Overview Bar)
    
    private var macroTimeline: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(videoDuration, 1)

            let winStartX = CGFloat(activeWindowStart / total) * width
            let winEndX = CGFloat(activeWindowEnd / total) * width
            let winWidth = max(4, winEndX - winStartX)

            let clipStartX = CGFloat(trimStart / total) * width
            let clipEndX = CGFloat(trimEnd / total) * width
            let clipWidth = max(2, clipEndX - clipStartX)

            let playheadX = CGFloat(displayedTime / total) * width

            ZStack(alignment: .leading) {
                // Background Track (Full Video)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.22))
                    .frame(height: 14)

                // Yellow Clip Region relative to full recording
                Rectangle()
                    .fill(Color.yellow)
                    .frame(width: clipWidth, height: 14)
                    .offset(x: clipStartX)

                // White Bounding Box (Shows where the Zoomed Micro Window is)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.white, lineWidth: 1.5)
                    .background(Color.white.opacity(0.15))
                    .frame(width: winWidth, height: 16)
                    .offset(x: winStartX)

                // Mini Playhead indicator
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 18)
                    .offset(x: playheadX - 1)
            }
            .contentShape(Rectangle())
            // Tap/Drag on Macro bar jumps the clip window anywhere in the video!
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginDragging()
                        let clampedX = max(0, min(width, value.location.x))
                        let norm = clampedX / width
                        let targetTime = Double(norm) * total
                        
                        let currentLen = totalLength
                        let newStart = max(0, min(targetTime - currentLen / 2, videoDuration - currentLen))
                        let newEnd = min(videoDuration, newStart + currentLen)
                        
                        trimStart = newStart
                        trimEnd = newEnd
                        playheadTime = newStart
                        draggingTime = newStart
                        seekPreview(to: newStart)
                    }
                    .onEnded { _ in
                        endDragging(keepPaused: true)
                    }
            )
        }
    }

    // MARK: - 2. MICRO TIMELINE (Zoomed High-Resolution Handle View)

    private var appleStyleTrimControl: some View {
        HStack(spacing: 0) {
            Button {
                togglePreviewPlayback()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.clear)
                        .frame(width: 64, height: 64)

                    Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.crimsonBlaze)
                }
            }
            .buttonStyle(.plain)
            
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 2, height: 64)
                .padding(.trailing, 10)

            microTrimBar
                .frame(height: 64)
                .padding(.trailing, 12)
        }
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.75))
        )
    }

    private var microTrimBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let wStart = activeWindowStart
            let wSpan = activeWindowSpan

            // Convert trim times into local Zoomed Window space
            let startX = CGFloat((trimStart - wStart) / wSpan) * width
            let endX = CGFloat((trimEnd - wStart) / wSpan) * width
            let selectionWidth = max(0, endX - startX)
            let playheadX = CGFloat((displayedTime - wStart) / wSpan) * width

            ZStack(alignment: .topLeading) {
                // Timeline Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.32))
                    .frame(height: 52)
                    .offset(y: 6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                beginDragging()

                                let clampedX = max(0, min(width, value.location.x))
                                let normalized = clampedX / width
                                let newTime = max(trimStart, min(trimEnd, wStart + Double(normalized) * wSpan))

                                playheadTime = newTime
                                draggingTime = newTime
                                seekPreview(to: newTime)
                            }
                            .onEnded { _ in
                                endDragging(keepPaused: true)
                            }
                    )

                // Dimmed Left Non-Selected Area
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: max(0, startX), height: 52)
                    .offset(x: 0, y: 6)

                // Dimmed Right Non-Selected Area
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: max(0, width - endX), height: 52)
                    .offset(x: endX, y: 6)

                // Yellow Connected Trim Border
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.yellow, lineWidth: 6)
                    .frame(width: selectionWidth, height: 52)
                    .offset(x: startX, y: 6)

                // Left Yellow Handle
                appleHandle(direction: .left)
                    .offset(x: startX - 6, y: 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                beginDragging()

                                if dragStartTrimStart == nil {
                                    dragStartTrimStart = trimStart
                                    dragStartWindowStart = activeWindowStart
                                    dragStartWindowEnd = activeWindowEnd
                                }

                                let secondsPerPoint = wSpan / width
                                let startingTrim = dragStartTrimStart ?? trimStart
                                let newTime = startingTrim + Double(value.translation.width) * secondsPerPoint

                                trimStart = min(max(0, newTime), trimEnd - 1.0)
                                playheadTime = trimStart
                                draggingTime = trimStart
                                seekPreview(to: trimStart)
                            }
                            .onEnded { _ in
                                dragStartTrimStart = nil
                                dragStartWindowStart = nil
                                dragStartWindowEnd = nil
                                endDragging(keepPaused: true)
                            }
                    )

                // Right Yellow Handle
                appleHandle(direction: .right)
                    .offset(x: endX - 18, y: 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                beginDragging()

                                if dragStartTrimEnd == nil {
                                    dragStartTrimEnd = trimEnd
                                    dragStartWindowStart = activeWindowStart
                                    dragStartWindowEnd = activeWindowEnd
                                }

                                let secondsPerPoint = wSpan / width
                                let startingTrim = dragStartTrimEnd ?? trimEnd
                                let newTime = startingTrim + Double(value.translation.width) * secondsPerPoint

                                trimEnd = max(min(videoDuration, newTime), trimStart + 1.0)
                                playheadTime = trimEnd
                                draggingTime = trimEnd
                                seekPreview(to: trimEnd)
                            }
                            .onEnded { _ in
                                dragStartTrimEnd = nil
                                dragStartWindowStart = nil
                                dragStartWindowEnd = nil
                                endDragging(keepPaused: true)
                            }
                    )

                // Playhead Bar
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .frame(width: 3, height: 54)
                    .offset(x: playheadX - 1.5, y: 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 64)
    }

    private enum HandleDirection { case left, right }

    private func appleHandle(direction: HandleDirection) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow)
                .frame(width: 18, height: 60)

            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.black)
                .scaleEffect(x: 0.8, y: 1.8)
        }
    }

    // MARK: - Timestamp Header Info & Micro-Steppers

    private var timestampInfo: some View {
        HStack(spacing: 0) {
            // Start Handle
            VStack(spacing: 3) {
                Text("Start")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatPreciseTime(clipStart))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.crimsonBlaze)
                
                HStack(spacing: 14) { // spacing between +/- buttons
                    Button { stepStart(by: -0.1) } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 32)
                            .background(Color(white: 0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Button { stepStart(by: 0.1) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 32)
                            .background(Color(white: 0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color(white: 0.25))
                .frame(width: 1, height: 36)

            // Playhead Center
            VStack(spacing: 3) {
                Text("Playhead")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatPreciseTime(displayedTime))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.black)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color(white: 0.25))
                .frame(width: 1, height: 36)

            // End Handle
            VStack(spacing: 3) {
                Text("End")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatPreciseTime(clipEnd))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.crimsonBlaze)
                
                HStack(spacing: 14) {
                    Button { stepEnd(by: -0.1) } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 32)
                            .background(Color(white: 0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Button { stepEnd(by: 0.1) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 32)
                            .background(Color(white: 0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Helper Micro-Step Actions

    private func stepStart(by amount: Double) {
        let newTime = min(max(0, trimStart + amount), trimEnd - 0.5)
        trimStart = newTime
        playheadTime = newTime
        draggingTime = nil
        seekPreview(to: newTime)
    }

    private func stepEnd(by amount: Double) {
        let newTime = max(min(videoDuration, trimEnd + amount), trimStart + 0.5)
        trimEnd = newTime
        playheadTime = newTime
        draggingTime = nil
        seekPreview(to: newTime)
    }

    // MARK: - Player & Preview Setup

    private func setupPreview() {
        let start = min(playheadTime, max(videoDuration, 0))

        if let player = previewPlayer {
            player.pause()
            let seekTime = CMTime(seconds: start, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            isPreviewPlaying = false
        } else {
            let item = AVPlayerItem(url: previewURL)
            let player = AVPlayer(playerItem: item)
            let seekTime = CMTime(seconds: start, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            previewPlayer = player
            addTimeObserverIfNeeded(to: player)
            player.play()
            isPreviewPlaying = true
        }
    }

    private func loadSourceDurationIfNeeded() {
        let asset = AVURLAsset(url: sourceURL)

        Task {
            if let duration = try? await asset.load(.duration) {
                let seconds = duration.seconds
                guard seconds.isFinite, seconds > 0 else { return }

                await MainActor.run {
                    loadedSourceDuration = seconds

                    if trimEnd > seconds {
                        trimEnd = seconds
                    }
                    if playheadTime > seconds {
                        playheadTime = seconds
                    }
                }
            }
        }
    }

    private func beginDragging() {
        guard let player = previewPlayer else { return }

        if !isDraggingTimeline {
            wasPlayingBeforeDrag = player.rate != 0
        }

        isDraggingTimeline = true
        player.pause()
        isPreviewPlaying = false
    }

    private func endDragging(keepPaused: Bool = true) {
        draggingTime = nil
        isDraggingTimeline = false

        guard let player = previewPlayer else { return }

        let clampedTime = min(max(playheadTime, trimStart), trimEnd)
        let t = CMTime(seconds: clampedTime, preferredTimescale: 600)

        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)

        if keepPaused {
            player.pause()
            isPreviewPlaying = false
        } else if wasPlayingBeforeDrag {
            player.play()
            isPreviewPlaying = true
        }
    }

    private func seekPreview(to time: Double) {
        guard let player = previewPlayer else { return }

        let clampedTime = min(max(time, trimStart), trimEnd)
        let t = CMTime(seconds: clampedTime, preferredTimescale: 600)

        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePreviewPlayback() {
        guard let player = previewPlayer else { return }

        if isPreviewPlaying {
            player.pause()
            isPreviewPlaying = false
        } else {
            let restartThreshold = 0.03
            let shouldRestartFromBeginning = playheadTime >= (trimEnd - restartThreshold)

            let targetTime = shouldRestartFromBeginning ? trimStart : min(max(playheadTime, trimStart), trimEnd)

            let seekTime = CMTime(seconds: targetTime, preferredTimescale: 600)

            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
                isPreviewPlaying = true
                playheadTime = targetTime
            }
        }
    }

    private func addTimeObserverIfNeeded(to player: AVPlayer) {
        guard timeObserver == nil else { return }

        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isDraggingTimeline else { return }

            let seconds = time.seconds
            guard seconds.isFinite else { return }

            playheadTime = min(max(seconds, trimStart), trimEnd)

            if seconds >= trimEnd {
                player.pause()
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero)
                playheadTime = trimStart
                isPreviewPlaying = false
            }
        }
    }

    private func removeTimeObserver() {
        guard let player = previewPlayer, let observer = timeObserver else { return }
        player.removeTimeObserver(observer)
        timeObserver = nil
    }

    private var liveDisplayTitle: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? clip.displayName : cleaned
    }

    // MARK: - Export Logic

    private func exportClip(asNewClip: Bool = false) {
        isExporting = true
        exportProgress = "Saving video..."

        let asset = AVURLAsset(url: previewURL)

        Task {
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                await MainActor.run {
                    isExporting = false
                    exportProgress = ""
                }
                return
            }

            let clipsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Clips", isDirectory: true)

            try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)

            // 🌟 If saving as a new clip, generate a brand new UUID!
            let targetClipID = asNewClip ? UUID() : clip.id
            let targetHighlightIndex = asNewClip ? 1 : clip.highlightIndex

            let baseUUID = UUID().uuidString
            let tempTrimURL = clipsDirectory.appendingPathComponent("\(targetClipID.uuidString)-temp-\(baseUUID).mp4")
            let finalOutputURL = clipsDirectory.appendingPathComponent("\(targetClipID.uuidString)-trimmed-\(baseUUID).mp4")

            try? FileManager.default.removeItem(at: tempTrimURL)
            try? FileManager.default.removeItem(at: finalOutputURL)

            exportSession.outputURL = tempTrimURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.timeRange = CMTimeRange(
                start: CMTime(seconds: trimStart, preferredTimescale: 600),
                end: CMTime(seconds: trimEnd, preferredTimescale: 600)
            )

            await exportSession.export()

            guard exportSession.status == .completed else {
                await MainActor.run {
                    isExporting = false
                    exportProgress = "Trim failed"
                }
                return
            }
            
            await MainActor.run { exportProgress = "Saving..." }

            // Watermarking disabled for now — just relocate the trimmed file directly.
            // (Restore the WatermarkService call here once a subscription tier ships.)
            do {
                try? FileManager.default.removeItem(at: finalOutputURL)
                try FileManager.default.moveItem(at: tempTrimURL, to: finalOutputURL)
            } catch {
                print("Failed to finalize trimmed clip: \(error.localizedDescription)")
                await MainActor.run {
                    isExporting = false
                    exportProgress = "Save failed"
                }
                return
            }

            await MainActor.run {
                isExporting = false
                exportProgress = ""
                
                let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let savedClip = Clip(
                    id: targetClipID,
                    sessionID: clip.sessionID,
                    triggeredAt: clip.triggeredAt,
                    offsetInSession: asNewClip ? trimStart : clip.offsetInSession,
                    fileURL: finalOutputURL,
                    duration: trimEnd - trimStart,
                    isUploaded: clip.isUploaded,
                    highlightIndex: targetHighlightIndex,
                    customTitle: cleanedTitle.isEmpty ? nil : cleanedTitle,
                    sourceVideoURL: sourceURL,
                    sourceStartTime: trimStart,
                    sourceEndTime: trimEnd
                )
                
                onSave(savedClip)
                previewPlayer?.pause()
                previewPlayer?.replaceCurrentItem(with: nil)
                previewPlayer = nil
                dismiss()
            }
        }
    }

    private func formatPreciseTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = Int(clamped) % 60
        let hundredths = Int((clamped - floor(clamped)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, hundredths)
    }
    
    private var isTrimTooShort: Bool {
        (trimEnd - trimStart) < 1.0
    }
}
