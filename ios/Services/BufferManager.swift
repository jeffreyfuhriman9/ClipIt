import Foundation
import AVFoundation
import Combine

final class BufferManager {

    var bufferSeconds: Int = 10
    var postRollSeconds: Int = 10

    // Separate storage arrays to prevent video/audio synchronization drift
    private var videoRingBuffer: [CMSampleBuffer] = []
    private var audioRingBuffer: [CMSampleBuffer] = []
    
    private var isBuffering: Bool = false
    private var currentMode: RecordingMode = .highlightsOnly
    private var cancellables = Set<AnyCancellable>()
    private let bufferQueue = DispatchQueue(label: "com.clipit.buffer", qos: .userInitiated)

    private var postRollVideoBuffers: [CMSampleBuffer] = []
    private var postRollAudioBuffers: [CMSampleBuffer] = []
    
    private var isCapturingPostRoll: Bool = false
    private var postRollTargetFrames: Int = 0
    private var postRollCompletion: (() -> Void)?

    private var estimatedFPS: Double = 30.0
    private var frameCount: Int = 0
    private var fpsWindowStart: Date = Date()

    private var videoWidth: Int = 1920
    private var videoHeight: Int = 1080
    private var pixelFormatType: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    // MARK: - Setup

    func startBuffering(mode: RecordingMode, cameraManager: CameraManager) {
        currentMode = mode
        isBuffering = true
        videoRingBuffer.removeAll()
        audioRingBuffer.removeAll()
        postRollVideoBuffers.removeAll()
        postRollAudioBuffers.removeAll()
        frameCount = 0
        fpsWindowStart = Date()

        guard mode == .highlightsOnly else { return }

        cameraManager.sampleBufferPublisher
            .receive(on: bufferQueue)
            .sink { [weak self] sampleBuffer in
                self?.handleIncomingBuffer(sampleBuffer)
            }
            .store(in: &cancellables)
    }

    func stopBuffering() {
        isBuffering = false
        cancellables.removeAll()
        videoRingBuffer.removeAll()
        audioRingBuffer.removeAll()
        postRollVideoBuffers.removeAll()
        postRollAudioBuffers.removeAll()
    }

    // MARK: - Buffer Routing Pipeline

    private func handleIncomingBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isBuffering else { return }

        // Retain memory safely
        var copied: CMSampleBuffer?
        CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleBufferOut: &copied)
        guard let retainedBuffer = copied else { return }

        // Route buffer based on media track classification
        if CMSampleBufferGetImageBuffer(retainedBuffer) != nil {
            // Processing Video Buffer
            if let pb = CMSampleBufferGetImageBuffer(retainedBuffer) {
                videoWidth      = CVPixelBufferGetWidth(pb)
                videoHeight     = CVPixelBufferGetHeight(pb)
                pixelFormatType = CVPixelBufferGetPixelFormatType(pb)
            }
            
            updateFPSEstimate()
            videoRingBuffer.append(retainedBuffer)
            
            let maxVideoFrames = Int(estimatedFPS * Double(bufferSeconds))
            if videoRingBuffer.count > maxVideoFrames {
                videoRingBuffer.removeFirst(videoRingBuffer.count - maxVideoFrames)
            }
            
            if isCapturingPostRoll {
                postRollVideoBuffers.append(retainedBuffer)
                checkPostRollStatus()
            }
            
        } else {
            // Processing Audio Buffer
            audioRingBuffer.append(retainedBuffer)
            
            // Retain roughly double the asset seconds in audio frames to prevent boundary cutoff
            let maxAudioBuffers = Int(50 * bufferSeconds)
            if audioRingBuffer.count > maxAudioBuffers {
                audioRingBuffer.removeFirst(audioRingBuffer.count - maxAudioBuffers)
            }
            
            if isCapturingPostRoll {
                postRollAudioBuffers.append(retainedBuffer)
            }
        }
    }

    private func updateFPSEstimate() {
        frameCount += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 2.0 {
            estimatedFPS = Double(frameCount) / elapsed
            frameCount = 0
            fpsWindowStart = Date()
        }
    }

    private func checkPostRollStatus() {
        if postRollVideoBuffers.count >= postRollTargetFrames {
            isCapturingPostRoll = false
            postRollCompletion?()
            postRollCompletion = nil
        }
    }

    // MARK: - Clip Extraction

    func extractClip(clip: Clip, completion: @escaping (URL?) -> Void) {
        guard currentMode == .highlightsOnly else {
            completion(nil)
            return
        }

        bufferQueue.async { [weak self] in
            guard let self = self else { return }

            let preRollV = self.videoRingBuffer
            let preRollA = self.audioRingBuffer

            guard !preRollV.isEmpty else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if self.postRollSeconds == 0 {
                let url = self.outputURL(for: clip)
                self.writeMediaPool(video: preRollV, audio: preRollA, to: url, completion: completion)
                return
            }

            let runtimePostRoll = self.postRollSeconds == 0 ? 0.5 : Double(self.postRollSeconds)
            let postTarget = max(1, Int(self.estimatedFPS * runtimePostRoll))
            
            self.postRollVideoBuffers.removeAll()
            self.postRollAudioBuffers.removeAll()
            self.postRollTargetFrames = postTarget
            self.isCapturingPostRoll = true

            self.postRollCompletion = { [weak self] in
                guard let self = self else { return }
                let finalVideo = preRollV + self.postRollVideoBuffers
                let finalAudio = preRollA + self.postRollAudioBuffers
                let url = self.outputURL(for: clip)
                self.writeMediaPool(video: finalVideo, audio: finalAudio, to: url, completion: completion)
            }
        }
    }

    // MARK: - AVAssetWriter Engine (Dual-Input Stream Audio + Video)

    private func writeMediaPool(video: [CMSampleBuffer], audio: [CMSampleBuffer], to url: URL, completion: @escaping (URL?) -> Void) {
        try? FileManager.default.removeItem(at: url)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let firstPTS = CMSampleBufferGetPresentationTimeStamp(video[0])

            // 1. Configure Video Layout
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            
            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormatType,
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: adaptorAttrs)
            
            if writer.canAdd(videoInput) { writer.add(videoInput) }

            // 2. Configure Audio Layout (Dynamic configuration derived from active recording session values)
            var audioInput: AVAssetWriterInput? = nil
            if let firstAudioBuffer = audio.first,
               let formatDescription = CMSampleBufferGetFormatDescription(firstAudioBuffer),
               let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: streamBasicDescription.pointee.mChannelsPerFrame,
                    AVSampleRateKey: streamBasicDescription.pointee.mSampleRate,
                    AVEncoderBitRateKey: 128_000
                ]
                
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioInput = aInput
                }
            }

            // 3. Begin Write Execution Loop
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            let writeQueue = DispatchQueue(label: "com.clipit.assetwriter")
            var videoIndex = 0
            var audioIndex = 0

            videoInput.requestMediaDataWhenReady(on: writeQueue) {
                // Interleave frame parsing arrays cleanly
                while videoInput.isReadyForMoreMediaData || (audioInput?.isReadyForMoreMediaData ?? false) {
                    
                    // Append available audio track data
                    if let aInput = audioInput, aInput.isReadyForMoreMediaData, audioIndex < audio.count {
                        let sample = audio[audioIndex]
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let shiftedPTS = CMTimeSubtract(pts, firstPTS)
                        
                        if shiftedPTS >= .zero {
                            // Copy the buffer to rewrite timing handles smoothly (using camelCase instead of a hyphen)
                            var timingInfo = CMSampleTimingInfo(
                                duration: CMSampleBufferGetDuration(sample),
                                presentationTimeStamp: shiftedPTS,
                                decodeTimeStamp: .invalid
                            )
                            var retimedSample: CMSampleBuffer?
                            
                            if CMSampleBufferCreateCopyWithNewTiming(
                                allocator: kCFAllocatorDefault,
                                sampleBuffer: sample,
                                sampleTimingEntryCount: 1,
                                sampleTimingArray: &timingInfo,
                                sampleBufferOut: &retimedSample
                            ) == noErr,
                               let readyAudio = retimedSample {
                                aInput.append(readyAudio)
                            }
                        }
                        audioIndex += 1
                        continue
                    }
                    
                    // Append available video frame data
                    if videoInput.isReadyForMoreMediaData, videoIndex < video.count {
                        let buffer = video[videoIndex]
                        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                        let shiftedPTS = CMTimeSubtract(pts, firstPTS)
                        
                        if let pb = CMSampleBufferGetImageBuffer(buffer) {
                            adaptor.append(pb, withPresentationTime: shiftedPTS)
                        }
                        videoIndex += 1
                        continue
                    }

                    // Complete writing once frame processing arrays deplete
                    if videoIndex >= video.count && (audioIndex >= audio.count || audioInput == nil) {
                        videoInput.markAsFinished()
                        audioInput?.markAsFinished()
                        
                        writer.finishWriting {
                            DispatchQueue.main.async {
                                completion(writer.status == .completed ? url : nil)
                            }
                        }
                        return
                    }
                }
            }
        } catch {
            DispatchQueue.main.async { completion(nil) }
        }
    }

    private func outputURL(for clip: Clip) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(clip.id.uuidString).mov")
    }
}
