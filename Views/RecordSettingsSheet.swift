import SwiftUI

struct RecordSettingsSheet: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var before: Double = 10
    @State private var after: Double = 10

    private let maxSeconds: Double = 60

    private var totalClipLength: Int { Int(before) + Int(after) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                clipLengthVisual
                    .padding(.top, 28)
                    .padding(.horizontal, 24)

                Divider()
                    .padding(.top, 28)

                VStack(spacing: 28) {
                    sliderRow(
                        label: "Before ClipIt",
                        sublabel: "Captured before you tap Clip It",
                        value: $before,
                        color: .blue
                    )
                    sliderRow(
                        label: "After ClipIt",
                        sublabel: "Captured after you tap Clip It",
                        value: $after,
                        color: .red
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    Text("Each clip will be \(totalClipLength) seconds long")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Clip timing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recordingVM.bufferLengthSeconds = Int(before)
                        recordingVM.postRollSeconds = Int(after)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            before = Double(recordingVM.bufferLengthSeconds)
            after  = Double(recordingVM.postRollSeconds)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Clip length visual

    private var clipLengthVisual: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let halfWidth  = totalWidth / 2

                // Each side fills proportionally up to maxSeconds
                let beforeWidth = (before / maxSeconds) * halfWidth
                let afterWidth  = (after  / maxSeconds) * halfWidth

                ZStack {
                    // Track
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.15))
                        .frame(width: totalWidth, height: 44)

                    // Before fill — grows leftward from center
                    HStack(spacing: 0) {
                        Spacer()
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: beforeWidth, height: 44)
                    }
                    .frame(width: halfWidth)
                    .frame(width: totalWidth, alignment: .leading)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: beforeWidth >= halfWidth ? 10 : 0,
                            bottomLeadingRadius: beforeWidth >= halfWidth ? 10 : 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 0
                        )
                    )

                    // After fill — grows rightward from center
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.red.opacity(0.4))
                            .frame(width: afterWidth, height: 44)
                        Spacer()
                    }
                    .frame(width: halfWidth)
                    .frame(width: totalWidth, alignment: .trailing)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: afterWidth >= halfWidth ? 10 : 0,
                            topTrailingRadius: afterWidth >= halfWidth ? 10 : 0
                        )
                    )

                    // Center marker — always perfectly centered
                    VStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: 28)
                        Text("Clip It")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: totalWidth, alignment: .center)
                }
                .frame(width: totalWidth, height: 44)
            }
            .frame(height: 44)

            // Labels
            HStack {
                Text("-\(Int(before))s")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.blue)
                Spacer()
                Text("0")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(white: 0.45))
                Spacer()
                Text("+\(Int(after))s")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Slider row

    private func sliderRow(
        label: String,
        sublabel: String,
        value: Binding<Double>,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int(value.wrappedValue)) sec")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value.wrappedValue)
            }

            Text(sublabel)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Slider(value: value, in: 5...maxSeconds, step: 5)
                .tint(color)
        }
    }
}
