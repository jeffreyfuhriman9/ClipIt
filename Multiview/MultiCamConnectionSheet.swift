//
//  MultiCamConnectionSheet.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 6/6/26.
//

import SwiftUI
import MultipeerConnectivity

struct MultiCamConnectionSheet: View {
    @ObservedObject var multipeerManager: MultipeerManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("Setup Multi-Cam Link")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 10)
                
                Text("Try setting up 2 phones on tripods to capture different angles of the same playing field simultaneously! Your ClipIt and record buttons will sync across both phones.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                Spacer()
                
                // 📱 OPTION A: HOST AS LEADER (Primary Camera)
                Button(action: {
                    multipeerManager.currentRole = .primary
                    multipeerManager.startHosting()
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.yellow)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Primary Camera 1")
                                .font(.system(size: 16, weight: .bold))
                                // ✅ Dynamic Title Color: White text when blue, primary text color when unselected
                                .foregroundColor(multipeerManager.currentRole == .primary ? .white : .primary)
                            
                            Text("Run the game as the primary device. The ClipIt button will sync ClipIt events across both camera angles.")
                                .font(.system(size: 12))
                                // ✅ Dynamic Subtitle Color: Faded white text when blue, secondary adaptive color when unselected
                                .foregroundColor(multipeerManager.currentRole == .primary ? Color.white.opacity(0.8) : .secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    // ✅ Adaptive Background Color: Vibrant Blue when selected, system material/secondary fill when unselected
                    .background(multipeerManager.currentRole == .primary ? Color.blue : Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            // ✅ Border Stroke Fix: Thick white outline if active on blue background, subtle stroke border when inactive
                            .stroke(multipeerManager.currentRole == .primary ? Color.blue : Color.primary.opacity(0.08), lineWidth: 1.5)
                    )
                    // ✅ Shadow Treatment: Adds separation and depth to the card layout in Light mode, subtle in Dark mode
                    .shadow(color: Color.black.opacity(multipeerManager.currentRole == .primary ? 0.15 : 0.05), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain) // Prevents iOS from applying default blue tint over our custom elements
                
                // 🔭 OPTION B: JOIN AS FOLLOWER (Secondary Camera)
                Button(action: {
                    multipeerManager.currentRole = .secondary
                    multipeerManager.startBrowsing()
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "video.badge.plus.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Secondary Camera 2")
                                .font(.system(size: 16, weight: .bold))
                                // ✅ Dynamic Title Color: White text when blue, primary text color when unselected
                                .foregroundColor(multipeerManager.currentRole == .secondary ? .white : .primary)
                            
                            Text("Place a secondary device for a different camera angle. It will sync to the primary device to record and clip automatically.")
                                .font(.system(size: 12))
                                // ✅ Dynamic Subtitle Color: Faded white text when blue, secondary adaptive color when unselected
                                .foregroundColor(multipeerManager.currentRole == .secondary ? Color.white.opacity(0.8) : .secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    // ✅ Adaptive Background Color: Vibrant Blue when selected, system material/secondary fill when unselected
                    .background(multipeerManager.currentRole == .secondary ? Color.blue : Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            // ✅ Border Stroke Fix: Thick white outline if active on blue background, subtle stroke border when inactive
                            .stroke(multipeerManager.currentRole == .secondary ? Color.blue : Color.primary.opacity(0.08), lineWidth: 1.5)
                    )
                    // ✅ Shadow Treatment: Adds separation and depth to the card layout in Light mode, subtle in Dark mode
                    .shadow(color: Color.black.opacity(multipeerManager.currentRole == .secondary ? 0.15 : 0.05), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain) // Prevents iOS from applying default blue tint over our custom elements
                
                Spacer()
                
                // 📊 CONNECTION STATUS HUB
                VStack(spacing: 12) {
                    if multipeerManager.isSuccessfullyConnected {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Linked to: \(multipeerManager.connectedPeers.first?.displayName ?? "Remote iPhone")")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                        
                        Button("Ready to Record!") {
                            dismiss()
                        }
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .frame(height: 65)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        
                    } else if multipeerManager.currentRole != .none {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(multipeerManager.currentRole == .primary ? "Waiting for Secondary Device..." : "Searching for Primary Device...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                }
                
                Spacer()
                
                // 🔴 BOTTOM DISCONNECT BUTTON
                if multipeerManager.isSuccessfullyConnected {
                    Button(role: .destructive) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        
                        withAnimation {
                            multipeerManager.stopAllNetworkServices()
                            multipeerManager.currentRole = .none // Reset role upon intentional disconnect
                        }
                        dismiss()
                        
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.gen3.slash")
                            Text("Disconnect Multiview Session")
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.crimsonBlaze)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 15)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        // Keep network running if already connected, otherwise stop
                        if !multipeerManager.isSuccessfullyConnected {
                            multipeerManager.stopAllNetworkServices()
                            multipeerManager.currentRole = .none
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
