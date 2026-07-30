import Foundation
import AVFoundation
import UIKit
import CoreImage
import CoreGraphics
import CoreMedia

// MARK: - ClipExtractor
//
// After a full session recording ends, this takes the full .mov file
// and extracts a short trimmed clip for each highlight timestamp.
// Exports clips with ISO-8601 QuickTime metadata for chronological album sorting
// and applies the standardized filename schema: ClipIt_YYYYMMDD_HHmmss_[Title].mov

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
            
            // TaskGroup extracts clips in parallel across multiple CPU cores
            let updatedClips = await withTaskGroup(of: (Int, Clip).self) { group in
                
                for (index, clip) in highlights.enumerated() {
                    let startSecs = max(0, clip.offsetInSession - beforeSeconds)
                    let adjustedAfter = afterSeconds == 0 ? 0.5 : afterSeconds
                    let endSecs    = min(totalDuration, clip.offsetInSession + adjustedAfter)

                    let finalEndSecs = (endSecs <= startSecs) ? min(totalDuration, startSecs + 1.0) : endSecs

                    let clipDate = Date() // 🌟 Uses current timestamp
                    let outputURL = clipOutputURL(for: clip, triggeredAt: clipDate)
                    
                    group.addTask {
                        let extracted = await extractClip(
                            from: asset,
                            startSeconds: startSecs,
                            endSeconds: finalEndSecs,
                            outputURL: outputURL,
                            creationDate: clipDate
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
                
                var results: [(index: Int, clip: Clip)] = []
                var completedCount = 0
                
                for await (index, updatedClip) in group {
                    results.append((index, updatedClip))
                    completedCount += 1
                    
                    let currentCompleted = completedCount
                    progress(currentCompleted, totalCount)
                }
                
                return results.sorted { $0.index < $1.index }.map { $0.clip }
            }

            completion(updatedClips)
        }
    }
    
    // MARK: - Single clip extraction with EXIF Metadata Injection

    private static func extractClip(
        from asset: AVURLAsset,
        startSeconds: Double,
        endSeconds: Double,
        outputURL: URL,
        creationDate: Date
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
        
        // 🌟 Inject Chronological Creation Metadata for iOS Photos & Files sorting
        exportSession.metadata = createChronologicalMetadataItems(for: creationDate)
        
        // 🧪 Watermark composition (Optional)
        // if let watermarkedComposition = buildWatermarkedVideoComposition(for: composition, asset: asset) {
        //     exportSession.videoComposition = watermarkedComposition
        // }
        
        await exportSession.export()
        
        let finalStatus = exportSession.status
        
        if finalStatus == .completed {
            return outputURL
        } else {
            print("[ClipExtractor] export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
            return nil
        }
    }

    // MARK: - Chronological Metadata Creation Helper

    private static func createChronologicalMetadataItems(for date: Date) -> [AVMetadataItem] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateString = isoFormatter.string(from: date)
        
        var items: [AVMetadataItem] = []
        
        // QuickTime metadata key space
        let qtDateItem = AVMutableMetadataItem()
        qtDateItem.keySpace = .quickTimeMetadata
        qtDateItem.key = AVMetadataKey.quickTimeMetadataKeyCreationDate as NSString
        qtDateItem.value = dateString as NSString
        qtDateItem.dataType = "com.apple.metadata.datatype.utf8" // 🌟 Direct String identifier avoiding scope issues
        items.append(qtDateItem)
        
        // Common key space fallback
        let commonDateItem = AVMutableMetadataItem()
        commonDateItem.keySpace = .common
        commonDateItem.key = AVMetadataKey.commonKeyCreationDate as NSString
        commonDateItem.value = dateString as NSString
        items.append(commonDateItem)
        
        return items
    }

    // MARK: - Watermark Composition (Clean Logo)

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
            
            guard renderSize.width > 0, renderSize.height > 0,
                  cgLogo.width > 0, cgLogo.height > 0,
                  ciLogo.extent.width > 0, ciLogo.extent.height > 0 else {
                request.finish(with: sourceImage, context: nil)
                return
            }
            
            let referenceDimension = min(renderSize.width, renderSize.height)
            let badgeW = referenceDimension * 0.22
            let badgeH = badgeW * (CGFloat(cgLogo.height) / CGFloat(cgLogo.width))
            let padding = referenceDimension * 0.035
            
            let watermarkX = renderSize.width - badgeW - padding
            let watermarkY = renderSize.height - badgeH - padding
            
            let positionedLogo = ciLogo
                .transformed(by: CGAffineTransform(scaleX: badgeW / ciLogo.extent.width,
                                                   y: badgeH / ciLogo.extent.height))
                .transformed(by: CGAffineTransform(translationX: watermarkX, y: watermarkY))
            
            let outputImage = positionedLogo.composited(over: sourceImage)
            request.finish(with: outputImage, context: nil)
        }
        
        return videoComposition
    }

    // MARK: - Output URL Helper

    private static func clipOutputURL(for clip: Clip, triggeredAt date: Date) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir  = docs.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let filename = ClipFilenameHelper.generateFilename(title: clip.displayName, date: date)
        return dir.appendingPathComponent(filename)
    }
}

// MARK: - Standardized Filename Helper

enum ClipFilenameHelper {
    static func generateFilename(title: String, date: Date, fileExtension: String = "mov") -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = dateFormatter.string(from: date)
        
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>| ")
        let sanitizedTitle = title
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        
        let cleanTitle = sanitizedTitle.isEmpty ? "Highlight" : sanitizedTitle
        return "ClipIt_\(dateString)_\(cleanTitle).\(fileExtension)"
    }
}
