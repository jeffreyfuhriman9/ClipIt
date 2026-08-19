import SwiftUI
import AVFoundation
import Combine

// 🌟 Helper item for bulletproof share sheet presentation
struct ShareContainer: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - ClipRow

private struct ClipRow: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    let sessionID: UUID
    let clip: Clip
    var allClips: [Clip] = []
    let fullVideoURL: URL?
    let sessionDuration: TimeInterval
    
    // 🌟 Multi-Select Properties
    let isSelectionMode: Bool
    let isSelected: Bool
    let onSelectToggle: () -> Void
    
    let onDeleteFullRecording: (() -> Void)?
    
    @State private var showPlayer = false
    @State private var thumbnail: UIImage? = nil
    @EnvironmentObject var multipeerManager: MultipeerManager
    
    var body: some View {
        Button(action: {
            if isSelectionMode {
                onSelectToggle()
            } else if clip.fileURL != nil {
                showPlayer = true
            }
        }) {
            HStack(spacing: 12) {
                // 🌟 Checkmark Selection Indicator
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundColor(isSelected ? .blue : Color(UIColor.tertiaryLabel))
                        .transition(.scale.combined(with: .opacity))
                }
                
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
                    
                    if thumbnail != nil && !isSelectionMode {
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
                
                if !isSelectionMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showPlayer) {
            ClipPagerView(
                clips: allClips,
                initialClipID: clip.id,
                fullVideoURL: fullVideoURL,
                sessionDuration: sessionDuration,
                onDelete: { clipToDelete in
                    if clipToDelete.highlightIndex == nil {
                        onDeleteFullRecording?()
                    } else {
                        recordingVM.deleteClip(sessionID: clipToDelete.sessionID, clipID: clipToDelete.id)
                    }
                },
                onTrimSaved: { updatedClip in
                    recordingVM.updateClip(updatedClip)
                },
                onRename: { clipToRename, newName in
                    var updatedClip = clipToRename
                    updatedClip.customName = newName
                    recordingVM.updateClip(updatedClip)
                }
            )
            .environmentObject(multipeerManager)
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
                            
                            if let batteryLevel = bleVM.remoteBatteryLevel {
                                HStack(spacing: 4) {
                                    Text("\(batteryLevel)%")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    
                                    Image(systemName: getBatteryIcon(for: batteryLevel))
                                        .font(.system(size: 15))
                                        .foregroundColor(getBatteryColor(for: batteryLevel))
                                }
                            } else {
                                Text("Connected")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.green.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                
                Section {
                    Button(action: { bleVM.startScanning() }) {
                        HStack {
                            Spacer()
                            Text("Scan Nearby Devices")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.crimsonBlaze)
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
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleDisplayMode(.large)
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
                        .fill(Color.crimsonBlaze.opacity(0.85))
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
    @AppStorage("dimScreenDuringRecording") private var dimScreenDuringRecording = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Recording") {
                    SettingsRow(icon: "timer", color: .crimsonBlaze, label: "ClipIt Highlight Length") {
                        Stepper("\(recordingVM.bufferLengthSeconds)s",
                                value: $recordingVM.bufferLengthSeconds, in: 5...60, step: 5)
                        .font(.system(size: 14))
                    }
                    
                    SettingsRow(icon: "video.fill", color: .green, label: "Video Quality") {
                        Picker("", selection: $recordingVM.selectedVideoQuality) {
                            ForEach(CameraManager.VideoQuality.allCases) { quality in
                                Text(quality.rawValue).tag(quality)
                            }
                        }
                        .onChange(of: recordingVM.selectedVideoQuality) { oldQuality, newQuality in
                            recordingVM.updateVideoQuality(to: newQuality)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .font(.system(size: 14))
                    }
                    
                    SettingsRow(icon: "sunset.fill", color: .orange, label: "Dim Screen While Recording") {
                        Toggle("", isOn: $dimScreenDuringRecording)
                            .labelsHidden()
                    }
                }
                
                Section("Bluetooth") {
                    NavigationLink(destination: BLEDeviceView()) {
                        SettingsRow(icon: "antenna.radiowaves.left.and.right", color: .gochujangRed, label: "ClipIt Button") {
                            Text("Configure").foregroundColor(.secondary).font(.system(size: 14))
                        }
                    }
                }
                
                Section("Storage") {
                    SettingsRow(icon: "internaldrive.fill", color: .gray, label: "Storage Used") {
                        Text(recordingVM.localStoreSize)
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                }
                
                Section("Account") {
                    SettingsRow(icon: "star.fill", color: .purple, label: "Subscription") {
                        Text("Free").foregroundColor(.secondary).font(.system(size: 14))
                    }
                    SettingsRow(icon: "cloud.fill", color: .blueMarble, label: "Cloud Storage") {
                        Text("Coming soon...").foregroundColor(.secondary).font(.system(size: 14))
                    }
                }
                
                Section("About") {
                    NavigationLink(destination: AboutView()) {
                        SettingsRow(icon: "info.circle.fill", color: .cosmosBlue, label: "About") {
                            EmptyView()
                        }
                    }
                }
                
                Section {
                    Text("2026 ClipIt LLC • Version 1.3")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleDisplayMode(.large)
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
