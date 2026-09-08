import SwiftUI

/// The primary control: type a request or open the live microphone.
struct ConversationComposer: View {
    @Binding var text: String
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
        HStack(alignment: .bottom, spacing: 2) {
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

            Button(action: toggleMicrophone) {
                Image(systemName: isMicrophoneActive ? "waveform" : "mic")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(isMicrophoneActive || !hasDraft ? .black : .white)
                    .frame(width: 40, height: 40)
                    .background(
                        isMicrophoneActive || !hasDraft ? Color.white : Color.clear,
                        in: Circle()
                    )
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isMicrophoneActive ? "Pause microphone" : "Start voice conversation")
            .accessibilityValue(isMicrophoneActive ? "Microphone on" : "Microphone off")
            .accessibilityIdentifier("microphone-button")

            if hasDraft {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(canSend ? .black : .white.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .background(canSend ? Color.white : Color.white.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("send-request")
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 5)
        .padding(.top, 1)
        .background(Color(white: 0.065).opacity(0.97), in: RoundedRectangle(cornerRadius: 29))
        .overlay {
            RoundedRectangle(cornerRadius: 29)
                .strokeBorder(.white.opacity(isFocused.wrappedValue ? 0.28 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
    }
}
