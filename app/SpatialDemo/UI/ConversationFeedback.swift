import SwiftUI

struct ConversationFeedback: View {
    let phase: DemoPresentationPhase
    let response: String?
    let responseLineLimit: Int
    let retry: () -> Void
    let openResponse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = phase {
                HStack(alignment: .top, spacing: 10) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    Button("Retry", action: retry)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("retry-action")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("runtime-message")
            } else if phase != .ready {
                ShimmerStatusText(text: phase.label, animates: phase.isAnimating)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.78), in: Capsule())
                    .accessibilityIdentifier("runtime-status")
            }

            if let response, !response.isEmpty {
                Button(action: openResponse) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(response)
                            .font(.subheadline)
                            .lineSpacing(3)
                            .lineLimit(responseLineLimit)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 4)
                    }
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(16)
                    .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(response)
                .accessibilityHint("Opens the complete answer")
                .accessibilityIdentifier("assistant-response")
            }
        }
    }
}

/// Time drives only the highlight, never the work stage.
private struct ShimmerStatusText: View {
    let text: String
    let animates: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(.white.opacity(0.75))
            .overlay {
                if animates && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 2.2) / 2.2
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.85), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geometry.size.width * 0.5)
                            .offset(x: geometry.size.width * (phase * 1.5 - 0.5))
                        }
                        .mask(Text(text))
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(text)
    }
}

struct AssistantResponseSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 620, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            .navigationTitle("Astra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
