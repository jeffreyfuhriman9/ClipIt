import SwiftUI

struct RecordSettingsSheet: View {
    @EnvironmentObject var recordingVM: RecordingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var preceding: Double = 10

    private let minSeconds: Double = 1
    private let maxSeconds: Double = 60
    private let quickOptions: [Int] = [5, 10, 15, 20, 30, 60]

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                header
                    .padding(.top, 20)

                precedingSlider
                    .padding(.horizontal, 24)

                quickSnapRow
                    .padding(.horizontal, 24)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        recordingVM.bufferLengthSeconds = Int(preceding)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            preceding = Double(recordingVM.bufferLengthSeconds)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                Text("ClipIt Save Time")
                    .font(.system(size: 21, weight: .bold))
            }
            .foregroundColor(.white)

            Text("Save the preceding seconds")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Preceding-seconds slider

    private var precedingSlider: some View {
        let trackHeight: CGFloat = 56

        return GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat((preceding - minSeconds) / (maxSeconds - minSeconds))
            let fillWidth = max(trackHeight, frac * w)
            let thumbX = min(max(fillWidth, trackHeight / 2), w - 2)

            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: w, height: trackHeight)

                // Filled portion
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.65)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth, height: trackHeight)

                // Value label
                Text("\(Int(preceding))s")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.leading, 18)

                // Pause-style thumb marker
                HStack(spacing: 3) {
                    Capsule().fill(Color.white).frame(width: 3, height: trackHeight * 0.5)
                    Capsule().fill(Color.white).frame(width: 3, height: trackHeight * 0.5)
                }
                .position(x: thumbX, y: trackHeight / 2)
            }
            .frame(width: w, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), w)
                        let f = Double(x / w)
                        let sec = minSeconds + f * (maxSeconds - minSeconds)
                        withAnimation(.interactiveSpring()) {
                            preceding = min(max(sec.rounded(), minSeconds), maxSeconds)
                        }
                    }
            )
        }
        .frame(height: trackHeight)
    }

    // MARK: - Quick snap buttons

    private var quickSnapRow: some View {
        HStack(spacing: 8) {
            ForEach(quickOptions, id: \.self) { option in
                let isSelected = Int(preceding) == option

                Button {
                    withAnimation(.snappy) { preceding = Double(option) }
                } label: {
                    Text("\(option)s")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.55))
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.blue : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
