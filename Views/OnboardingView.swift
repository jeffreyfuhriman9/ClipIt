//
//  OnboardingView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 5/5/26.
//

import SwiftUI
import AVFoundation
import CoreBluetooth

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    private let totalPages = 6

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    if currentPage < totalPages - 1 {
                        Button("Skip") {
                            completeOnboarding()
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    } else {
                        Color.clear.frame(height: 44)
                            .padding(.top, 16)
                    }
                }

                // Page content
                TabView(selection: $currentPage) {
                    WelcomePage().tag(0)
                    BufferExplainerPage().tag(1)
                    TrimEditPage().tag(3)
                    BLEButtonPage().tag(4)
                    GetStartedPage(onGetStarted: completeOnboarding).tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Page dots + Next button
                VStack(spacing: 20) {
                    // Dot indicators
                    HStack(spacing: 8) {
                        ForEach(0..<totalPages, id: \.self) { i in
                            Circle()
                                .fill(i == currentPage ? Color.red : Color.gray.opacity(0.3))
                                .frame(width: i == currentPage ? 10 : 7,
                                       height: i == currentPage ? 10 : 7)
                                .animation(.spring(), value: currentPage)
                        }
                    }

                    // Next / Get Started button
                    if currentPage < totalPages - 1 {
                        Button {
                            withAnimation { currentPage += 1 }
                        } label: {
                            Text("Next")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.red)
                                .cornerRadius(16)
                                .padding(.horizontal, 32)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func completeOnboarding() {
        requestPermissionsInSequence {
            hasCompletedOnboarding = true
        }
    }

    private func requestPermissionsInSequence(completion: @escaping () -> Void) {
        // 1. Camera
        AVCaptureDevice.requestAccess(for: .video) { _ in
            // 2. Microphone
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    // 3. Bluetooth (just instantiate CBCentralManager to trigger prompt)
                    // Your existing BLEManager will handle this — just flip the flag
                    completion()
                }
            }
        }
    }
}

// MARK: - Page 1: Welcome
struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // App icon placeholder — swap with Image("AppIcon") if you have it
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.red, Color.red.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 110, height: 110)
                    .shadow(color: Color.red.opacity(0.3), radius: 16, y: 8)

                Image(systemName: "video.badge.checkmark")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(spacing: 12) {
                Text("Welcome to\nClipIt!")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)

                Text("Never miss a moment\nwith instant highlight creation.")
                    .font(.system(size: 20, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Page 2: The Buffer
struct BufferExplainerPage: View {
    @State private var animateBuffer = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 52))
                    .foregroundColor(.blue)

                Text("Always Recording,\nSaving Highlights With\n One Click")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)

                Text("ClipIt keeps a rolling buffer of 5-60 seconds before and after your clip.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }

            // Timeline visual
            VStack(spacing: 12) {
                BufferTimelineView(animated: animateBuffer)

                HStack {
                    Text("10s before")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Spacer()
                    Text("ClipIt!")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                    Spacer()
                    Text("10s after")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
            .onAppear { withAnimation(.easeInOut(duration: 1.2)) { animateBuffer = true } }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct BufferTimelineView: View {
    var animated: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Before segment
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue.opacity(0.25))
                .frame(height: 28)
                .overlay(
                    Text("BEFORE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                )

            // Tap marker
            ZStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 36, height: 36)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }

            // After segment
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.red.opacity(0.25))
                .frame(height: 28)
                .overlay(
                    Text("AFTER")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                )
        }
        .opacity(animated ? 1 : 0)
        .scaleEffect(animated ? 1 : 0.85)
    }
}

// MARK: - Page 4: Trim & Edit
struct TrimEditPage: View {
    @State private var trimLeading: CGFloat = 0.15
    @State private var trimTrailing: CGFloat = 0.85
    @State private var isAnimating = false
    @State private var selectionScale: CGFloat = 1.0


    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 52))
                    .foregroundColor(.orange)

                Text("Polish Every Highlight")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)

                Text("After a clip is saved, tap 'edit' in your Clips library to open the trim editor\nand adjustif needed.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }

            // Mock trim editor visual
            VStack(spacing: 16) {
                GeometryReader { geo in
                    let w = geo.size.width
                    let selectionWidth = w * 0.45 * selectionScale

                    ZStack {
                        // Filmstrip (ONLY ONCE)
                        HStack(spacing: 2) {
                            ForEach(0..<12, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(i % 2 == 0
                                          ? Color.gray.opacity(0.25)
                                          : Color.gray.opacity(0.15))
                            }
                        }
                        .frame(height: 52)
                        .cornerRadius(8)

                        // Selection
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.orange, lineWidth: 3)

                            HStack {
                                Capsule()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 44)

                                Spacer()

                                Capsule()
                                    .fill(Color.orange)
                                    .frame(width: 6, height: 44)
                            }
                        }
                        .frame(width: selectionWidth, height: 52)
                        .opacity(0.95 + (1 - selectionScale) * 0.05)
                    }
                }
                .frame(height: 52)
                .padding(.horizontal, 24)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 1.2)
                        .repeatForever(autoreverses: true)
                    ) {
                        // Animate width instead of edges
                        // Use a @State var:
                        // @State private var selectionScale: CGFloat = 1.0
                        selectionScale = 0.75
                    }
                }

                // Timecode labels
                HStack {
                    Text("0:00")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("0:10")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("0:20")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 28)
            }

            // Step callouts
            VStack(spacing: 10) {
                TrimStepRow(number: "1", icon: "hand.tap", color: .orange,
                            text: "Tap 'edit' inside any clip")
                TrimStepRow(number: "2", icon: "arrow.left.and.right", color: .orange,
                            text: "Drag the handles")
                TrimStepRow(number: "3", icon: "square.and.arrow.down", color: .orange,
                            text: "Save or share directly")
            }
            .padding(.horizontal, 24)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

struct TrimStepRow: View {
    let number: String
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(color)
            }
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.black.opacity(0.75))
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Page 5: BLE Button
struct BLEButtonPage: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 90, height: 90)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 44))
                    .foregroundColor(.blue)
            }

            VStack(spacing: 12) {
                Text("One-Tap Hardware Button")
                    .font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)

                Text("Clip a moment without looking at your phone. The ClipIt button connects over Bluetooth and triggers a save from your pocket.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }

            VStack(spacing: 10) {
                BLEFeatureRow(icon: "battery.100", text: "Battery level shown in-app")
                BLEFeatureRow(icon: "hand.tap", text: "Single press to capture")
                BLEFeatureRow(icon: "iphone.and.arrow.forward", text: "Pairs automatically on launch")
            }
            .padding(.horizontal, 16)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

struct BLEFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.blue)
                .frame(width: 28)
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.black.opacity(0.75))
            Spacer()
        }
        .padding(14)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Page 6: Get Started
struct GetStartedPage: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundColor(.blue)

            VStack(spacing: 12) {
                Text("You're Ready.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.black)

                Text("We'll ask for camera, microphone, and Bluetooth access — all powering ClipIt.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }

            Spacer()

            Button(action: onGetStarted) {
                HStack(spacing: 10) {
                    Text("Get Started")
                        .font(.system(size: 18, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(18)
                .shadow(color: Color.blue.opacity(0.35), radius: 12, y: 6)
                .padding(.horizontal, 32)
            }

            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 32)
    }
}
