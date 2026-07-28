import Foundation
import AVFoundation
import Combine
import QuartzCore
import UIKit

final class CameraManager: NSObject, ObservableObject {

    @Published var isRunning: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var error: CameraError?

    // Camera controls
    @Published var zoomFactor: CGFloat = 2.0
    @Published var minZoom: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 5.0
    @Published var exposureBias: Float = 0.0  // -2.0 to +2.0
    @Published var videoQuality: VideoQuality = .hd1080p
    @Published var isVideoStabilizationEnabled: Bool = true

    let movieFileReady = PassthroughSubject<URL, Never>()
    let session = AVCaptureSession()
    let sampleBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    let recordingStarted = PassthroughSubject<Void, Never>()

    private let sessionQueue = DispatchQueue(label: "com.clipit.camera.session", qos: .userInitiated)
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var movieFileOutput: AVCaptureMovieFileOutput?

    @available(iOS 17.0, *)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var currentCaptureRotationAngle: CGFloat = 0

    // MARK: - Video Quality

    enum VideoQuality: String, CaseIterable, Identifiable {
        case hd720p  = "720p HD"
        case hd1080p = "1080p HD"
        case uhd4K   = "4K"

        var id: String { rawValue }

        var sessionPreset: AVCaptureSession.Preset {
            switch self {
            case .hd720p:  return .hd1280x720
            case .hd1080p: return .hd1920x1080
            case .uhd4K:   return .hd4K3840x2160
            }
        }
    }

    // MARK: - Permission & Setup

    func requestPermissionAndSetup() {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch (videoStatus, audioStatus) {
        case (.authorized, .authorized):
            permissionGranted = true
            setupSession()

        case (.notDetermined, _), (_, .notDetermined):
            AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
                guard let self else { return }
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioGranted in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let granted = videoGranted && audioGranted
                        self.permissionGranted = granted
                        if granted { self.setupSession() } else { self.error = .permissionDenied }
                    }
                }
            }

        default:
            DispatchQueue.main.async {
                self.permissionGranted = false
                self.error = .permissionDenied
            }
        }
    }

    private func setupSession() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                    try audioSession.setActive(true)
                } catch {
                    print("[CameraManager] Failed to configure audio session: \(error)")
                }
                self.configureBaseSession()
                self.session.startRunning()
                
                // Lock the autofocus engine to the dead-center immediately upon camera launch
                Task { @MainActor in
                    self.configureContinuousCenterFocus()
                }
                DispatchQueue.main.async { self.isRunning = true }
            }
        }

    private func configureBaseSession() {
        session.beginConfiguration()
        session.sessionPreset = videoQuality.sessionPreset

        // 1. Discover the best multi-camera hardware combination available on this device
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInUltraWideCamera, // Fallback for specific device types
            .builtInWideAngleCamera
        ]
        
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .back
        )
        
        guard let videoDevice = discoverySession.devices.first,
              let vInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(vInput) else {
            DispatchQueue.main.async { self.error = .deviceUnavailable }
            session.commitConfiguration()
            return
        }
        session.addInput(vInput)
        videoInput = vInput

        // 2. Audio Input
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let aInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(aInput) {
            session.addInput(aInput)
            audioInput = aInput
        }

        // 3. Video Data Output
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(dataOutput) {
            session.addOutput(dataOutput)
            videoDataOutput = dataOutput
        }

        // 4. Movie File Output
        let movieOut = AVCaptureMovieFileOutput()
        movieOut.movieFragmentInterval = .invalid
        
        if session.canAddOutput(movieOut) {
            session.addOutput(movieOut)
            self.movieFileOutput = movieOut
        }

        // Commit the setup first so AVFoundation doesn't overwrite our zoom!
        session.commitConfiguration()

        // Apply zoom, focus, and exposure locking AFTER committing the session
        if let device = videoInput?.device {
            do {
                try device.lockForConfiguration()
                
                // 1. Force hardware to 2.0 (1x UI Lens) on startup
                let minAvailable = device.minAvailableVideoZoomFactor
                let maxAvailable = min(device.maxAvailableVideoZoomFactor, 10.0)
                let startingZoom: CGFloat = maxAvailable >= 2.0 ? 2.0 : minAvailable
                
                device.videoZoomFactor = startingZoom
                
                // 2. Lock continuous autofocus and autoexposure
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                
                device.unlockForConfiguration()
                
                // 3. Sync the final starting bounds to the UI properties
                DispatchQueue.main.async {
                    self.minZoom = minAvailable
                    self.maxZoom = maxAvailable
                    self.zoomFactor = startingZoom
                }
                
            } catch {
                print("[CameraManager] Could not set continuous autofocus/exposure/zoom: \(error)")
            }
        }

        applyVideoStabilization()
    }
    
    // MARK: - Video Stabilization

    private func applyVideoStabilization() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let connection = self.movieFileOutput?.connection(with: .video),
               connection.isVideoStabilizationSupported {
                if self.isVideoStabilizationEnabled {
                    if #available(iOS 18.0, *) {
                        connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                    } else {
                        connection.preferredVideoStabilizationMode = .cinematic
                    }
                } else {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
        }
    }

    func setStabilization(_ enabled: Bool) {
        DispatchQueue.main.async { self.isVideoStabilizationEnabled = enabled }
        applyVideoStabilization()
    }

    // MARK: - Quality change (live, between recordings)

    func setVideoQuality(_ quality: VideoQuality) {
        guard quality != videoQuality else { return }
        
        // Update inner tracking token on main thread immediately
        DispatchQueue.main.async {
            self.videoQuality = quality
        }
        
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(quality.sessionPreset) {
                self.session.sessionPreset = quality.sessionPreset
            }
            self.session.commitConfiguration() // Wipes out hardware zoom factor to 0.5x
            
            // Restore our baseline 1x UI zoom (2.0 hardware scale)
            if let device = self.videoInput?.device {
                do {
                    try device.lockForConfiguration()
                    
                    let minAvailable = device.minAvailableVideoZoomFactor
                    let maxAvailable = min(device.maxAvailableVideoZoomFactor, 10.0)
                    let targetZoom: CGFloat = maxAvailable >= 2.0 ? 2.0 : minAvailable
                    
                    device.videoZoomFactor = targetZoom
                    device.unlockForConfiguration()
                    
                    DispatchQueue.main.async {
                        self.zoomFactor = targetZoom
                    }
                } catch {
                    print("[CameraManager] Error resetting zoom factor: \(error)")
                }
            }
        }
    }
    
    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let clamped = factor.clamped(to: minZoom...maxZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clamped }
        } catch {
            print("[CameraManager] zoom error: \(error)")
        }
    }

    func changeZoom(by delta: CGFloat) {
        setZoom(zoomFactor * delta)
    }

    // MARK: - Focus & Exposure (tap to focus)

    func focusAndExpose(at point: CGPoint, in previewLayer: AVCaptureVideoPreviewLayer) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        guard let device = videoInput?.device else { return }

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        } catch {
            print("[CameraManager] focus error: \(error)")
        }
    }

    func resetFocusAndExposure() {
        configureContinuousCenterFocus()
    }
    
    // MARK: - Core Center Focus Controls
    @MainActor // 🌟 This ensures UIApplication is always checked safely on the main thread
    func configureContinuousCenterFocus() {
        // 🛑 1. Instantly exit if the phone is locked, inactive, or backgrounded
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        
        guard let videoDevice = videoInput?.device else {
            print("❌ Camera device could not be reached for focusing rules.")
            return
        }
        
        // Background threads are allowed to lock the hardware device, so we push that work off-main if needed,
        // but doing it here directly under @MainActor is perfectly safe and fast.
        do {
            try videoDevice.lockForConfiguration()
            let centerPoint = CGPoint(x: 0.5, y: 0.5)
            
            if videoDevice.isFocusPointOfInterestSupported {
                videoDevice.focusPointOfInterest = centerPoint
            }
            if videoDevice.isFocusModeSupported(.continuousAutoFocus) {
                videoDevice.focusMode = .continuousAutoFocus
            }
            if videoDevice.isExposurePointOfInterestSupported {
                videoDevice.exposurePointOfInterest = centerPoint
            }
            if videoDevice.isExposureModeSupported(.continuousAutoExposure) {
                videoDevice.exposureMode = .continuousAutoExposure
            }
            
            videoDevice.unlockForConfiguration()
        } catch {
            print("❌ Failed to lock camera device configurations: \(error.localizedDescription)")
        }
    }

    // MARK: - Brightness / Exposure Bias

    func setExposureBias(_ bias: Float) {
        guard let device = videoInput?.device else { return }
        let clamped = bias.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(clamped)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureBias = clamped }
        } catch {
            print("[CameraManager] exposure bias error: \(error)")
        }
    }

    // MARK: - Preview Layer

        func attachPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill

            guard let device = videoInput?.device else { return }

            if #available(iOS 17.0, *) {
                previewRotationObservation = nil
                captureRotationObservation = nil

                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                rotationCoordinator = coordinator

                // 🔥 THE FIX: Capture 'self' and check for active recording
                previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self, weak previewLayer] coordinator, _ in
                    guard let self = self, let previewLayer = previewLayer else { return }
                    
                    let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                    let isActivelyRecording = self.movieFileOutput?.isRecording ?? false
                    
                    DispatchQueue.main.async {
                        // Only spin the preview layer if we are NOT recording
                        if !isActivelyRecording {
                            guard let connection = previewLayer.connection,
                                  connection.isVideoRotationAngleSupported(angle) else { return }
                            connection.videoRotationAngle = angle
                        }
                    }
                }

                captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                    guard let self else { return }
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    self.currentCaptureRotationAngle = angle
                    self.applyCaptureRotationToOutputs(angle)
                }
            }
        }

    func detachPreviewLayer() {
        previewRotationObservation = nil
        captureRotationObservation = nil
        if #available(iOS 17.0, *) { rotationCoordinator = nil }
    }

    private func applyCaptureRotationToOutputs(_ angle: CGFloat) {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                
                // 🛑 THE FIX: Prevent changing orientation while actively writing to a file!
                // If we change this mid-recording, AVFoundation aborts the file immediately.
                let isActivelyRecording = self.movieFileOutput?.isRecording ?? false
                
                if !isActivelyRecording {
                    if let connection = self.movieFileOutput?.connection(with: .video),
                       connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
                
                // It is safe to update the video data output (used for live frame analysis)
                // even while recording, so we don't need to lock this one.
                if let connection = self.videoDataOutput?.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }

    // MARK: - Recording

    func startMovieRecording(to url: URL) {
        guard let movieOutput = movieFileOutput else { return }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 🔥 THE FIX: Check if a file already exists at this exact URL and delete it
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    print("[CameraManager] 🗑️ Cleaned up pre-existing file at: \(url.lastPathComponent)")
                } catch {
                    print("[CameraManager] ❌ Failed to clear existing file: \(error.localizedDescription)")
                }
            }
            
            if let connection = movieOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(self.currentCaptureRotationAngle) {
                connection.videoRotationAngle = self.currentCaptureRotationAngle
            }
            // Ensure stabilization is applied
            if let connection = movieOutput.connection(with: .video),
               connection.isVideoStabilizationSupported {
                if self.isVideoStabilizationEnabled {
                    if #available(iOS 18.0, *) {
                        connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                    } else {
                        connection.preferredVideoStabilizationMode = .cinematic
                    }
                } else {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
            
            // Now this call is guaranteed a clean, conflict-free file destination
            movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopMovieRecording() {
        sessionQueue.async { [weak self] in
            self?.movieFileOutput?.stopRecording()
        }
    }

    func startIfNeeded() {
            guard permissionGranted else {
                requestPermissionAndSetup()
                return
            }
            // FIX #6: Reset broken state if session is configured but not running
            if !session.isRunning {
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    // If there's an active movie recording, stop it first to clean up
                    if let movieOut = self.movieFileOutput, movieOut.isRecording {
                        movieOut.stopRecording()
                    }
                    self.session.startRunning()
                    
                    // 🔥 THE FIX: Re-lock focus on startup
                    Task { @MainActor in
                        self.configureContinuousCenterFocus()
                    }
                    DispatchQueue.main.async { self.isRunning = true }
                }
            }
        }

        // FIX #6: Called on app foreground to recover from interrupted state
        func recoverFromInterruption() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                    
                    // 🔥 THE FIX: Re-lock focus on app foreground recovery
                    Task { @MainActor in
                        self.configureContinuousCenterFocus()
                    }
                    DispatchQueue.main.async { self.isRunning = true }
                }
            }
        }
}

// MARK: - Comparable clamp helpers

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

extension Float {
    func clamped(to limits: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleBufferPublisher.send(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        #if DEBUG
        print("[CameraManager] dropped frame")
        #endif
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in self.recordingStarted.send() }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        if let error {
            let nsError = error as NSError
            print("[CameraManager] Movie stopped. Domain: \(nsError.domain) | Code: \(nsError.code) | Reason: \(nsError.localizedDescription)")
        }
        Task { @MainActor in self.movieFileReady.send(outputFileURL) }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case permissionDenied
    case deviceUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:  return "Camera access denied. Enable it in Settings."
        case .deviceUnavailable: return "Camera unavailable on this device."
        }
    }
}
