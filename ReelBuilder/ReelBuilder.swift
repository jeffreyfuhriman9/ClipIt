//
//  ReelBuilder.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 8/4/26.
//

import Foundation
import AVFoundation
import UIKit

struct ReelBuilder {
    
    enum ReelError: Error {
        case emptyClipList
        case cannotCreateTrack
        case exportFailed
    }
    
    static func generateReel(
        clipURLs: [URL],
        transition: ReelTransition = .crossfade,
        renderSize: CGSize? = nil
    ) async throws -> URL {
        
        guard !clipURLs.isEmpty else {
            throw ReelError.emptyClipList
        }
        
        // 🌟 Determine dynamic target size (Landscape vs Portrait)
        let targetRenderSize: CGSize
        if let renderSize = renderSize {
            targetRenderSize = renderSize
        } else {
            targetRenderSize = await detectTargetRenderSize(for: clipURLs)
        }
        
        let mixComposition = AVMutableComposition()
        
        guard let compositionVideoTrack = mixComposition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let compositionAudioTrack = mixComposition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ReelError.cannotCreateTrack
        }
        
        var currentTime = CMTime.zero
        // ⚡️ Faster crossfade duration (0.35s instead of 0.75s)
        let transitionDuration = (transition == .none) ? CMTime.zero : CMTime(seconds: 0.35, preferredTimescale: 600)
        
        var instructions: [AVMutableVideoCompositionInstruction] = []
        
        for (index, url) in clipURLs.enumerated() {
            let asset = AVURLAsset(url: url)
            
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: currentTime)
            
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try? compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: currentTime)
            }
            
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let naturalSize = try await videoTrack.load(.naturalSize)
            
            let finalTransform = computeAspectFillTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                targetSize: targetRenderSize
            )
            
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
            layerInstruction.setTransform(finalTransform, at: currentTime)
            
            if transition == .crossfade && duration > CMTime(seconds: 0.8, preferredTimescale: 600) {
                let fadeOutStart = CMTimeSubtract(CMTimeAdd(currentTime, duration), transitionDuration)
                
                layerInstruction.setOpacityRamp(
                    fromStartOpacity: 1.0,
                    toEndOpacity: 0.0,
                    timeRange: CMTimeRange(start: fadeOutStart, duration: transitionDuration)
                )
                if index > 0 {
                    layerInstruction.setOpacityRamp(
                        fromStartOpacity: 0.0,
                        toEndOpacity: 1.0,
                        timeRange: CMTimeRange(start: currentTime, duration: transitionDuration)
                    )
                }
            }
            
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: currentTime, duration: duration)
            instruction.layerInstructions = [layerInstruction]
            
            instruction.backgroundColor = UIColor.black.cgColor
            instructions.append(instruction)
            
            currentTime = CMTimeAdd(currentTime, duration)
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = targetRenderSize
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Reel_\(UUID().uuidString).mp4")
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        guard let exportSession = AVAssetExportSession(
            asset: mixComposition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ReelError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        
        await exportSession.export()
        
        if exportSession.status == .completed {
            return outputURL
        } else {
            print("❌ Reel Export Failed: \(String(describing: exportSession.error))")
            throw ReelError.exportFailed
        }
    }
    
    private static func detectTargetRenderSize(for urls: [URL]) async -> CGSize {
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            guard let naturalSize = try? await track.load(.naturalSize),
                  let preferredTransform = try? await track.load(.preferredTransform) else { continue }
            
            let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
            let orientedWidth = abs(rect.width)
            let orientedHeight = abs(rect.height)
            
            if orientedWidth > orientedHeight {
                return CGSize(width: 1920, height: 1080)
            } else if orientedHeight > orientedWidth {
                return CGSize(width: 1080, height: 1920)
            }
        }
        return CGSize(width: 1080, height: 1920)
    }
    
    private static func computeAspectFillTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        targetSize: CGSize
    ) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let transformedSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        
        let scaleX = targetSize.width / transformedSize.width
        let scaleY = targetSize.height / transformedSize.height
        let scale = max(scaleX, scaleY)
        
        let scaledWidth = transformedSize.width * scale
        let scaledHeight = transformedSize.height * scale
        
        let translateX = (targetSize.width - scaledWidth) / 2.0
        let translateY = (targetSize.height - scaledHeight) / 2.0
        
        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: translateX, y: translateY))
    }
}
