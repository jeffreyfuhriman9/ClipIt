import SwiftUI
import AVFoundation
import Combine
import UserNotifications
import UIKit

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
    @EnvironmentObject private var tutorial: TutorialController
    @State private var showingRenameButton = false
    @State private var proposedButtonName = ""
    @State private var showingAutoReconnectConfirmation = false

    private var isConnected: Bool { bleVM.bleState.isConnected }
    private var isConnecting: Bool {
        if case .connecting = bleVM.bleState { return true }
        return false
    }

    private var statusDetail: String {
        switch bleVM.bleState {
        case .connected:
            return "Press your ClipIt Button while recording to save a highlight."
        case .connecting:
            return "Keep your button nearby while the connection finishes."
        case .scanning:
            if bleVM.isWaitingForManualButtonSelection {
                return "Choose a button below to reconnect. Your disconnected button won't reconnect on its own."
            }
            return "Turn on your button and keep it close to this device."
        case .poweredOff:
            return ""
        case .disconnected:
            if bleVM.isWaitingForManualButtonSelection {
                return "Choose your button from the nearby list to reconnect."
            }
            return "Turn on your button, then scan to connect."
        }
    }

    private var statusLabel: String {
        switch bleVM.bleState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .scanning: return "Scanning"
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
                        .tutorialTarget(.device)

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
            if !tutorial.isActive && !isConnected && !isConnecting {
                bleVM.startScanning()
            }
        }
        .alert("Rename ClipIt Button", isPresented: $showingRenameButton) {
            TextField("Button name", text: $proposedButtonName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                bleVM.renameConnectedButton(to: proposedButtonName)
            }
            .disabled(proposedButtonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if bleVM.currentButtonName != "ClipIt Button" {
                Button("Use Default Name") {
                    bleVM.resetConnectedButtonName()
                }
            }
        } message: {
            Text("This name is saved on your ClipIt Button and appears on every phone that scans for it. Use up to 23 letters, numbers, spaces, hyphens, apostrophes, or underscores.")
        }
        .alert("Turn On Auto-Reconnect?", isPresented: $showingAutoReconnectConfirmation) {
            Button("Not Now", role: .cancel) {}
            Button("Turn On") {
                bleVM.setAutoReconnect(true)
            }
        } message: {
            Text("Only turn Auto-Reconnect on if you own your own ClipIt Button. Shared buttons can connect to a nearby phone that used them previously.")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "button.programmable.square")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.crimsonBlaze)
                    .frame(width: 64, height: 64)
                    .background(Color.crimsonBlaze.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 4) {
                        Text(bleVM.currentButtonName)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.cosmosBlue)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if bleVM.connectedButtonID != nil {
                            Button {
                                beginRenaming()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.crimsonBlaze)
                            .accessibilityLabel("Rename \(bleVM.currentButtonName)")
                        }
                    }

                    HStack(spacing: 7) {
                        if bleVM.bleState.isConnected {
                            Image(systemName: "link")
                        } else {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                        }

                        Text(statusLabel)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(statusColor.opacity(0.11), in: Capsule())

                    if let buttonID = bleVM.connectedButtonID {
                        Text("Button ID \(String(buttonID.uuidString.suffix(4)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(statusDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let commandError = bleVM.commandError {
                Label(commandError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.crimsonBlaze)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let transferStatus = bleVM.lastClipTransferStatus {
                Text("Clip transfer: \(transferStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pending = bleVM.pendingButtonClips, isConnected {
                Text(pending == 0
                     ? "Button clip queue is clear."
                     : "Button has \(pending) clip \(pending == 1 ? "tap" : "taps") awaiting acknowledgment.")
                    .font(.footnote)
                    .foregroundStyle(pending == 0 ? Color.secondary : Color.crimsonBlaze)
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

                if bleVM.remoteBatteryCharging == true {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if bleVM.remoteUSBConnected == true {
                    Text("USB connected · not charging")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        bleVM.disconnect()
                    } label: {
                        Text("Disconnect Button")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Color.red.opacity(0.08), in: Capsule())
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
                            .foregroundStyle(.white)
                            .background(Color.crimsonBlaze, in: RoundedRectangle(cornerRadius: 15))
                            .contentShape(RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                }

                if !isConnecting && !bleVM.discoveredDevices.isEmpty {
                    nearbyDevicesCard
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
                HStack(spacing: 0) {
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
                                Text(bleVM.displayName(for: device.name))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("ID \(String(device.id.uuidString.suffix(4))) · \(signalDescription(for: device.rssi))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.crimsonBlaze)
                        }
                        .padding(.leading, 18)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Connect to \(bleVM.displayName(for: device.name))")
                }
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var settingsCard: some View {
        Toggle(isOn: Binding(
            get: { bleVM.autoReconnect },
            set: { enabled in
                if enabled {
                    showingAutoReconnectConfirmation = true
                } else {
                    bleVM.setAutoReconnect(false)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-reconnect")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Off by default. Use only with a button you personally own.")
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

    private func beginRenaming() {
        proposedButtonName = bleVM.currentButtonName == "ClipIt Button" ? "" : bleVM.currentButtonName
        showingRenameButton = true
    }

    private func batteryColor(for level: Int) -> Color {
        level <= 20 ? .red : .green
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
    @AppStorage(NotificationManager.notificationsEnabledDefaultsKey) private var notificationsEnabled = false
    @State private var showOriginalVideoInfo = false
    @State private var showNotificationPermissionAlert = false
    
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
                    .tutorialTarget(.dimScreen)
                }
                
                Section("Notifications") {
                    SettingsRow(icon: "bell.badge.fill", color: .red, label: "Notifications") {
                        Toggle("Notifications", isOn: $notificationsEnabled)
                            .labelsHidden()
                    }
                }
                .onChange(of: notificationsEnabled) { _, isEnabled in
                    if isEnabled {
                        Task {
                            let granted = await NotificationManager.shared.requestPermission()
                            if granted {
                                recordingVM.refreshOriginalVideoDeletionReminders()
                            } else {
                                notificationsEnabled = false
                                showNotificationPermissionAlert = true
                            }
                        }
                    } else {
                        recordingVM.refreshOriginalVideoDeletionReminders()
                    }
                }
                .alert("Notifications Are Off", isPresented: $showNotificationPermissionAlert) {
                    Button("Not Now", role: .cancel) { }
                    Button("Open Settings") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(settingsURL)
                    }
                } message: {
                    Text("Allow notifications for ClipIt in iPhone Settings to receive original-video auto-delete reminders.")
                }
                
                Section("Storage") {
                    SettingsRow(icon: "internaldrive.fill", color: .cosmosBlue, label: "Storage Used") {
                        Text(recordingVM.localStoreSize)
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }

                    SettingsRow(icon: "trash.circle", color: .gray, label: "Delete Original\nVideos") {
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
                    .tutorialTarget(.retention)
                }
                .onChange(of: originalVideoRetentionDays) { _, days in
                    recordingVM.applyOriginalVideoRetention(days: days)
                }
                .alert("Original Video Auto-Delete", isPresented: $showOriginalVideoInfo) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Need more storage space? Choose how you'd like to manage your Original Videos. Deleting them automatically saves device space, while your other clips will stay saved in your gallery.")
                }
                
                Section("Bluetooth") {
                    NavigationLink(destination: BLEDeviceView()) {
                        SettingsRow(icon: "button.programmable.square", color: .crimsonBlaze, label: "ClipIt Button") {
                            Text("Configure").foregroundColor(.secondary).font(.system(size: 14))
                        }
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
            }
            .task {
                NotificationManager.shared.migrateLegacyNotificationPreferenceIfNeeded()
                notificationsEnabled = NotificationManager.shared.notificationsEnabled
                let status = await NotificationManager.shared.authorizationStatus()
                if status == .denied && notificationsEnabled {
                    notificationsEnabled = false
                    recordingVM.refreshOriginalVideoDeletionReminders()
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
