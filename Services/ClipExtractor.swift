import Foundation
import AVFoundation
import UIKit
import CoreImage
import CoreGraphics

// MARK: - ClipExtractor
//
// After a full session recording ends, this takes the full .mov file
// and extracts a short trimmed clip for each highlight timestamp.
// Each exported clip gets a "Powered by ClipIt" watermark burned in.

final class ClipExtractor {

    @MainActor
    static func extractHighlights(
        from videoURL: URL,
        highlights: [Clip],
        beforeSeconds: Double,
        afterSeconds: Double,
        progress: @MainActor @escaping (Int, Int) -> Void,
        completion: @MainActor @escaping ([Clip]) -> Void
    ) {
        guard !highlights.isEmpty else {
            completion([])
            return
        }

        let asset = AVURLAsset(url: videoURL)

        Task { @MainActor in
            guard let duration = try? await asset.load(.duration) else {
                print("[ClipExtractor] could not load asset duration")
                completion(highlights)
                return
            }

            let totalDuration = duration.seconds
            let totalCount = highlights.count
            
            // We use a TaskGroup to extract clips in parallel across multiple CPU cores
            let updatedClips = await withTaskGroup(of: (Int, Clip).self) { group in
                
                for (index, clip) in highlights.enumerated() {
                    let startSecs = max(0, clip.offsetInSession - beforeSeconds)
                    // 🛡️ Add 0.5s padding if 0s post-roll was chosen to preserve the action climax
                    let adjustedAfter = afterSeconds == 0 ? 0.5 : afterSeconds
                    let endSecs    = min(totalDuration, clip.offsetInSession + adjustedAfter)

                    // 🛡️ SAFEGUARD: Ensure duration is valid. If a user clips at 0.0s with 0s post-roll,
                    // force a minimum 1-second window to prevent export crashes.
                    let finalEndSecs = (endSecs <= startSecs) ? min(totalDuration, startSecs + 1.0) : endSecs

                    let outputURL = clipOutputURL(for: clip)
                    
                    // Add this extraction task to the parallel execution pool
                    group.addTask {
                        let extracted = await extractClip(
                            from: asset,
                            startSeconds: startSecs,
                            endSeconds: finalEndSecs,
                            outputURL: outputURL
                        )

                        var updated = clip
                        updated.fileURL = extracted
                        updated.duration = finalEndSecs - startSecs
                        updated.sourceVideoURL = videoURL
                        updated.sourceStartTime = startSecs
                        updated.sourceEndTime = finalEndSecs
                        return (index, updated)
                    }
                }
                
                // Collect results dynamically as they finish out-of-order
                var results: [(index: Int, clip: Clip)] = []
                var completedCount = 0
                
                for await (index, updatedClip) in group {
                    results.append((index, updatedClip))
                    completedCount += 1
                    
                    // MainActor isolation ensures UI updates happen safely on the main thread
                    let currentCompleted = completedCount
                    progress(currentCompleted, totalCount)
                }
                
                // Sort them back into their original chronological order before returning
                return results.sorted { $0.index < $1.index }.map { $0.clip }
            }

            completion(updatedClips)
        }
    }
    
    // MARK: - Single clip extraction with watermark

    private static func extractClip(
        from asset: AVURLAsset,
        startSeconds: Double,
        endSeconds: Double,
        outputURL: URL
    ) async -> URL? {
        try? FileManager.default.removeItem(at: outputURL)

        let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let endTime   = CMTime(seconds: endSeconds,   preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        let composition = AVMutableComposition()

        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard let sourceVideoTrack = videoTracks.first else { return nil }
            guard let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { return nil }

            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)

            // Keep orientation metadata intact
            let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
            compositionVideoTrack.preferredTransform = preferredTransform

            // 🔥 SAFE MULTI-TRACK AUDIO FIX:
            for sourceAudioTrack in audioTracks {
                if let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) {
                    do {
                        try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
                    } catch {
                        print("[ClipExtractor] Skipping a degraded or misaligned audio track: \(error)")
                    }
                }
            }
        } catch {
            return nil
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            return nil
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // 🔥 THE FIX: Use your custom built watermarked composition function!
        if let watermarkedComposition = buildWatermarkedVideoComposition(for: composition, asset: asset) {
            exportSession.videoComposition = watermarkedComposition
        } else {
            // Fallback composition layout if watermark compilation fails
            let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
            exportSession.videoComposition = videoComposition
        }
        
        // Await the export sequentially to bypass closure warnings entirely!
        await exportSession.export()
        
        // Read parameters safely inside the task context scope
        let finalStatus = exportSession.status
        
        if finalStatus == .completed {
            return outputURL
        } else {
            print("[ClipExtractor] export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
            return nil
        }
    }

    // MARK: - Watermark composition

    private static func buildWatermarkedVideoComposition(
        for composition: AVMutableComposition,
        asset: AVURLAsset
    ) -> AVVideoComposition? {
        guard let logoImage = UIImage(named: "watermark_logo"),
              let cgLogo = logoImage.cgImage else {
            return nil
        }
        
        let ciLogo = CIImage(cgImage: cgLogo)
        
        let videoComposition = AVVideoComposition(asset: composition) { request in
            let sourceImage = request.sourceImage
            let renderSize = sourceImage.extent.size
            
            // 🛡️ Safeguard check
            guard renderSize.width > 0, renderSize.height > 0,
                  cgLogo.width > 0, cgLogo.height > 0,
                  ciLogo.extent.width > 0, ciLogo.extent.height > 0 else {
                request.finish(with: sourceImage, context: nil)
                return
            }
            
            let referenceDimension = min(renderSize.width, renderSize.height)
            
            // --- 1. Proportional Dimensions for Logo ---
            let badgeW = referenceDimension * 0.22
            let badgeH = badgeW * (CGFloat(cgLogo.height) / CGFloat(cgLogo.width))
            let padding = referenceDimension * 0.035
            
            let watermarkX = renderSize.width - badgeW - padding
            let watermarkY = renderSize.height - badgeH - padding
            
            let positionedLogo = ciLogo
                .transformed(by: CGAffineTransform(scaleX: badgeW / ciLogo.extent.width,
                                                   y: badgeH / ciLogo.extent.height))
                .transformed(by: CGAffineTransform(translationX: watermarkX, y: watermarkY))
            
            // --- 2. Composite Only The Logo Layer ---
            let outputImage = positionedLogo.composited(over: sourceImage)
            request.finish(with: outputImage, context: nil)
        }
        
        return videoComposition
    }
    
    // MARK: - Output URL

    private static func clipOutputURL(for clip: Clip) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(clip.id.uuidString).mov")
    }
}
