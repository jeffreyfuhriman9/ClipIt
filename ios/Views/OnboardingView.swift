import SwiftUI
import Combine

enum TutorialTarget: Hashable {
    case record, clipIt, timing, zoom, library, reel, device, retention, dimScreen
}

enum TutorialStep: Int, CaseIterable {
    case welcome, record, clipIt, timing, zoom, library, reel, device, retention, dimScreen

    var tab: Int {
        switch self {
        case .welcome, .record, .clipIt, .timing, .zoom: return 0
        case .library, .reel: return 1
        case .device: return 2
        case .retention, .dimScreen: return 3
        }
    }

    var target: TutorialTarget? {
        switch self {
        case .welcome: return nil
        case .record: return .record
        case .clipIt: return .clipIt
        case .timing: return .timing
        case .zoom: return .zoom
        case .library: return .library
        case .reel: return .reel
        case .device: return .device
        case .retention: return .retention
        case .dimScreen: return .dimScreen
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome to ClipIt"
        case .record: return "Start with Record"
        case .clipIt: return "Clip the highlights"
        case .timing: return "Choose your highlight length"
        case .zoom: return "Zoom without missing the play"
        case .library: return "Your clips, filtered"
        case .reel: return "Create a highlight reel"
        case .device: return "Connect your ClipIt Button"
        case .retention: return "Take control of your storage"
        case .dimScreen: return "Record for longer"
        }
    }

    var message: String {
        switch self {
        case .welcome:
            return "A quick tour will show you how to record, save highlights, make reels, and connect to your ClipIt Button!"
        case .record:
            return "Tap this button to start recording. Tap it again to stop and save the session. If you have a physical ClipIt Button, hold for 3 seconds to start/stop recordings remotely."
        case .clipIt:
            return "While recording, tap the ClipIt Button to save a highlight. If you have a physical ClipIt Button, it functions the same."
        case .timing:
            return "Tap this button to change how much footage is saved around a highlight, from 5 to 60 seconds."
        case .zoom:
            return "Press and hold the 1.0x control, then drag up to zoom in or down to zoom out. Tap .5x for a wider camera view."
        case .library:
            return "Use the filters to find Highlights, Favorites, Reels, or Original Videos within your ClipIt Library."
        case .reel:
            return "Tap Create ClipIt Reel, choose highlights in the order you want them to play, then generate your reel. This will string your clips together for you."
        case .device:
            return "Turn on your ClipIt Button and keep it nearby. On this screen, scan and select it when it appears. Its connection and battery status show here. Rename your device if you'd like!"
        case .retention:
            return "Original Videos use the most storage. Set automatic deletion to Never or after 1, 3, 7, 14, or 30 days. Your highlights and reels remain saved in the Library."
        case .dimScreen:
            return "Turn on Dim Screen While Recording to lower screen brightness during a session and help save battery. You're ready to capture your first moment!"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "bolt.circle"
        case .record: return "record.circle.fill"
        case .clipIt: return "hand.tap.fill"
        case .timing: return "gobackward"
        case .zoom: return "arrow.up.left.and.down.right.magnifyingglass"
        case .library: return "film"
        case .reel: return "movieclapper.fill"
        case .device: return "button.programmable.square.fill"
        case .retention: return "externaldrive.badge.timemachine"
        case .dimScreen: return "sunset.fill"
        }
    }
}

@MainActor
final class TutorialController: ObservableObject {
    @Published private(set) var step: TutorialStep?
    @Published private var targetFrames: [TutorialTarget: CGRect] = [:]

    var isActive: Bool { step != nil }

    func start() {
        targetFrames.removeAll()
        step = .welcome
    }

    func next() {
        guard let step else { return }
        self.step = TutorialStep(rawValue: step.rawValue + 1)
    }

    func back() {
        guard let step, step.rawValue > 0 else { return }
        self.step = TutorialStep(rawValue: step.rawValue - 1)
    }

    func finish() {
        step = nil
        targetFrames.removeAll()
    }

    func setFrame(_ frame: CGRect, for target: TutorialTarget) {
        guard step != nil, frame.width > 0, frame.height > 0 else { return }
        if targetFrames[target] != frame { targetFrames[target] = frame }
    }

    func frame(for target: TutorialTarget) -> CGRect? { targetFrames[target] }
}

private struct TutorialTargetReporter: View {
    @EnvironmentObject private var tutorial: TutorialController
    let target: TutorialTarget

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            Color.clear
                .onAppear { tutorial.setFrame(frame, for: target) }
                .onChange(of: tutorial.isActive) { _, isActive in
                    if isActive { tutorial.setFrame(frame, for: target) }
                }
                .onChange(of: frame) { _, newFrame in
                    tutorial.setFrame(newFrame, for: target)
                }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func tutorialTarget(_ target: TutorialTarget) -> some View {
        background(TutorialTargetReporter(target: target))
    }
}

struct TutorialOverlay: View {
    @EnvironmentObject private var tutorial: TutorialController
    @AppStorage("hasSeenGuidedTour") private var hasSeenGuidedTour = false
    @State private var confirmSkip = false
    @State private var animateFinger = false

    private var windowSafeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            if let step = tutorial.step {
                let origin = geometry.frame(in: .global).origin
                let target = step.target.flatMap(tutorial.frame(for:))?
                    .offsetBy(dx: -origin.x, dy: -origin.y)
                let visibleTarget = target.flatMap { frame -> CGRect? in
                    let clipped = frame.intersection(CGRect(origin: .zero, size: geometry.size))
                    return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : clipped
                }
                let highlight = visibleTarget?.insetBy(dx: -7, dy: -7)
                let cardAbove = visibleTarget.map { $0.midY > geometry.size.height * 0.5 } ?? false

                ZStack {
                    Color.clear.contentShape(Rectangle()).onTapGesture { }

                    Canvas { context, size in
                        var mask = Path(CGRect(origin: .zero, size: size))
                        if let highlight {
                            mask.addRoundedRect(in: highlight, cornerSize: CGSize(width: 20, height: 20))
                        }
                        context.fill(mask, with: .color(.black.opacity(0.78)), style: FillStyle(eoFill: true))
                    }
                    .allowsHitTesting(false)

                    if let highlight {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.crimsonBlaze, lineWidth: 3)
                            .shadow(color: .crimsonBlaze.opacity(0.8), radius: 12)
                            .frame(width: highlight.width, height: highlight.height)
                            .position(x: highlight.midX, y: highlight.midY)
                            .allowsHitTesting(false)

                        Image(systemName: cardAbove ? "arrow.down" : "arrow.up")
                            .font(.system(size: 25, weight: .heavy))
                            .foregroundStyle(Color.crimsonBlaze)
                            .position(
                                x: min(max(highlight.midX, 26), geometry.size.width - 26),
                                y: cardAbove ? max(highlight.minY - 28, 35) : min(highlight.maxY + 28, geometry.size.height - 35)
                            )
                            .allowsHitTesting(false)
                    }

                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button("Skip") { confirmSkip = true }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 76, minHeight: 44)
                                .background(.black.opacity(0.35), in: Capsule())
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, max(windowSafeAreaTop, 48) + 12)

                        if visibleTarget == nil || !cardAbove { Spacer(minLength: 12) }
                        tutorialCard(step)
                            .padding(.horizontal, 18)
                            .padding(.top, cardAbove ? 14 : 0)
                            .padding(.bottom, cardAbove ? 0 : geometry.safeAreaInsets.bottom + 18)
                        if visibleTarget != nil && cardAbove { Spacer(minLength: 12) }
                    }
                    .frame(maxWidth: 500)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .alert("Skip the tutorial?", isPresented: $confirmSkip) {
                    Button("Keep Learning", role: .cancel) { }
                    Button("Skip Tutorial", role: .destructive) { finish() }
                } message: {
                    Text("You can watch it again anytime in Settings → About.")
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: tutorial.step) { _, newStep in
            animateFinger = false
            if newStep == .zoom {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    animateFinger = true
                }
            }
        }
    }

    private func tutorialCard(_ step: TutorialStep) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.crimsonBlaze, in: RoundedRectangle(cornerRadius: 12))

                Text("CLIPIT TOUR  ·  \(step.rawValue + 1) OF \(TutorialStep.allCases.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Color.blueMarble)
            }

            Text(step.title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color.cosmosBlue)

            Text(step.message)
                .font(.system(size: 15))
                .foregroundStyle(Color.cosmosBlue.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            if step == .zoom {
                HStack(spacing: 12) {
                    Text("1.0x")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 45, height: 45)
                        .background(Color.cosmosBlue, in: Circle())
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.crimsonBlaze)
                        .offset(y: animateFinger ? -12 : 12)
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.crimsonBlaze)
                    Text("Hold + drag")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.cosmosBlue)
                }
                .padding(.vertical, 4)
                .accessibilityLabel("Hold the one times zoom button and drag up or down")
            }

            GeometryReader { progress in
                Capsule().fill(Color.crimsonBlaze.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.crimsonBlaze)
                            .frame(width: progress.size.width * CGFloat(step.rawValue + 1) / CGFloat(TutorialStep.allCases.count))
                    }
            }
            .frame(height: 5)
            .padding(.top, 3)

            HStack(spacing: 12) {
                if step != .welcome {
                    Button { tutorial.back() } label: {
                        Text("Back")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.cosmosBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    }
                    .foregroundStyle(Color.cosmosBlue)
                }

                Button {
                    if step == TutorialStep.allCases.last { finish() }
                    else { tutorial.next() }
                } label: {
                    HStack(spacing: 7) {
                        Text(step == TutorialStep.allCases.last ? "Get Started" : "Next")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.crimsonBlaze, in: RoundedRectangle(cornerRadius: 13))
                }
                .foregroundStyle(.white)
            }
            .font(.system(size: 16, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 23))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
    }

    private func finish() {
        hasSeenGuidedTour = true
        tutorial.finish()
    }
}
