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

    private var isConnected: Bool { bleVM.bleState.isConnected }
    private var isConnecting: Bool {
        if case .connecting = bleVM.bleState { return true }
        return false
    }

    private var statusTitle: String {
        switch bleVM.bleState {
        case .connected: return "Connected and ready"
        case .connecting: return "Connecting to your button"
        case .scanning: return "Looking for your button"
        case .poweredOff: return "Bluetooth is off"
        case .disconnected: return "Button not connected"
        }
    }

    private var statusDetail: String {
        switch bleVM.bleState {
        case .connected:
            return "Press your ClipIt Button while recording to save a highlight."
        case .connecting:
            return "Keep your button nearby while the connection finishes."
        case .scanning:
            return "Turn on your button and keep it close to this device."
        case .poweredOff:
            return ""
        case .disconnected:
            return "Turn on your button, then scan to connect."
        }
    }

    private var statusLabel: String {
        switch bleVM.bleState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .scanning: return "Searching"
        case .poweredOff: return "Bluetooth off"
        case .disconnected: return "Not connected"
        }
    }

    private var statusColor: Color {
        switch bleVM.bleState {
        case .connected: return .green
        case .connecting, .scanning: return .blueMarble
        case .poweredOff, .disconnected: return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard

                    if !isConnected {
                        connectionSection
                    }

                    settingsCard
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleDisplayMode(.large)
        }
        .onAppear {
            if !isConnected && !isConnecting {
                bleVM.startScanning()
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.blueMarble)
                    .frame(width: 64, height: 64)
                    .background(Color.blueMarble.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 8)

                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(statusColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(statusColor.opacity(0.11), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("ClipIt Button")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cosmosBlue)

                Text(statusTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isConnected {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                HStack(spacing: 12) {
                    if let batteryLevel = bleVM.remoteBatteryLevel {
                        Image(systemName: batteryIcon(for: batteryLevel))
                            .font(.system(size: 22))
                            .foregroundStyle(batteryColor(for: batteryLevel))
                            .frame(width: 32)
                    } else {
                        ProgressView()
                            .tint(.blueMarble)
                            .frame(width: 32)
                    }

                    Text("Button battery")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(bleVM.remoteBatteryLevel.map { "\($0)%" } ?? "Checking…")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.cosmosBlue)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.blueMarble.opacity(0.12), lineWidth: 1)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if case .poweredOff = bleVM.bleState {
                Label("Turn on Bluetooth to find your ClipIt Button.", systemImage: "bluetooth.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            } else {
                if case .connecting = bleVM.bleState {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.crimsonBlaze)
                        Text("Connecting…")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.crimsonBlaze.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                } else {
                    Button {
                        bleVM.startScanning()
                    } label: {
                        Label("Scan for ClipIt Button", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.crimsonBlaze, in: RoundedRectangle(cornerRadius: 15))
                }

                if !isConnecting && !bleVM.discoveredDevices.isEmpty {
                    nearbyDevicesCard
                } else if !isConnecting {
                    Text("Keep your button on and nearby. It will appear here when found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private var nearbyDevicesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nearby buttons")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.cosmosBlue)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ForEach(bleVM.discoveredDevices) { device in
                Button {
                    bleVM.connect(to: device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.blueMarble)
                            .frame(width: 40, height: 40)
                            .background(Color.blueMarble.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(signalDescription(for: device.rssi))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.crimsonBlaze)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connect to \(device.name)")
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var settingsCard: some View {
        Toggle(isOn: $bleVM.autoReconnect) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-reconnect")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Reconnect automatically when your button is nearby.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.crimsonBlaze)
        .padding(18)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func signalDescription(for rssi: Int) -> String {
        if rssi >= -65 { return "Strong signal" }
        if rssi >= -80 { return "Good signal" }
        return "Weak signal"
    }

    private func batteryColor(for level: Int) -> Color {
        switch level {
        case ...20:  return .red
        case 21...50: return .orange
        default:      return .green
        }
    }

    private func batteryIcon(for level: Int) -> String {
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
    @AppStorage("originalVideoRetentionDays") private var originalVideoRetentionDays = 0
    @State private var showOriginalVideoInfo = false
    
    var body: some View {
        NavigationStack {
            List {
                Section("Recording") {
                    SettingsRow(icon: "timer", color: .crimsonBlaze, label: "ClipIt Highlight Length") {
                        HStack(spacing: 6) {
                            Text("\(recordingVM.bufferLengthSeconds)s")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)

                            Stepper("",
                                    value: $recordingVM.bufferLengthSeconds, in: 5...60, step: 5)
                                .labelsHidden()
                        }
                        .fixedSize(horizontal: true, vertical: false)
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
                        SettingsRow(icon: "antenna.radiowaves.left.and.right", color: .blueMarble, label: "ClipIt Button") {
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

                    SettingsRow(icon: "trash.circle", color: .crimsonBlaze, label: "Delete Original\nVideos") {
                        HStack(spacing: 8) {
                            Picker("Original video retention", selection: $originalVideoRetentionDays) {
                                Text("Never").tag(0)
                                Text("After 1 day").tag(1)
                                Text("After 3 days").tag(3)
                                Text("After 7 days").tag(7)
                                Text("After 14 days").tag(14)
                                Text("After 30 days").tag(30)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize(horizontal: true, vertical: false)

                            Button {
                                showOriginalVideoInfo = true
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 19))
                                    .foregroundColor(.crimsonBlaze)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About original video deletion")
                        }
                    }
                }
                .onChange(of: originalVideoRetentionDays) { _, days in
                    recordingVM.applyOriginalVideoRetention(days: days)
                }
                .alert("Original Video Auto-Delete", isPresented: $showOriginalVideoInfo) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Original Videos allow you to edit clips, but take up the most storage space. Deleting them automatically saves device space; your other saved clips will stay in your gallery. Choose “Never” to keep them.")
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
            Text(label)
                .font(.system(size: 15))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
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
