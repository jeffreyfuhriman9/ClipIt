//
//  HighlightProgressView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/9/26.
//

import SwiftUI

struct HighlightExtractionProgressView: View {
    let currentCount: Int
    let totalCount: Int
    
    private var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(currentCount) / Double(totalCount)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saving Your Clips!")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Do not force quit app...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                
                // Text Counter Display (ex: 3/10)
                Text("\(currentCount)/\(totalCount)")
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
            }
            
            // The Loading Track & Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.red, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * progressFraction, height: 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentCount)
                }
            }
            .frame(height: 8)
        }
        .padding()
        .frame(maxWidth: 360) // 🌟 THE FIX: Hard-caps the width so it stays beautifully centered!
        .background(Color(white: 0.12))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        // Add a subtle shadow so it floats off the camera feed nicely
        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 5)
    }
}

struct ImportProgressView: View {
    let progress: Double // Expects a value from 0.0 to 1.0
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importing Full Recording...")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Please keep devices nearby...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                
                // Percentage Display (ex: 45%)
                Text("\(Int(progress * 100))%")
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
            }
            
            // The Loading Track & Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)
                    
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.red, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        // Uses the Double directly for the width multiplier
                        .frame(width: geo.size.width * max(0, min(progress, 1)), height: 8)
                        .animation(.linear(duration: 0.1), value: progress)
                }
            }
            .frame(height: 8)
        }
        .padding()
        .frame(maxWidth: 360) // 🌟 THE FIX: Hard-caps the width so it stays beautifully centered!
        .background(Color(white: 0.12))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        // Add a subtle shadow so it floats off the camera feed nicely
        .shadow(color: Color.black.opacity(0.4), radius: 10, y: 5)
    }
}
