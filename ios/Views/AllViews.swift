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
    let isSelected: Bool = true
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
    let isSelected: Bool
    @EnvironmentObject var bleVM: BLEViewModel
    @EnvironmentObject private var tutorial: TutorialController
    @State private var showingRenameButton = false
    @State private var proposedButtonName = ""
    @State private var showingButtonInfo = false
    @State private var buttonEducationSlide = 0
    @State private var isProductPhotoPulsing = false

    private let buttonEducationSlides: [(image: String, detail: String)] = [
        ("ClipItSetupIllustration", "Place your phone on a tripod and hold the ClipIt Button for 3 seconds to start and stop recording."),
        ("ClipItTapIllustration", "Press your ClipIt Button remotely when a great clip happens, without touching your phone!"),
        ("ClipItSavedIllustration", "Your highlights are saved automatically and ready in your ClipIt Library after recording.")
    ]

    private var isConnected: Bool { bleVM.bleState.isConnected }
    private var isConnecting: Bool {
        if case .connecting = bleVM.bleState { return true }
        return false
    }

    private var statusDetail: String {
        switch bleVM.bleState {
        case .connected:
            return "Ready to ClipIt!"
        case .connecting:
            return "Connecting..."
        case .scanning:
            if bleVM.isWaitingForManualButtonSelection {
                return "Turn on ClipIt Button to begin pairing."
            }
            return "Turn on ClipIt Button to begin pairing."
        case .poweredOff:
            return ""
        case .disconnected:
            if bleVM.isWaitingForManualButtonSelection {
                return "Choose your button from the nearby list to reconnect."
            }
            return "Turn on your button and it will appear below."
        }
    }

    private var statusLabel: String {
        switch bleVM.bleState {
        case .connected: return "Connected"
        case .connecting, .scanning, .poweredOff, .disconnected: return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch bleVM.bleState {
        case .connected: return .green
        case .connecting, .scanning, .poweredOff, .disconnected: return .crimsonBlaze
        }
    }

    var body: some View {
        ZStack {
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

            if showingButtonInfo {
                buttonEducationWindow
            }
        }
        .onAppear {
            scanForNearbyButtonsIfNeeded()
            updateProductPhotoPulse()
        }
        .onChange(of: isSelected) { _, _ in
            // TabView keeps each tab alive. Start a fresh discovery pass when
            // Device becomes visible instead of relying on `.onAppear` again.
            scanForNearbyButtonsIfNeeded()
        }
        .onChange(of: bleVM.bleState) { _, state in
            // The Device screen behaves like the system Bluetooth screen:
            // keep looking while it is visible, without requiring a Scan tap.
            if case .disconnected = state {
                scanForNearbyButtonsIfNeeded()
            }
            updateProductPhotoPulse()
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
            Text("Personalize your ClipIt Button by giving it a unique name!")
        }
    }

    private func scanForNearbyButtonsIfNeeded() {
        guard isSelected, !tutorial.isActive, !isConnected, !isConnecting else { return }
        bleVM.startScanning()
    }

    private func updateProductPhotoPulse() {
        guard !isConnected else {
            withAnimation(.easeOut(duration: 0.2)) {
                isProductPhotoPulsing = false
            }
            return
        }

        isProductPhotoPulsing = false
        DispatchQueue.main.async {
            guard !isConnected else { return }
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                isProductPhotoPulsing = true
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 4) {
                Text(bleVM.currentButtonName)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cosmosBlue)
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

                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
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

                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let commandError = bleVM.commandError {
                    HStack(alignment: .top, spacing: 8) {
                        Label(commandError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.crimsonBlaze)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)

                        Button("OK") {
                            bleVM.dismissCommandError()
                        }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.cosmosBlue)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss button message")
                    }
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

                        Spacer(minLength: 0)
                    }
                }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    buttonEducationSlide = 0
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        showingButtonInfo = true
                    }
                } label: {
                ZStack(alignment: .topTrailing) {
                    Image("ClipItButtonProduct")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112)
                        .scaleEffect(isConnected ? 1 : (isProductPhotoPulsing ? 1.07 : 0.95))

                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.cosmosBlue)
                        .padding(3)
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: Circle())
                        .accessibilityHidden(true)
                }
                .frame(width: 118, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Learn about the ClipIt Button")
            .accessibilityHint("Opens information about the physical ClipIt Button")
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
                Label("Turn on Bluetooth to find your ClipIt Button.", systemImage: "antenna.radiowaves.left.and.right")
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
                }

                if !isConnecting {
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

            if bleVM.discoveredDevices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.blueMarble)
                    Text("Looking for nearby ClipIt Buttons…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
                                Text(bleVM.displayName(for: device.name))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
//                                Text("ID \(String(device.id.uuidString.suffix(4))) · \(signalDescription(for: device.rssi))")
//                                    .font(.caption)
//                                    .foregroundStyle(.secondary)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Connect to \(bleVM.displayName(for: device.name))")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: Binding(
                get: { bleVM.autoReconnect },
                set: { enabled in
                    bleVM.setAutoReconnect(enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-reconnect")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Automatically reconnect to your ClipIt Button after turning off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.crimsonBlaze)
            .padding(18)
            .background(
                Color(UIColor.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )

            Text("A ClipIt Button is optional. You can also use the on-screen ClipIt button as you Record.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
    }

    private var buttonEducationWindow: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .transition(.opacity)

            GeometryReader { geometry in
                let compactHeight = geometry.size.height < 700
                let veryCompactHeight = geometry.size.height < 500
                let artworkHeight: CGFloat = veryCompactHeight ? 105 : (compactHeight ? 160 : 410)
                let slideshowHeight: CGFloat = veryCompactHeight ? 215 : (compactHeight ? 290 : 520)
                let windowHeight = min(
                    geometry.size.height - 40,
                    veryCompactHeight ? 320 : (compactHeight ? 410 : 650)
                )

                ZStack(alignment: .topTrailing) {
                    VStack(spacing: compactHeight ? 8 : 14) {
                        TabView(selection: $buttonEducationSlide) {
                            ForEach(Array(buttonEducationSlides.enumerated()), id: \.offset) { index, slide in
                                Image(slide.image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: artworkHeight)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: compactHeight ? 16 : 22, style: .continuous))
                                    .padding(.horizontal, 2)
                                    .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: artworkHeight)

                        HStack(spacing: 7) {
                            ForEach(buttonEducationSlides.indices, id: \.self) { index in
                                Circle()
                                    .fill(index == buttonEducationSlide ? Color.crimsonBlaze : Color.crimsonBlaze.opacity(0.28))
                                    .frame(width: index == buttonEducationSlide ? 9 : 7, height: index == buttonEducationSlide ? 9 : 7)
                            }
                        }
                        .frame(height: compactHeight ? 12 : 16)
                        .accessibilityLabel("Tutorial step \(buttonEducationSlide + 1) of \(buttonEducationSlides.count)")

                        Text(buttonEducationSlides[buttonEducationSlide].detail)
                            .font(compactHeight ? .footnote : .subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: slideshowHeight - artworkHeight - (compactHeight ? 20 : 28), alignment: .top)

                        Link(destination: URL(string: "https://www.clipitbutton.com/products")!) {
                            HStack(spacing: 8) {
                                Image("ClipItButtonProduct")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 48, height: 52)
                                    .accessibilityHidden(true)

                                Text("Shop ClipIt Button")
                                Image(systemName: "arrow.up.right")
                            }
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.cosmosBlue)
                                .frame(maxWidth: .infinity)
                                .frame(height: compactHeight ? 50 : 62)
                                .background(Color.yellow, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, compactHeight ? 14 : 24)

                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            showingButtonInfo = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                    .accessibilityLabel("Close ClipIt Button information")
                }
                .frame(maxWidth: min(560, geometry.size.width - 32), minHeight: windowHeight, maxHeight: windowHeight)
                .background(Color(red: 0.99, green: 0.975, blue: 0.92), in: RoundedRectangle(cornerRadius: 28))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .strokeBorder(Color.blueMarble.opacity(0.18), lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.88)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
        ))
        .zIndex(20)
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
                    Text("Choose how you'd like the app to manage your large Original Videos. Deleting them automatically saves device space, while your other clips will stay saved in your gallery. Just remember you will lose the ability to edit individual clips when their Original Video is deleted!")
                }
                
                Section("Bluetooth") {
                    NavigationLink(destination: BLEDeviceView(isSelected: true)) {
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
