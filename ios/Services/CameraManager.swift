import Foundation
import AVFoundation
import Combine
import QuartzCore

final class CameraManager: NSObject, ObservableObject {

    @Published var isRunning: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var error: CameraError?

    // Camera controls
    @Published var zoomFactor: CGFloat = 2.0
    @Published var minZoom: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 5.0
    @Published private(set) var isUsingFrontCamera = false
    @Published private(set) var isSwitchingCamera = false
    let supportsCameraFlip = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    @Published var exposureBias: Float = 0.0  // -2.0 to +2.0
    @Published var videoQuality: VideoQuality = .hd1080p
    @Published var isVideoStabilizationEnabled: Bool = true

    let movieFileReady = PassthroughSubject<URL, Never>()
    let session = AVCaptureSession()
    let sampleBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    let recordingStarted = PassthroughSubject<Void, Never>()
    let recordingFailed = PassthroughSubject<String, Never>()

    private let sessionQueue = DispatchQueue(label: "com.clipit.camera.session", qos: .userInitiated)
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var movieFileOutput: AVCaptureMovieFileOutput?
    private weak var activePreviewLayer: AVCaptureVideoPreviewLayer?
    // Accessed only on sessionQueue. Uncover the camera after the replacement
    // input has delivered a frame, rather than immediately after configuration.
    private var pendingCameraSwitchFrame: (() -> Void)?

    @available(iOS 17.0, *)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var currentCaptureRotationAngle: CGFloat = 0
    private var latestCaptureRotationAngle: CGFloat = 0
    private var activeMovieURL: URL?
    private let recordingRotationLock = NSLock()
    private var recordingRotationLocked = false

    var displayZoomFactor: CGFloat {
        zoomFactor / (isUsingFrontCamera ? 1.0 : 2.0)
    }

    func hardwareZoomFactor(for displayZoomFactor: CGFloat) -> CGFloat {
        displayZoomFactor * (isUsingFrontCamera ? 1.0 : 2.0)
    }

    private var isRecordingRotationLocked: Bool {
        recordingRotationLock.lock()
        defer { recordingRotationLock.unlock() }
        return recordingRotationLocked
    }

    private func setRecordingRotationLocked(_ locked: Bool) {
        recordingRotationLock.lock()
        recordingRotationLocked = locked
        recordingRotationLock.unlock()
    }

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
                self.configureContinuousCenterFocus()
                
                DispatchQueue.main.async { self.isRunning = true }
            }
        }

    private func configureBaseSession() {
        session.beginConfiguration()
        session.sessionPreset = videoQuality.sessionPreset

        // 1. Discover the best multi-camera hardware combination available on this device
        guard let videoDevice = cameraDevice(for: .back),
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

    private func cameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInUltraWideCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        ).devices.first
    }

    // Switch inputs only between recordings; the movie and microphone outputs
    // stay attached to the same session, so no recording pipeline is rebuilt.
    func flipCamera(completion: @escaping (Bool) -> Void) {
        guard permissionGranted, isRunning, !isSwitchingCamera else {
            completion(false)
            return
        }
        isSwitchingCamera = true

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let oldInput = self.videoInput,
                  self.movieFileOutput?.isRecording != true,
                  !self.isRecordingRotationLocked else {
                DispatchQueue.main.async {
                    self.isSwitchingCamera = false
                    completion(false)
                }
                return
            }

            let position: AVCaptureDevice.Position = oldInput.device.position == .front ? .back : .front
            guard let newDevice = self.cameraDevice(for: position),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else {
                DispatchQueue.main.async {
                    self.isSwitchingCamera = false
                    completion(false)
                }
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            guard self.session.canAddInput(newInput) else {
                self.session.addInput(oldInput)
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.isSwitchingCamera = false
                    completion(false)
                }
                return
            }
            self.session.addInput(newInput)

            let preferredPreset = self.videoQuality.sessionPreset
            var downgradedQuality = false
            if self.session.canSetSessionPreset(preferredPreset) {
                self.session.sessionPreset = preferredPreset
            } else if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
                downgradedQuality = true
            }
            self.session.commitConfiguration()

            self.videoInput = newInput
            self.configureContinuousCenterFocus()

            let minAvailable = newDevice.minAvailableVideoZoomFactor
            let maxAvailable = min(newDevice.maxAvailableVideoZoomFactor, 10.0)
            let baseline: CGFloat = position == .front ? 1.0 : 2.0
            let targetZoom = baseline.clamped(to: minAvailable...maxAvailable)
            do {
                try newDevice.lockForConfiguration()
                newDevice.videoZoomFactor = targetZoom
                newDevice.unlockForConfiguration()
            } catch {
                print("[CameraManager] Could not set zoom after camera switch: \(error)")
            }

            self.applyVideoStabilization()
            let qualityDowngraded = downgradedQuality
            DispatchQueue.main.async {
                self.isUsingFrontCamera = position == .front
                self.minZoom = minAvailable
                self.maxZoom = maxAvailable
                self.zoomFactor = targetZoom
                if qualityDowngraded { self.videoQuality = .hd1080p }
                if let previewLayer = self.activePreviewLayer {
                    self.attachPreviewLayer(previewLayer)
                }
                self.sessionQueue.async {
                    let finishSwitch = {
                        DispatchQueue.main.async {
                            self.isSwitchingCamera = false
                            completion(true)
                        }
                    }
                    self.pendingCameraSwitchFrame = finishSwitch
                    self.sessionQueue.asyncAfter(deadline: .now() + 1.5) {
                        guard let finish = self.pendingCameraSwitchFrame else { return }
                        self.pendingCameraSwitchFrame = nil
                        finish()
                    }
                }
            }
        }
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
                    let baseline: CGFloat = self.isUsingFrontCamera ? 1.0 : 2.0
                    let targetZoom = baseline.clamped(to: minAvailable...maxAvailable)
                    
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
    func configureContinuousCenterFocus() {
        guard let videoDevice = videoInput?.device else {
            print("❌ Camera device could not be reached for focusing rules.")
            return
        }
        
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
            print("🎯 Camera successfully locked to continuous center auto-focus.")
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
            if previewLayer.session !== session { previewLayer.session = session }
            previewLayer.videoGravity = .resizeAspectFill
            activePreviewLayer = previewLayer

            if let connection = previewLayer.connection,
               connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = videoInput?.device.position == .front
            }

            guard let device = videoInput?.device else { return }

            if #available(iOS 17.0, *) {
                previewRotationObservation = nil
                captureRotationObservation = nil

                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                rotationCoordinator = coordinator

                previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak previewLayer] coordinator, _ in
                    guard let previewLayer else { return }
                    
                    let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                    // The coordinator calls this observer on the main queue.
                    // Update the live preview immediately as the phone moves;
                    // only the recorded outputs keep their starting angle.
                    guard let connection = previewLayer.connection,
                          connection.isVideoRotationAngleSupported(angle) else { return }
                    connection.videoRotationAngle = angle
                }

                captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
                    guard let self else { return }
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    self.applyCaptureRotationToOutputs(angle)
                }
            }
        }

    func detachPreviewLayer() {
        previewRotationObservation = nil
        captureRotationObservation = nil
        activePreviewLayer = nil
        if #available(iOS 17.0, *) { rotationCoordinator = nil }
    }

    private func applyCaptureRotationToOutputs(_ angle: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.latestCaptureRotationAngle = angle
            self.applyCaptureRotationOnSessionQueue(angle)
        }
    }

    private func applyCaptureRotationOnSessionQueue(_ angle: CGFloat) {
        // Freeze both output connections from the moment recording is
        // requested. `movieFileOutput.isRecording` becomes true later, leaving
        // a window where rotating could otherwise abort the movie file.
        guard !isRecordingRotationLocked else { return }
        currentCaptureRotationAngle = angle

        if let connection = movieFileOutput?.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        if let connection = videoDataOutput?.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Recording

    func startMovieRecording(to url: URL) {
        guard let movieOutput = movieFileOutput else {
            recordingFailed.send("Camera is not ready to record.")
            return
        }
        setRecordingRotationLocked(true)
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
            
            self.activeMovieURL = url
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
                    self.configureContinuousCenterFocus()
                    
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
                    self.configureContinuousCenterFocus()
                    
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
        if let finish = pendingCameraSwitchFrame {
            pendingCameraSwitchFrame = nil
            finish()
        }
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
        if let error { print("[CameraManager] movie recording error: \(error)") }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.activeMovieURL == outputFileURL {
                self.activeMovieURL = nil
                self.setRecordingRotationLocked(false)
                self.applyCaptureRotationOnSessionQueue(self.latestCaptureRotationAngle)
            }
            DispatchQueue.main.async {
                if #available(iOS 17.0, *),
                   let previewLayer = self.activePreviewLayer,
                   let coordinator = self.rotationCoordinator {
                    let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                    if let connection = previewLayer.connection,
                       connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
                let fileSize = (try? FileManager.default.attributesOfItem(
                    atPath: outputFileURL.path
                )[.size] as? NSNumber)?.intValue ?? 0
                if let error {
                    self.recordingFailed.send("Recording failed: \(error.localizedDescription)")
                } else if FileManager.default.fileExists(atPath: outputFileURL.path),
                          fileSize > 0 {
                    self.movieFileReady.send(outputFileURL)
                } else {
                    self.recordingFailed.send("Recording produced no video file.")
                }
            }
        }
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
