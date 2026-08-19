//
//  CreateReelSheet.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 8/4/26.
//

import SwiftUI
import AVFoundation

// MARK: - Transition Enum (Simplified to None & Crossfade)
enum ReelTransition: String, CaseIterable, Identifiable {
    case none = "None"
    case crossfade = "Crossfade"
    
    var id: String { rawValue }
}

struct CreateReelSheet: View {
    let targetSessionID: UUID?
    let selectedClips: [Clip]
    
    @EnvironmentObject var recordingVM: RecordingViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var titleText: String = ""
    @State private var selectedColor: TitleCardColor = .black
    @State private var selectedTransition: ReelTransition = .crossfade
    @State private var clipsSequence: [Clip] = []
    @State private var isExporting = false
    @State private var exportStatusText = "Generating Highlight Reel..."
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                // Title Slide Text Input
                Section(header: Text("Title Slide (Optional)")) {
                    TextField(
                        "e.g.\nTeam 1 vs Team 2\nGame 1\n8/5/2026",
                        text: $titleText,
                        axis: .vertical
                    )
                    .focused($isTextFieldFocused)
                    .lineLimit(3...6)
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    .padding(.vertical, 6)
                }
                .environment(\.editMode, .constant(.inactive))
                
                // Color Picker
                Section(header: Text("Title Card Color")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            ForEach(TitleCardColor.allCases) { colorOption in
                                colorOptionCell(for: colorOption)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .environment(\.editMode, .constant(.inactive))
                
                // Transition Style Picker
                Section(
                    header: Text("Transition Between Clips"),
                    footer: Text(selectedTransition == .none ? "Clips will cut directly from one to the next." : "Adds a quick crossfade between each clip.")
                ) {
                    Picker("Transition Style", selection: $selectedTransition) {
                        ForEach(ReelTransition.allCases) { transition in
                            Text(transition.rawValue).tag(transition)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                }
                .environment(\.editMode, .constant(.inactive))
                
                // Clip Sequence List
                Section(
                    header: Text("Clips Sequence (\(clipsSequence.count))"),
                    footer: Text("Grab the ☰ handle on the right of any clip to reorder.")
                ) {
                    ForEach(clipsSequence) { clip in
                        HStack {
                            Image(systemName: "film")
                                .foregroundColor(clip.isReel ? .purple : (clip.highlightIndex == nil ? .cosmosBlue : .crimsonBlaze))
                            
                            Text(clip.displayName)
                                .font(.system(size: 15, weight: .semibold))
                            
                            Spacer()
                        }
                    }
                    .onMove(perform: moveClips)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Create Reel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        isTextFieldFocused = false
                        generateReel()
                    }
                    .bold()
                    .disabled(isExporting || clipsSequence.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isTextFieldFocused = false
                    }
                    .bold()
                }
            }
            .overlay {
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.85)
                            .ignoresSafeArea()
                        
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .purple))
                                .scaleEffect(1.5)
                            
                            Text(exportStatusText)
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(32)
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
        .onAppear {
            self.clipsSequence = selectedClips
        }
    }
    
    // MARK: - Subviews & Color Selection Helpers
    @ViewBuilder
    private func colorOptionCell(for colorOption: TitleCardColor) -> some View {
        let isSelected = selectedColor == colorOption
        
        VStack(spacing: 6) {
            Circle()
                .fill(colorOption.swiftUIColor)
                .frame(width: 38, height: 38)
                .overlay(
                    Circle()
                        .stroke(strokeColor(for: colorOption, isSelected: isSelected), lineWidth: isSelected ? 3 : 1)
                )
                .shadow(radius: isSelected ? 3 : 1)
            
            Text(colorOption.rawValue)
                .font(.caption2)
                .bold(isSelected)
                .foregroundColor(isSelected ? .primary : .secondary)
        }
        .onTapGesture {
            selectedColor = colorOption
            isTextFieldFocused = false
        }
    }
    
    private func strokeColor(for option: TitleCardColor, isSelected: Bool) -> Color {
        if isSelected {
            return .primary
        }
        return option == .white ? Color.gray.opacity(0.4) : .clear
    }
    
    private func moveClips(from source: IndexSet, to destination: Int) {
        clipsSequence.move(fromOffsets: source, toOffset: destination)
    }
    
    private func generateReel() {
        Task {
            await MainActor.run {
                isExporting = true
                exportStatusText = "Creating title card..."
            }
            
            // 0. Detect dynamic render size based on orientation of selected clips
            let targetRenderSize = await determineTargetRenderSize(from: clipsSequence)
            
            var urlsToStitch: [URL] = []
            
            // 1. Create Title Card Video matching selected video orientation
            if let titleCardURL = await TitleSlideGenerator.createTitleSlideVideo(
                titleText: titleText,
                color: selectedColor,
                renderSize: targetRenderSize
            ) {
                urlsToStitch.append(titleCardURL)
            }
            
            // 2. Gather URLs for selected clips
            for clip in clipsSequence {
                if let url = clip.fileURL {
                    urlsToStitch.append(url)
                }
            }
            
            guard !urlsToStitch.isEmpty else {
                await MainActor.run { isExporting = false }
                return
            }
            
            await MainActor.run { exportStatusText = "Stitching video clips..." }
            
            do {
                let tempReelURL = try await ReelBuilder.generateReel(
                    clipURLs: urlsToStitch,
                    transition: selectedTransition,
                    renderSize: targetRenderSize
                )
                
                // 3. Save Highlight Reel into Session & local storage
                if let sessionID = targetSessionID ?? clipsSequence.first?.sessionID {
                    if let _ = await saveReelToSession(tempURL: tempReelURL, sessionID: sessionID) {
                        await MainActor.run {
                            isExporting = false
                            dismiss()
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    isExporting = false
                    dismiss()
                }
            } catch {
                print("❌ Failed to generate highlight reel: \(error)")
                await MainActor.run { isExporting = false }
            }
        }
    }
    
    /// Detects whether the first valid clip in the sequence is Landscape (1920x1080) or Portrait (1080x1920).
    private func determineTargetRenderSize(from clips: [Clip]) async -> CGSize {
        for clip in clips {
            guard let url = clip.fileURL else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            guard let naturalSize = try? await track.load(.naturalSize),
                  let preferredTransform = try? await track.load(.preferredTransform) else { continue }
            
            let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let orientedWidth = abs(rect.width)
            let orientedHeight = abs(rect.height)
            
            if orientedWidth > orientedHeight {
                return CGSize(width: 1920, height: 1080) // Landscape
            } else if orientedHeight > orientedWidth {
                return CGSize(width: 1080, height: 1920) // Portrait
            }
        }
        return CGSize(width: 1080, height: 1920) // Fallback default
    }
    
    @discardableResult
    private func saveReelToSession(tempURL: URL, sessionID: UUID) async -> URL? {
        let fileManager = FileManager.default
        guard let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        
        let reelsDir = docsURL.appendingPathComponent("HighlightReels", isDirectory: true)
        try? fileManager.createDirectory(at: reelsDir, withIntermediateDirectories: true)
        
        let filename = "Reel_\(UUID().uuidString).mp4"
        let permanentURL = reelsDir.appendingPathComponent(filename)
        
        do {
            if fileManager.fileExists(atPath: permanentURL.path) {
                try fileManager.removeItem(at: permanentURL)
            }
            try fileManager.moveItem(at: tempURL, to: permanentURL)
            
            let asset = AVURLAsset(url: permanentURL)
            let cmDuration = (try? await asset.load(.duration)) ?? .zero
            let durationSeconds = CMTimeGetSeconds(cmDuration)
            
            let targetSession = recordingVM.sessions.first(where: { $0.id == sessionID })
            let maxIndex = targetSession?.clips.compactMap(\.highlightIndex).max() ?? 0
            
            var reelClip = Clip(
                sessionID: sessionID,
                offsetInSession: 0,
                fileURL: permanentURL,
                duration: durationSeconds.isNaN ? 0 : durationSeconds,
                highlightIndex: maxIndex + 1
            )
            reelClip.isReel = true
            
            let cleanTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            reelClip.customName = cleanTitle.isEmpty ? "ClipIt Highlight Reel" : cleanTitle
            
            await MainActor.run {
                if let index = recordingVM.sessions.firstIndex(where: { $0.id == sessionID }) {
                    recordingVM.sessions[index].clips.append(reelClip)
                    recordingVM.saveSessionsToDisk()
                    recordingVM.updateStorageSize()
                }
            }
            return permanentURL
        } catch {
            print("❌ Failed to save highlight reel to session storage: \(error)")
            return nil
        }
    }
}
