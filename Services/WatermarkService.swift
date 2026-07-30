//
//  WatermarkService.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 5/21/26.
//

import Foundation
import AVFoundation
import UIKit
import CoreImage

final class WatermarkService {
    
    static func applyWatermark(inputURL: URL, outputURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVURLAsset(url: inputURL)
        let composition = AVMutableComposition()
        
        Task {
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                
                guard let sourceVideoTrack = videoTracks.first,
                      let compositionVideoTrack = composition.addMutableTrack(
                        withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else {
                    throw NSError(domain: "WatermarkService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load video track"])
                }
                
                let duration = try await asset.load(.duration)
                let timeRange = CMTimeRange(start: .zero, duration: duration)
                
                try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
                
                // Keep orientation metadata intact
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                compositionVideoTrack.preferredTransform = preferredTransform
                
                // Safe multi-track audio mapping
                for sourceAudioTrack in audioTracks {
                    if let compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) {
                        do {
                            try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
                        } catch {
                            print("[WatermarkService] Skipping a degraded or misaligned audio track: \(error)")
                        }
                    }
                }
                
                guard let exportSession = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetHighestQuality
                ) else {
                    throw NSError(domain: "WatermarkService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create export session"])
                }
                
                exportSession.outputURL = outputURL
                exportSession.outputFileType = .mp4
                exportSession.shouldOptimizeForNetworkUse = true
                
                // 🧪 WATERMARK DISABLED FOR TESTING (Uncomment when subscription tier is added)
                // let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                // let isPortrait = preferredTransform.b != 0 || preferredTransform.c != 0
                // let renderSize = isPortrait ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize
                // if let watermarkedComposition = buildWatermarkedVideoComposition(for: composition, renderSize: renderSize) {
                //     exportSession.videoComposition = watermarkedComposition
                // }
                
                await exportSession.export()
                
                if exportSession.status == .completed {
                    completion(.success(outputURL))
                } else {
                    let error = exportSession.error ?? NSError(domain: "WatermarkService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
                    completion(.failure(error))
                }
                
            } catch {
                completion(.failure(error))
            }
        }
    }
    
    // MARK: - Optimized Watermark Composition Logic
    
    private static func buildWatermarkedVideoComposition(
        for composition: AVMutableComposition,
        renderSize: CGSize
    ) -> AVVideoComposition? {
        guard let logoImage = UIImage(named: "watermark_logo"),
              let cgLogo = logoImage.cgImage else {
            return nil
        }
        
        let ciLogo = CIImage(cgImage: cgLogo)
        
        // --- 1. Pre-calculate Geometry & Math ---
        let referenceDimension = min(renderSize.width, renderSize.height)
        
        // Scaled elegantly to 22% of the shortest side
        let badgeW = referenceDimension * 0.22
        let badgeH = badgeW * (CGFloat(cgLogo.height) / CGFloat(cgLogo.width))
        
        // Tight, uniform padding relative to the shortest side
        let padding = referenceDimension * 0.035
        
        // Coordinates for Top-Right corner
        let watermarkX = renderSize.width - badgeW - padding
        let watermarkY = renderSize.height - badgeH - padding
        
        let positionedLogo = ciLogo
            .transformed(by: CGAffineTransform(scaleX: badgeW / ciLogo.extent.width,
                                               y: badgeH / ciLogo.extent.height))
            .transformed(by: CGAffineTransform(translationX: watermarkX, y: watermarkY))
        
        // --- 2. Per-Frame Execution Block (Clean Logo Only - "POWERED BY" Removed) ---
        let videoComposition = AVVideoComposition(asset: composition) { request in
            let sourceImage = request.sourceImage
            let outputImage = positionedLogo.composited(over: sourceImage)
            request.finish(with: outputImage, context: nil)
        }
        
        return videoComposition
    }
}
