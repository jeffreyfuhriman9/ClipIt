//
//  AboutView.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 8/11/26.
//

import SwiftUI

// MARK: - Main About View
struct AboutView: View {
    @EnvironmentObject private var tutorial: TutorialController
    @Environment(\.dismiss) private var dismiss
    // Dynamically retrieve version & build number from Info.plist
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        List {
            // App Branding Header
            // MARK: - About View Header Section
            Section {
                VStack(spacing: 12) {
                    // App Icon Tile
                    ZStack {
                        // 🖼️ YOUR IMAGE LOGO ASSET
                        Image("ClipIt_Logo") // 👈 This must match the name in Assets.xcassets
                            .resizable()
                            .aspectRatio(contentMode: .fill) // .fill ensures it fills the tile without whitespace
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: Color.crimsonBlaze.opacity(0.6), radius: 10) // Crimson Blaze glow
                    }

                    // App Title & Version
                    VStack(spacing: 4) {
                        Text("ClipIt")
                            .font(.system(size: 26, weight: .bold, design: .rounded))

                        Text(appVersion) // Uses the dynamic appVersion computed property
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear) // Keeps the header background clean
            }

            // Sub-navigation destinations
            Section(header: Text("Learn More")) {
                NavigationLink(destination: FAQView()) {
                    Label {
                        Text("Frequently Asked Questions")
                            .font(.system(size: 16, weight: .medium))
                    } icon: {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.blueMarble)
                    }
                }

                NavigationLink(destination: DeveloperNoteView()) {
                    Label {
                        Text("Note from Developers")
                            .font(.system(size: 16, weight: .medium))
                    } icon: {
                        Image(systemName: "heart.text.square.fill")
                            .foregroundColor(.gochujangRed)
                    }
                }
            }

            // Optional App Info & Links
            Section(header: Text("Connect & Support")) {
                Link(destination: URL(string: "https://clipitbutton.com")!) {
                    Label {
                        HStack {
                            Text("Visit ClipIt website")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "safari.fill")
                            .foregroundColor(.cosmosBlue)
                    }
                }

                Link(destination: URL(string: "mailto:support@clipitbutton.com")!) {
                    Label {
                        HStack {
                            Text("Email ClipIt Team")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.green)
                    }
                }
                
                Button {
                    dismiss()
                    DispatchQueue.main.async { tutorial.start() }
                } label: {
                    Label {
                        Text("Rewatch App Tutorial")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundColor(.crimsonBlaze)
                    }
                }
            }

            // Footer
            Section {
                VStack(spacing: 4) {
                    Text("Made with ❤️ by athletes for athletes.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("© \(String(format: "%d", Calendar.current.component(.year, from: Date()))) ClipIt LLC. All rights reserved.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - FAQ View
struct FAQView: View {
    struct FAQItem: Identifiable {
        let id = UUID()
        let question: String
        let answer: String
    }

    @State private var expandedID: UUID? = nil

    private let faqs: [FAQItem] = [
        FAQItem(
            question: "How does ClipIt work?",
            answer: "ClipIt works as your own instant highlight broadcaster! Start by hitting record and each time you tap the ClipIt Button, timestamps are saved. When finished, hit the stop recording button and your ClipIt timestamps are instantly saved into standalone highlight clips! The original video from start to finish is also saved to enable editing a highlight clip or to 'save as a new clip' afterwards."
        ),
        FAQItem(
            question: "What's the difference between clip types (Highlights, Reels, & Original Videos?",
            answer: "The Original Video is the source of truth, where highlights are made. Highlights are the individual clips made from the preceding seconds of a ClipIt button press. Reels are highlights stitched together into one video, like a highlight reel!"
        ),
        FAQItem(
            question: "How do I pair a the ClipIt BlueTooth Button?",
            answer: "Turn device Bluetooth on. Ensure your Bluetooth ClipIt Button is turned on by sliding the slide switch on the side of the device. You should see the blue light blinking. Navigate to the Device screen and find your nearby button. Once connected, pressing the small button toggles start/stop recordng and the larger button triggers a ClipIt highlight instantly."
        ),
        FAQItem(
            question: "I'm running out of storage, how do I free up more space on my device?",
            answer: "Original Videos use the most storage since it's the film from start to finish. Once you’ve edited your highlights, you can safely delete the Original Video from a session. Your highlight clips will remain saved. To use less space going forward, you can also lower your Highlight Length or reduce Video Quality (e.g., from 4K to 1080p or 720p) in Settings."
        ),
        FAQItem(
            question: "What happens if I receive a phone call while recording?",
            answer: "ClipIt handles incoming calls safely! If you answer a call, ClipIt automatically finishes saving your active recording session up to that exact second so no footage is lost or corrupted. If you ignore or deny the call, your video will continue rolling."
        ),
        FAQItem(
            question: "How do I change the highlight buffer duration?",
            answer: "On the Record screen, tap the red circle icon in the bottom left. Use the slider or quick-select buttons to adjust the buffer length between 5 and 60 seconds. You can also find the ClipIt Highlight Length in Settings."
        ),
        FAQItem(
            question: "Where are my saved clips stored?",
            answer: "Clips are stored directly into your ClipIt Gallery inside the app. You can export, share, or save individual highlights directly to your iOS Photos library at any time. This keeps your camera roll clutter free, allows you to have a dedicated space for sports videos, and gives you the ability to name each clip so you remember the play!"
        ),
        FAQItem(
            question: "Can I save or share a highlight outside of ClipIt?",
            answer: "Yes! Hit the 'select' button in the ClipIt gallery to select multiple, or tap the share icon inside any clip to export the video(s). You can also send it directly via AirDrop or Messages, or post it straight to platforms like Instagram, YouTube, and TikTok. ClipIt is designed to be your dedicated, organized home for sports film."
        ),
        FAQItem(
            question: "What does 'Dim Screen While Recording' do?",
            answer: "It automatically lowers your screen brightness during active recording sessions to save battery and prevent your phone from overheating. Ending the video restores normal brightness."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(faqs) { faq in
                    let isExpanded = expandedID == faq.id

                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                expandedID = isExpanded ? nil : faq.id
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(faq.question)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.leading)

                                Spacer()

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.blueMarble)
                                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            }
                        }
                        .buttonStyle(.plain)

                        if isExpanded {
                            Text(faq.answer)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineSpacing(4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isExpanded ? Color.blueMarble.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Frequently Asked")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Developer Note View
struct DeveloperNoteView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Top Header Card
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.crimsonBlaze)

                    Text("A Note from the Creators")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text("Why we built ClipIt")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                // Letter Content Card
                VStack(alignment: .leading, spacing: 16) {
                    Text("We're happy you're here! 😁")
                        .font(.system(size: 17, weight: .bold))

                    Text("As two college volleyball athletes, we love filming our games and practices. However we found it difficult to find the time to rewatch the footage, extract our best moments, and keep them organized in our photos library. That's why we built ClipIt.")

                    Text("Whether you're recording sports, family moments, or action shots, your phone gallery shouldn't be sprawled with videos just because you want to catch the best moments.")

                    Text("ClipIt will help keep video recording organized, make sure you never miss a highlight again, and save storage space by keeping only the 'wow' moments.")
                    
                    Text("We're constantly working to refine our app and ClipIt Button. If you have ideas, feedback, or bugs to report, please reach out to us!")

                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Thank you for being part of the journey,")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)

                        Text("— The ClipIt Team")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.crimsonBlaze)
                    }
                }
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .lineSpacing(5)
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(UIColor.secondarySystemGroupedBackground))
                )
                .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Developer Note")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Preview
#Preview {
    NavigationView {
        AboutView()
    }
}
