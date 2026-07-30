import SwiftUI
import AVFoundation
import Combine

// MARK: - ClipsView

import SwiftUI

struct ClipsView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    @State private var sessionBeingRenamed: Session?
    @State private var renameDraft = ""
    @State private var sessionToDelete: Session?
    @State private var fullRecordingToDelete: Session?
    
    var body: some View {
        ZStack { // 🌟 Wraps everything to allow overlays to float on top
            NavigationStack {
                VStack(spacing: 0) { // 🛠️ Changed from Group to VStack to host the banner
                    
                    // Main Content Body Switcher
                    if recordingVM.sessions.isEmpty {
                        emptyState
                    } else {
                        sessionList
                    }
                }
                .navigationTitle("My Clips")
                .background(Color(UIColor.systemBackground))
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
                .onChange(of: multipeerManager.newlyImportedFullVideoURL) { _, newURL in
                    if let incomingURL = newURL {
                        print("📦 AllViews intercepted completed transfer file path for session: \(String(describing: multipeerManager.newlyImportedTargetSessionID))")
                        
                        // 🌟 FIX: Pass the sessionID we parsed during the transfer
                        recordingVM.attachSecondaryMasterVideo(
                            fileURL: incomingURL,
                            targetSessionID: multipeerManager.newlyImportedTargetSessionID
                        )
                        
                        // Clear out the temporary variables so the manager is ready for the next request
                        multipeerManager.newlyImportedFullVideoURL = nil
                        multipeerManager.newlyImportedTargetSessionID = nil
                    }
                }
                .alert("Delete session?", isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                )) {
                    Button("Cancel", role: .cancel) { sessionToDelete = nil }
                    Button("Delete", role: .destructive) {
                        if let session = sessionToDelete {
                            recordingVM.deleteSession(id: session.id)
                        }
                        sessionToDelete = nil
                    }
                } message: {
                    Text("This will permanently delete the full recording and all highlights in this session.")
                }
                .alert("Delete Full Recording?", isPresented: Binding(
                    get: { fullRecordingToDelete != nil },
                    set: { if !$0 { fullRecordingToDelete = nil } }
                )) {
                    Button("Delete Master Video", role: .destructive) {
                        if let session = fullRecordingToDelete {
                            // Check if a secondary continuous master track exists for this session context
                            let hasSecondaryMaster = session.clips.contains { $0.isSecondaryAngle && $0.sourceVideoURL != nil }
                            
                            if hasSecondaryMaster {
                                // If secondary exists, wipe it out cleanly!
                                recordingVM.deleteSecondaryFullRecording(sessionID: session.id)
                            } else {
                                // Otherwise fallback to default primary track deletion workflow
                                recordingVM.deleteFullRecording(sessionID: session.id)
                            }
                        }
                        fullRecordingToDelete = nil
                    }
                    Button("Keep File", role: .cancel) { fullRecordingToDelete = nil }
                } message: {
                    Text("Are you sure you want to delete the continuous master background track? You will keep your individual trimmed highlight clips, but you will no longer be able to change their window boundaries.")
                }
                .alert("Import Multiview Highlights?", isPresented: Binding(
                    // 🌟 ONLY show the alert if the trigger is true, this device is the host,
                    // AND there is actually a secondary device currently in your connectedPeers array!
                    get: {
                        recordingVM.showAutomaticImportPrompt &&
                        multipeerManager.isHost &&
                        !multipeerManager.connectedPeers.isEmpty
                    },
                    set: { recordingVM.showAutomaticImportPrompt = $0 }
                )) {
                    Button("Import Highlights", role: .none) {
                        // No longer strictly need the if-statement here since the alert won't open without it,
                        // but keeping it is totally fine and safe!
                        if !multipeerManager.connectedPeers.isEmpty {
                            recordingVM.isImportingSecondary = true
                            multipeerManager.sendCommand(.requestHighlights)
                            print("📡 Sent .requestHighlights command to secondary device.")
                        }
                    }
                    Button("Skip", role: .cancel) {
                        recordingVM.isImportingSecondary = false
                    }
                } message: {
                    Text("Your primary clips are fully processed! Would you like to wirelessly match and import the individual highlight clips from your connected secondary camera now?")
                }
            }
            
            // 🌟 STEP 3 PROGRESS OVERLAY LAYER
            if recordingVM.isExtractingHighlights {
                ZStack {
                    Color.black.opacity(0.85)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .red))
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
            
            // 🌟 STEP 4: MULTIVIEW IMPORT PROGRESS OVERLAY
            if recordingVM.isImportingSecondary {
                ZStack {
                    Color.black.opacity(0.85)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 24) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .red))
                            .scaleEffect(1.5)
                        
                        Text("Importing Angles...")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)
                        
                        // 🌟 Using your beautiful custom progress view!
                        HighlightExtractionProgressView(
                            currentCount: multipeerManager.receivedHighlightCount,
                            totalCount: max(1, multipeerManager.expectedHighlightCount) // max(1) prevents divide-by-zero crashes
                        )
                        .frame(maxWidth: 340)
                        .padding(.horizontal, 24)
                    }
                }
                .transition(.opacity)
                .id("ClipsImportOverlay")
            }
        }
        // Animates both the extraction screen overlay and the multi-cam notification banner slide-in
        .animation(.default, value: multipeerManager.importedVideoURLQueue)
        .animation(.easeInOut(duration: 0.3), value: recordingVM.isExtractingHighlights)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No clips yet")
                .font(.title3.bold())
            Text("Head to Record to start capturing highlights.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var sessionList: some View {
        List {
            ForEach(recordingVM.sessions, id: \.id) { session in
                SessionSection(
                    session: session,
                    renameDraft: $renameDraft,
                    sessionBeingRenamed: $sessionBeingRenamed,
                    sessionToDelete: $sessionToDelete,
                    fullRecordingToDelete: $fullRecordingToDelete // 🌟 ADD THIS LINE HERE!
                )
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - SessionSection

// MARK: - SessionSection

private struct SessionSection: View {
    let session: Session
    
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var multipeerManager: MultipeerManager
    
    @Binding var renameDraft: String
    @Binding var sessionBeingRenamed: Session?
    @Binding var sessionToDelete: Session?
    @Binding var fullRecordingToDelete: Session?
    
    var body: some View {
        Section {
            // 🗑️ We removed the redundant HStack here that had the duplicate title and trash can.
            
            if session.isProcessing {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.1)
                        .tint(.red)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Processing Video...")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        if session.processingProgress > 0 {
                            Text("Extracting highlights: \(Int(session.processingProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Applying ClipIt watermark...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
            } else {
                            
                if let fullClip = session.fullRecordingClip {
                    ClipRow(
                        sessionID: session.id,
                        clip: fullClip,
                        fullVideoURL: nil,
                        sessionDuration: session.duration,
                        onDeleteFullRecording: { recordingVM.deleteFullRecording(sessionID: session.id) }
                    )
                }
                
                // 🎬 1. FILTER & DISPLAY PRIMARY CLIPS
                let primaryClips = session.highlights.filter { !$0.isSecondaryAngle }
                ForEach(primaryClips) { clip in
                    ClipRow(
                        sessionID: session.id,
                        clip: clip,
                        fullVideoURL: session.fullVideoURL,
                        sessionDuration: session.duration,
                        onDeleteFullRecording: nil
                    )
                }
                
                // 🔭 2. FILTER & DISPLAY SECONDARY CLIPS
                let secondaryClips = session.highlights.filter { $0.isSecondaryAngle }

                if !secondaryClips.isEmpty {
                    // ✅ CAMERA 2 HEADER: Keeping it inside its own section element row
                    Text("CAMERA ANGLE 2")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    
                    // 🎞️ UNIFIED LOOK & PLAYBACK FIX
                    if let secondaryMasterURL = secondaryClips.first?.sourceVideoURL {
                        let secondaryMasterClip: Clip = {
                            var c = Clip(
                                sessionID: session.id,
                                offsetInSession: 0,
                                fileURL: secondaryMasterURL,
                                duration: session.duration,
                                highlightIndex: nil
                            )
                            c.isSecondaryAngle = true
                            return c
                        }()
                        
                        // ✅ Placed directly in the Section so it gets native row height/spacing
                        ClipRow(
                            sessionID: session.id,
                            clip: secondaryMasterClip,
                            fullVideoURL: nil,
                            sessionDuration: session.duration,
                            onDeleteFullRecording: {
                                recordingVM.deleteSecondaryFullRecording(sessionID: session.id)
                            }
                        )
                    }
                    
                    // Individual secondary cropped highlights container loops
                    // ✅ Placed directly in the Section so they get identical row spacing and dividers natively
                    ForEach(secondaryClips) { clip in
                        ClipRow(
                            sessionID: session.id,
                            clip: clip,
                            fullVideoURL: clip.sourceVideoURL,
                            sessionDuration: session.duration,
                            onDeleteFullRecording: nil
                        )
                    }
                }
            }
        } header: {
            SessionHeader(
                session: session,
                onRenameTapped: {
                    renameDraft = session.name
                    sessionBeingRenamed = session
                },
                onDeleteTapped: { sessionToDelete = session }
            )
        }
    }
}

// MARK: - SessionHeader

private struct SessionHeader: View {
    let session: Session
    let onRenameTapped: () -> Void
    let onDeleteTapped: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onRenameTapped) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color(UIColor.tertiarySystemBackground))
                            .clipShape(Circle())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Text("\(session.formattedDate) · \(session.durationLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDeleteTapped) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - RenameSessionSheet

private struct RenameSessionSheet: View {
    let sessionName: String
    @Binding var draftName: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Session name") {
                    TextField("Enter a name", text: $draftName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .overlay(
                            HStack {
                                Spacer()
                                if !draftName.isEmpty {
                                    Button {
                                        draftName = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(Color(UIColor.tertiaryLabel))
                                            .font(.system(size: 16))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        )
                }
            }
            .navigationTitle("Rename Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(); dismiss() }
                        .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .onAppear { draftName = sessionName }
    }
}

// MARK: - ClipRow

private struct ClipRow: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    let sessionID: UUID
    let clip: Clip
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
    let onDeleteFullRecording: (() -> Void)?
    
    @State private var showPlayer = false
    @State private var thumbnail: UIImage? = nil
    @EnvironmentObject var multipeerManager: MultipeerManager
    
    var body: some View {
        Button(action: { if clip.fileURL != nil { showPlayer = true } }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.tertiarySystemBackground))
                        .frame(width: 72, height: 52)
                    
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if clip.fileURL != nil {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.tertiarySystemBackground))
                            .frame(width: 72, height: 52)
                            .overlay(
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(clip.highlightIndex == nil ? .blue : .red)
                                    .opacity(0.5)
                            )
                    } else {
                        ProgressView().tint(.red)
                    }
                    
                    if thumbnail != nil {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                }
                .frame(width: 72, height: 52)
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 4) {
                        if let url = clip.fileURL {
                            Text(url.fileSizeString)
                                .foregroundColor(clip.highlightIndex != nil ? .red : .blue)
                                .fontWeight(.bold)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                
                Text(clip.durationLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(clip.highlightIndex == nil ? .blue : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(clip.highlightIndex == nil ? Color.blue.opacity(0.12) : Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showPlayer) {
            ClipPlayerView(
                clip: clip,
                fullVideoURL: fullVideoURL,
                sessionDuration: sessionDuration,
                onDelete: {
                    if clip.highlightIndex == nil {
                        onDeleteFullRecording?()
                    } else {
                        recordingVM.deleteClip(sessionID: clip.sessionID, clipID: clip.id)
                    }
                },
                onTrimSaved: { updatedClip in
                    recordingVM.updateClip(updatedClip)
                },
                onRename: { newName in
                    var updatedClip = clip
                    updatedClip.customName = newName
                    recordingVM.updateClip(updatedClip)
                }
            )
            .environmentObject(multipeerManager)
            .id(clip.id)
        }
        .onAppear { loadThumbnail() }
        .onChange(of: clip.fileURL) { _, _ in loadThumbnail() }
    }
    
    private func loadThumbnail() {
        guard let url = clip.fileURL, thumbnail == nil else { return }
        
        Task(priority: .utility) {
            var retryCount = 0
            while !FileManager.default.fileExists(atPath: url.path) && retryCount < 10 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms pause
                retryCount += 1
            }
            
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 144, height: 104)
            
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            
            do {
                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                
                let midPointSeconds = durationSeconds > 0 ? (durationSeconds / 2.0) : 0.5
                let targetTime = CMTime(seconds: midPointSeconds, preferredTimescale: 600)
                
                let cgImage = try generator.copyCGImage(at: targetTime, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                
                await MainActor.run {
                    self.thumbnail = image
                }
            } catch {
                print("❌ Midpoint thumbnail generation failed: \(error)")
                
                let fallbackTime = CMTime(seconds: 0.5, preferredTimescale: 600)
                if let cgImage = try? generator.copyCGImage(at: fallbackTime, actualTime: nil) {
                    let image = UIImage(cgImage: cgImage)
                    await MainActor.run {
                        self.thumbnail = image
                    }
                }
            }
        }
    }
}

// MARK: - BLEDeviceView

struct BLEDeviceView: View {
    @EnvironmentObject var bleVM: BLEViewModel
    
    var body: some View {
            NavigationStack {
                List {
                    Section {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(bleVM.bleState.isConnected ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(bleVM.bleState.isConnected ? .blue : .gray)
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("ClipIt Button").font(.system(size: 15, weight: .semibold))
                                Text(bleVM.bleState.label).font(.caption).foregroundColor(.secondary)
                            }
                            
                            if bleVM.bleState.isConnected {
                                Spacer()
                                
                                // 🌟 Perfectly vertically aligned on the right hand side
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("Connected")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.12))
                                        .clipShape(Capsule())
                                    
                                    if let batteryLevel = bleVM.remoteBatteryLevel {
                                        HStack(spacing: 4) {
                                            Text("\(batteryLevel)%")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(.secondary)
                                            
                                            Image(systemName: getBatteryIcon(for: batteryLevel))
                                                .font(.system(size: 14))
                                                .foregroundColor(getBatteryColor(for: batteryLevel))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    
                    Section {
                        Button(action: { bleVM.startScanning() }) {
                            HStack {
                                Spacer()
                                Text("Scan Nearby Devices").font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                        .contentShape(Rectangle())
                    }
                    
                    if !bleVM.discoveredDevices.isEmpty {
                        Section("Nearby devices") {
                            ForEach(bleVM.discoveredDevices) { device in
                                HStack {
                                    Image(systemName: "memorychip").foregroundColor(.blue).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name).font(.system(size: 14, weight: .semibold))
                                        Text("\(device.rssi) dBm").font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button("Connect") { bleVM.connect(to: device) }
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                    
                    Section("Connection settings") {
                        Toggle("Auto-reconnect", isOn: $bleVM.autoReconnect)
                    }
                }
                .navigationTitle("ClipIt Button")
            }
        }
    
    private func getBatteryColor(for level: Int) -> Color {
        switch level {
        case ...20:   return .red     // Under 20% turns critical Red
        default:      return .primary   // White in Dark Mode, Black in Light
        }
    }

    private func getBatteryIcon(for level: Int) -> String {
        switch level {
        case ...10:   return "battery.0"
        case 11...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...85: return "battery.75"
        default:      return "battery.100"
        }
    }
}

// MARK: - SaveSessionView

struct SaveSessionView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    
    var body: some View {
        NavigationStack {
            Group {
                if let session = recordingVM.currentSession {
                    saveContent(session: session)
                } else {
                    noActiveSession
                }
            }
            .navigationTitle("Save Session")
        }
    }
    
    private var noActiveSession: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No active session").font(.title3.bold())
            Text("Start recording to see your session summary here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func saveContent(session: Session) -> some View {
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    SummaryTile(label: "Clips captured", value: "\(session.clips.count)")
                    SummaryTile(label: "Duration", value: session.durationLabel)
                    SummaryTile(label: "Mode", value: session.mode == .highlightsOnly ? "Highlights" : "Full session")
                    SummaryTile(label: "Est. size", value: session.mode == .highlightsOnly ? "~120 MB" : "~3.2 GB")
                }
                .padding(.vertical, 4)
            }
            
            if !session.clips.isEmpty {
                Section("Clip timeline") {
                    TimelineBar(clips: session.clips, sessionDuration: session.duration)
                        .frame(height: 40)
                        .padding(.vertical, 4)
                }
            }
            
            Section {
                Button(action: { recordingVM.endSession() }) {
                    HStack {
                        Spacer()
                        Text("Save session")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .frame(height: 44)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                
                Button(role: .destructive, action: { recordingVM.discardSession() }) {
                    HStack {
                        Spacer()
                        Text("Discard session")
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct SummaryTile: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 22, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TimelineBar: View {
    let clips: [Clip]
    let sessionDuration: TimeInterval
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(UIColor.tertiarySystemBackground))
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                    let pct = sessionDuration > 0 ? CGFloat(clip.offsetInSession / sessionDuration) : 0
                    let x = pct * (geo.size.width - 22)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 22, height: 30)
                        .overlay(Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundColor(.white))
                        .offset(x: x)
                }
            }
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @EnvironmentObject var supabaseService: SupabaseService
    @AppStorage("dimScreenDuringRecording") private var dimScreenDuringRecording = false
    @State private var accountEmail = ""
    @State private var authMessage: String?
    @State private var isSendingMagicLink = false
    
    private var cloudStatusText: String {
        if !supabaseService.isConfigured {
            return "Not configured"
        }
        if supabaseService.isSyncing {
            return "Syncing…"
        }
        if supabaseService.isSignedIn {
            return "Connected"
        }
        return "Connecting…"
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section("Recording") {
                    SettingsRow(icon: "timer", color: .blue, label: "Before ClipIt") {
                        Stepper("\(recordingVM.bufferLengthSeconds)s",
                                value: $recordingVM.bufferLengthSeconds, in: 5...60, step: 5)
                        .font(.system(size: 14))
                    }
                    
                    SettingsRow(icon: "video.fill", color: .green, label: "Video Quality") {
                        // ✅ Clean, direct binding to your new main view model state property
                        Picker("", selection: $recordingVM.selectedVideoQuality) {
                            ForEach(CameraManager.VideoQuality.allCases) { quality in
                                Text(quality.rawValue).tag(quality)
                            }
                        }
                        // ✅ Fires exactly once per tap, updating the hardware safely in the background
                        .onChange(of: recordingVM.selectedVideoQuality) { oldQuality, newQuality in
                            recordingVM.updateVideoQuality(to: newQuality)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .font(.system(size: 14))
                    }
                    
                    SettingsRow(icon: "timer", color: .red, label: "After ClipIt") {
                        Stepper("\(recordingVM.postRollSeconds)s",
                                value: $recordingVM.postRollSeconds, in: 0...60, step: 5)
                        .font(.system(size: 14))
                    }
                    
                    SettingsRow(icon: "sun.min.fill", color: .orange, label: "Dim Screen While Recording") {
                        Toggle("", isOn: $dimScreenDuringRecording)
                            .labelsHidden()
                    }
                }
                
                Section("Bluetooth") {
                    NavigationLink(destination: BLEDeviceView()) {
                        SettingsRow(icon: "antenna.radiowaves.left.and.right", color: .blue, label: "ClipIt Button") {
                            Text("Configure").foregroundColor(.secondary).font(.system(size: 14))
                        }
                    }
                }
                
                Section("Storage") {
                    SettingsRow(icon: "internaldrive.fill", color: .gray, label: "Total Storage Used") {
                        Text(recordingVM.localStoreSize)
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                }
                
                Section("Account") {
                    SettingsRow(icon: "star.fill", color: .purple, label: "Subscription") {
                        Text("Free").foregroundColor(.secondary).font(.system(size: 14))
                    }
                    SettingsRow(icon: "cloud.fill", color: .gray, label: "Cloud Storage") {
                        Text(cloudStatusText)
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    
                    if supabaseService.isConfigured {
                        if let email = supabaseService.currentUserEmail {
                            SettingsRow(icon: "person.fill", color: .blue, label: "Signed in as") {
                                Text(email).foregroundColor(.secondary).font(.system(size: 14))
                            }
                        }
                        
                        if supabaseService.isSignedIn {
                            Button("Sign Out", role: .destructive) {
                                Task {
                                    try? await supabaseService.signOut()
                                    authMessage = nil
                                }
                            }
                        }
                        
                        if let authMessage {
                            Text(authMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        
                        if let syncError = supabaseService.lastSyncError {
                            Text(syncError)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    } else {
                        Text("Copy Secrets.plist.example to Secrets.plist and add your Supabase project URL and anon key.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section {
                    Text("2026 ClipIt LLC • Version 1.3")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Settings")
            .onAppear { recordingVM.updateStorageSize() }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let color: Color
    let label: String
    @ViewBuilder let trailing: () -> Trailing
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(label).font(.system(size: 15))
            Spacer()
            trailing()
        }
    }
}

// MARK: - URL file size helper

extension URL {
    var fileSizeString: String {
        guard let resources = try? self.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = resources.fileSize else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }
}
