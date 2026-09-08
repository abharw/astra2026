import SwiftUI

/// The primary control: type a request or open the live microphone.
struct ConversationComposer: View {
    @Binding var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isFocused: FocusState<Bool>.Binding
    let isMicrophoneActive: Bool
    let canSend: Bool
    let lineLimit: Int
    let send: () -> Void
    let toggleMicrophone: () -> Void

    private var hasDraft: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            TextField(
                "Ask Astra",
                text: $text,
                prompt: Text("Ask Astra").foregroundStyle(.white.opacity(0.64)),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(.white)
            .lineLimit(1...lineLimit)
            .focused(isFocused)
            .padding(.leading, 18)
            .padding(.vertical, 15)
            .padding(.trailing, 4)
            .accessibilityLabel("Message Astra")
            .accessibilityIdentifier("text-composer")

            Button {
                if hasDraft {
                    send()
                } else {
                    toggleMicrophone()
                }
            } label: {
                Image(systemName: hasDraft ? "arrow.up" : "mic")
                    .font(.system(size: 21, weight: .medium))
                    .symbolVariant(isMicrophoneActive && !hasDraft ? .fill : .none)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .replace)))
                    .foregroundStyle(isActionEnabled ? .black : .white.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .background(isActionEnabled ? Color.white : Color.white.opacity(0.12), in: Circle())
                    .frame(width: 44, height: 44)
            }
            .disabled(!isActionEnabled)
            .accessibilityLabel(actionLabel)
            .accessibilityValue(actionValue)
            .accessibilityIdentifier(hasDraft ? "send-request" : "microphone-button")
        }
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(Color(white: 0.065).opacity(0.97), in: RoundedRectangle(cornerRadius: 29))
        .overlay {
            RoundedRectangle(cornerRadius: 29)
                .strokeBorder(.white.opacity(isFocused.wrappedValue ? 0.28 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }

    private var isActionEnabled: Bool { !hasDraft || canSend }

    private var actionLabel: String {
        if hasDraft { return "Send message" }
        return isMicrophoneActive ? "Pause microphone" : "Start voice conversation"
    }

    private var actionValue: String {
        if hasDraft { return "" }
        return isMicrophoneActive ? "Microphone on" : "Microphone off"
    }
}
