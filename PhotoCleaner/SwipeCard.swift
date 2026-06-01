import SwiftUI

enum SwipeDecision { case delete, keep }

/// Source-agnostic swipe card. The caller supplies the image (or video) view
/// as `imageContent` — so both Google Photos (AsyncImage with a remote URL)
/// and local PhotoKit (PHAsset image) can share the same card chrome, drag
/// physics, decision badges, and label pill.
struct SwipeCard<ImageContent: View>: View {
    let label: String
    let sizeLabel: String?    // e.g. "2.4 MB" — shown next to the label pill
    let isVideo: Bool
    let stackOffset: Int
    let cardSize: CGSize
    let onDecision: (SwipeDecision) -> Void
    let imageContent: ImageContent
    /// External fly trigger. Setting this to `.delete` or `.keep` from a
    /// parent (e.g. the X / ✓ action buttons) runs the same fly-off
    /// animation a drag gesture does, then resets the binding to nil.
    /// Only the top card (stackOffset == 0) acts on the trigger.
    @Binding var flyCommand: SwipeDecision?

    @State private var dragOffset: CGSize = .zero
    @State private var isFlying: Bool = false

    private let threshold: CGFloat = 110

    init(
        label: String,
        sizeLabel: String? = nil,
        isVideo: Bool,
        stackOffset: Int,
        cardSize: CGSize,
        flyCommand: Binding<SwipeDecision?> = .constant(nil),
        onDecision: @escaping (SwipeDecision) -> Void,
        @ViewBuilder imageContent: () -> ImageContent
    ) {
        self.label = label
        self.sizeLabel = sizeLabel
        self.isVideo = isVideo
        self.stackOffset = stackOffset
        self.cardSize = cardSize
        self._flyCommand = flyCommand
        self.onDecision = onDecision
        self.imageContent = imageContent()
    }

    var body: some View {
        ZStack {
            // Black card body so letterboxing on landscape photos blends.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

            imageContent
                .frame(width: cardSize.width, height: cardSize.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 20))

            // Video badge (top-right) when the asset is a video.
            if isVideo {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text("Video")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                    Spacer()
                }
            }

            // Decision hints — fade in based on drag direction.
            VStack {
                HStack {
                    decisionBadge(text: "DELETE", color: .red)
                        .opacity(deleteHintOpacity)
                        .rotationEffect(.degrees(-12))
                        .padding(20)
                    Spacer()
                    decisionBadge(text: "KEEP", color: .green)
                        .opacity(keepHintOpacity)
                        .rotationEffect(.degrees(12))
                        .padding(20)
                }
                Spacer()
            }

            // Label pill at the bottom. Optionally with a size chip
            // sitting beside it so the user always knows how much room
            // each triage decision is worth.
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    if !label.isEmpty {
                        Text(label)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if let sizeLabel, !sizeLabel.isEmpty, sizeLabel != "—" {
                        Text(sizeLabel)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 16)
                .padding(.horizontal, 16)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .scaleEffect(scaleForStack)
        .offset(y: yOffsetForStack)
        .offset(dragOffset)
        .rotationEffect(.degrees(rotationAngle))
        .gesture(stackOffset == 0 ? dragGesture : nil)
        .allowsHitTesting(stackOffset == 0 && !isFlying)
        .onChange(of: flyCommand) { _, newValue in
            guard stackOffset == 0, let newValue, !isFlying else { return }
            // Reset the binding immediately so a second tap doesn't re-fire.
            flyCommand = nil
            fly(to: newValue, direction: newValue == .delete ? -1 : 1)
        }
    }

    private func decisionBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, lineWidth: 4)
            )
    }

    private var scaleForStack: CGFloat {
        switch stackOffset {
        case 0: return 1.0
        case 1: return 0.96
        default: return 0.92
        }
    }
    private var yOffsetForStack: CGFloat { CGFloat(stackOffset) * 8 }
    private var rotationAngle: Double { Double(dragOffset.width / 20) }
    private var deleteHintOpacity: Double {
        max(0, min(1, Double(-dragOffset.width / threshold)))
    }
    private var keepHintOpacity: Double {
        max(0, min(1, Double(dragOffset.width / threshold)))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                let dx = value.translation.width
                if dx < -threshold {
                    fly(to: .delete, direction: -1)
                } else if dx > threshold {
                    fly(to: .keep, direction: 1)
                } else {
                    withAnimation(.spring(duration: 0.2)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func fly(to decision: SwipeDecision, direction: CGFloat) {
        isFlying = true
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = CGSize(width: direction * 600, height: dragOffset.height)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            onDecision(decision)
        }
    }
}
