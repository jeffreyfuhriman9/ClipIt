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
                    .foregroundColor(.crimsonBlaze)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.crimsonBlaze.opacity(0.15))
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
                                colors: [.gochujangRed, .crimsonBlaze],
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
        .background(Color(white: 0.12))
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
