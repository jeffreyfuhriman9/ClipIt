//
//  TitleSlideGenerator.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 8/4/26.
//

import UIKit
import AVFoundation
import SwiftUI

// MARK: - Title Card Color Enum
enum TitleCardColor: String, CaseIterable, Identifiable {
    case black = "Black"
    case white = "White"
    case red = "Red"
    case orange = "Orange"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    
    var id: String { rawValue }
    
    var swiftUIColor: Color {
        switch self {
        case .black: return .black
        case .white: return .white
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .orange: return .orange
        }
    }
    
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .white: return .white
        case .red: return .systemRed
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        }
    }
}

// MARK: - Title Slide Generator
struct TitleSlideGenerator {
    
    /// Generates an MP4 title slide video matching selected title text, background color, and render size (1080x1920 portrait or 1920x1080 landscape).
    static func createTitleSlideVideo(
        titleText: String,
        color: TitleCardColor,
        durationSeconds: Double = 3.0,
        renderSize: CGSize = CGSize(width: 1080, height: 1920)
    ) async -> URL? {
        let cleanText = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TitleSlide_\(UUID().uuidString).mp4")
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        // 1. Generate full-resolution title card image
        guard let titleImage = generateTitleImage(
            text: cleanText,
            color: color,
            size: renderSize
        ) else {
            return nil
        }
        
        // 2. Encode image frames into video file
        do {
            try await writeImageToVideo(
                image: titleImage,
                to: outputURL,
                durationSeconds: durationSeconds,
                size: renderSize
            )
            return outputURL
        } catch {
            print("❌ TitleSlideGenerator error: \(error)")
            return nil
        }
    }
    
    private static func generateTitleImage(
        text: String,
        color: TitleCardColor,
        size: CGSize
    ) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            let cgContext = context.cgContext
            
            // Fill background
            let uiBgColor = UIColor(color.swiftUIColor)
            uiBgColor.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))
            
            // Contrast text color selection
            let textColor: UIColor = (color == .white) ? .black : .white
            
            // Padding and bounding dimensions
            let margin: CGFloat = 80
            let maxTextWidth = size.width - (margin * 2)
            let maxTextHeight = size.height - (margin * 2)
            let textBoundingBox = CGSize(width: maxTextWidth, height: maxTextHeight)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.lineSpacing = 12
            
            // Dynamic font scaling
            var fontSize: CGFloat = 76
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
            
            var textHeight = (text as NSString).boundingRect(
                with: textBoundingBox,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).height
            
            while textHeight > maxTextHeight && fontSize > 28 {
                fontSize -= 4
                attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                textHeight = (text as NSString).boundingRect(
                    with: textBoundingBox,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                ).height
            }
            
            // Center text vertically
            let textY = (size.height - textHeight) / 2.0
            let textRect = CGRect(x: margin, y: textY, width: maxTextWidth, height: textHeight)
            
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
    
    private static func writeImageToVideo(
        image: UIImage,
        to outputURL: URL,
        durationSeconds: Double,
        size: CGSize
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: attributes
        )
        
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        guard let pixelBuffer = createPixelBuffer(from: image, size: size) else {
            throw NSError(domain: "TitleSlideGenerator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }
        
        let fps: Int32 = 30
        let frameCount = Int(durationSeconds * Double(fps))
        let frameDuration = CMTime(value: 1, timescale: fps)
        
        for frame in 0..<frameCount {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            bufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }
        
        writerInput.markAsFinished()
        await writer.finishWriting()
        
        if writer.status != .completed {
            throw writer.error ?? NSError(domain: "TitleSlideGenerator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Video writer failed"])
        }
    }
    
    private static func createPixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            options as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer, let cgImage = image.cgImage else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: pixelData,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        return buffer
    }
}
