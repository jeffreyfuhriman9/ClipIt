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
    
    // Left handle drag
    private var clipStart: Double {
        min(trimStart, max(0, trimEnd - 5.0))
    }
    
    // Right handle drag
    private var clipEnd: Double {
        max(trimEnd, min(videoDuration, trimStart + 5.0))
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
    
    private var appleStyleTrimControl: some View {
        HStack(spacing: 0) {
            Button {
                togglePreviewPlayback()
            } label: {
                ZStack {
                    // Play button specs
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.clear)
                        .frame(width: 64, height: 64)

                    Image(systemName: isPreviewPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            // Divider line between footage and play button
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 2, height: 64)
                .padding(.trailing, 10)

            trimBar
                .frame(height: 64)
                .padding(.trailing, 12)
        }
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.18))
        )
    }

    private enum HandleDirection {
        case left
        case right
    }

    var body: some View {
            // 💡 Detects if the phone is flipped sideways
            let isLandscape = verticalSizeClass == .compact
            
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()

                    VStack(spacing: 0) {
                        previewArea
                            // 🎯 THE FIX: Instead of a hardcoded 450 height, we let it flex to infinity in landscape.
                            // The layoutPriority(1) ensures it takes up all leftover space WITHOUT crushing the controls below.
                            .frame(maxHeight: isLandscape ? .infinity : 450)
                            .layoutPriority(1)

                        timestampInfo
                            .padding(.vertical, isLandscape ? 8 : 16)

                        appleStyleTrimControl
                            .padding(.horizontal, isLandscape ? 48 : 24) // Adds extra horizontal safe-area padding in landscape
                            .padding(.bottom, isLandscape ? 8 : 20)
                            .padding(.top, isLandscape ? 4 : 12)

                        Divider()
                            .overlay(Color(white: 0.2))

                        // Only push with a Spacer if we have massive vertical height (Portrait)
                        if !isLandscape {
                            Spacer()
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                            Text("Clip will be \(formatPreciseTime(totalLength))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, isLandscape ? 8 : 0)
                        .padding(.bottom, isLandscape ? 12 : 24)
                    }
                }
                .navigationTitle(liveDisplayTitle)
                .navigationBarTitleDisplayMode(.inline)
                .preferredColorScheme(.dark)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            previewPlayer?.pause()
                            previewPlayer?.replaceCurrentItem(with: nil)
                            previewPlayer = nil
                            dismiss()
                        }
                        .foregroundColor(.white)
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
                        } else {
                            Button("Save") { exportClip() }
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
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

    private var timestampInfo: some View {
        HStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("Start")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatTime(clipStart))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color(white: 0.25))
                .frame(width: 1, height: 32)

            VStack(spacing: 3) {
                Text("Playhead")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatPreciseTime(displayedTime))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color(white: 0.25))
                .frame(width: 1, height: 32)

            VStack(spacing: 3) {
                Text("End")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.5))
                Text(formatTime(clipEnd))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
    }

    private var trimBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let total = max(videoDuration, 1)

            let startX = CGFloat(trimStart / total) * width
            let endX = CGFloat(trimEnd / total) * width
            let selectionWidth = endX - startX
            let playheadX = CGFloat(displayedTime / total) * width

            ZStack(alignment: .topLeading) {
                // full timeline background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.35))
                    .frame(height: 52)
                    .offset(y: 6)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                beginDragging()

                                let clampedX = max(0, min(width, value.location.x))
                                let normalized = max(0, min(1, clampedX / width))
                                let newTime = max(trimStart, min(trimEnd, Double(normalized) * total))

                                playheadTime = newTime
                                draggingTime = newTime
                                seekPreview(to: newTime)
                            }
                            .onEnded { _ in
                                endDragging(keepPaused: true)
                            }
                    )

                // left dimmed region
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: max(0, startX), height: 52)
                    .offset(x: 0, y: 6)

                // right dimmed region
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: max(0, width - endX), height: 52)
                    .offset(x: endX, y: 6)

                // yellow connected trim frame
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.yellow, lineWidth: 6)
                    .frame(width: selectionWidth, height: 52)
                    .offset(x: startX, y: 6)

                // left yellow handle
                appleHandle(direction: .left)
                    .offset(x: startX - 6, y: 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                beginDragging()

                                if dragStartTrimStart == nil {
                                    dragStartTrimStart = trimStart
                                }

                                let secondsPerPoint = total / width
                                let startingTrim = dragStartTrimStart ?? trimStart
                                let newTime = startingTrim + Double(value.translation.width) * secondsPerPoint

                                trimStart = min(max(0, newTime), trimEnd - 5.0)
                                playheadTime = trimStart
                                draggingTime = trimStart
                                seekPreview(to: trimStart)
                            }
                            .onEnded { _ in
                                dragStartTrimStart = nil
                                endDragging(keepPaused: true)
                            }
                    )

                // right yellow handle
                appleHandle(direction: .right)
                    .offset(x: endX - 18, y: 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                beginDragging()

                                if dragStartTrimEnd == nil {
                                    dragStartTrimEnd = trimEnd
                                }

                                let secondsPerPoint = total / width
                                let startingTrim = dragStartTrimEnd ?? trimEnd
                                let newTime = startingTrim + Double(value.translation.width) * secondsPerPoint

                                trimEnd = max(min(videoDuration, newTime), trimStart + 5.0)
                                playheadTime = trimEnd
                                draggingTime = trimEnd
                                seekPreview(to: trimEnd)
                            }
                            .onEnded { _ in
                                dragStartTrimEnd = nil
                                endDragging(keepPaused: true)
                            }
                    )

                // playhead
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .frame(width: 3, height: 54)
                    .offset(x: playheadX - 1.5, y: 6)
                    .allowsHitTesting(false)

                // time bubble while dragging
                if let activeDragTime = draggingTime {
                    let bubbleX = CGFloat(activeDragTime / total) * width

                    Text(formatPreciseTime(activeDragTime))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(white: 0.12))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .offset(
                            x: max(0, min(width - 86, bubbleX - 43)),
                            y: -28
                        )
                }
            }
        }
        .frame(height: 64)
    }

    private func appleHandle(direction: HandleDirection) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow)
                .frame(width: 18, height: 60)

            Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.black)
                .scaleEffect(x: 0.8, y:1.8)
        }
    }

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

    private func exportClip() {
        isExporting = true
        exportProgress = "Exporting highlights..."

        let asset = AVURLAsset(url: previewURL)

        Task {
            // 1. Setup export session for the TRIM
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

            // 2. Create URLs for the temp trim and the final watermarked video
            let baseUUID = UUID().uuidString
            let tempTrimURL = clipsDirectory.appendingPathComponent("\(clip.id.uuidString)-temp-\(baseUUID).mp4")
            let finalOutputURL = clipsDirectory.appendingPathComponent("\(clip.id.uuidString)-trimmed-\(baseUUID).mp4")

            try? FileManager.default.removeItem(at: tempTrimURL)
            try? FileManager.default.removeItem(at: finalOutputURL)

            exportSession.outputURL = tempTrimURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true
            exportSession.timeRange = CMTimeRange(
                start: CMTime(seconds: trimStart, preferredTimescale: 600),
                end: CMTime(seconds: trimEnd, preferredTimescale: 600)
            )

            // 3. Export the raw trim
            await exportSession.export()

            guard exportSession.status == .completed else {
                await MainActor.run {
                    isExporting = false
                    exportProgress = "Trim failed"
                }
                return
            }
            
            // 4. APPLY THE WATERMARK
            await MainActor.run { exportProgress = "Applying watermark..." }
            
            WatermarkService.applyWatermark(inputURL: tempTrimURL, outputURL: finalOutputURL) { result in
                Task { @MainActor in
                    isExporting = false
                    exportProgress = ""
                    
                    // Clean up the temporary file now that we are done with it
                    try? FileManager.default.removeItem(at: tempTrimURL)
                    
                    switch result {
                    case .success(let watermarkedURL):
                        // 5. Build the final Clip model using the watermarked URL
                        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        let savedClip = Clip(
                            id: clip.id,
                            sessionID: clip.sessionID,
                            triggeredAt: clip.triggeredAt,
                            offsetInSession: clip.offsetInSession,
                            fileURL: watermarkedURL, // 👈 Points to the final watermarked file
                            duration: trimEnd - trimStart,
                            isUploaded: clip.isUploaded,
                            highlightIndex: clip.highlightIndex,
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
                        
                    case .failure(let error):
                        print("Watermark failed: \(error.localizedDescription)")
                        // Fallback: If watermark fails, at least save the raw trimmed video
                        // You can adjust this to throw an alert instead if you strictly require watermarks
                        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let savedClip = Clip(
                            id: clip.id,
                            sessionID: clip.sessionID,
                            triggeredAt: clip.triggeredAt,
                            offsetInSession: clip.offsetInSession,
                            fileURL: tempTrimURL,
                            duration: trimEnd - trimStart,
                            isUploaded: clip.isUploaded,
                            highlightIndex: clip.highlightIndex,
                            customTitle: cleanedTitle.isEmpty ? nil : cleanedTitle,
                            sourceVideoURL: sourceURL,
                            sourceStartTime: trimStart,
                            sourceEndTime: trimEnd
                        )
                        onSave(savedClip)
                        dismiss()
                    }
                }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formatPreciseTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = Int(clamped) % 60
        let hundredths = Int((clamped - floor(clamped)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, hundredths)
    }
}
