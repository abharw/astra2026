import SwiftUI
import SpatialApple
import UIKit

struct IllustrationPanel: View {
    let illustration: IllustrationPresentation
    let isCompact: Bool
    let cancel: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if case .ready = illustration.phase, let fileURL = illustration.fileURL {
                Button(action: open) {
                    HStack(spacing: 12) {
                        LocalIllustrationImage(fileURL: fileURL)
                            .frame(width: isCompact ? 42 : 68, height: isCompact ? 42 : 68)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Illustration ready")
                                .font(.subheadline.weight(.semibold))
                            componentNames
                            if !isCompact {
                                Text("Ask Astra to refine this illustration.")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Illustration of \(illustration.componentLabel)")
                .accessibilityHint("Opens the full illustration")
                .accessibilityIdentifier("open-illustration")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(illustration.phase.displayText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(isCompact ? 1 : 3)
                        .accessibilityIdentifier("illustration-status")
                    componentNames
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                IllustrationAction(phase: illustration.phase, canRetry: illustration.canRetry, cancel: cancel, retry: retry)
            }

            if !illustration.phase.isInProgress {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss illustration")
                .accessibilityIdentifier("dismiss-illustration")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.94))
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, isCompact ? 4 : 10)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("illustration-panel")
    }

    private var componentNames: some View {
        Text(illustration.componentLabel)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
    }
}

/// Observe the controller so retry, refinement, and retirement update an open sheet.
struct IllustrationSheet: View {
    @Bindable var controller: SceneController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let illustration = controller.illustration {
                    VStack(alignment: .leading, spacing: 20) {
                        if !illustration.componentNames.isEmpty {
                            Text(illustration.componentNames.joined(separator: ", "))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        if case .ready = illustration.phase, let fileURL = illustration.fileURL {
                            LocalIllustrationImage(fileURL: fileURL)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Illustration of \(illustration.componentLabel)")
                            Text("Ask Astra to refine this illustration.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(illustration.phase.displayText)
                                .font(.body)
                            IllustrationAction(
                                phase: illustration.phase,
                                canRetry: illustration.canRetry,
                                cancel: controller.cancelIllustration,
                                retry: controller.retryIllustration
                            )
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
            .navigationTitle("Illustration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: controller.illustration?.jobID) { _, jobID in
            if jobID == nil { dismiss() }
        }
        .accessibilityIdentifier("illustration-sheet")
    }
}

private struct IllustrationAction: View {
    let phase: IllustrationPhase
    let canRetry: Bool
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        Group {
            switch phase {
            case .generating, .downloading, .retrying:
                Button("Stop", action: cancel)
                    .accessibilityIdentifier("stop-illustration")
            case .failed, .cancelled:
                if canRetry {
                    Button("Retry", action: retry)
                        .accessibilityIdentifier("retry-illustration")
                }
            case .ready:
                EmptyView()
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(minWidth: 44, minHeight: 44)
    }
}

private struct LocalIllustrationImage: View {
    let fileURL: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
        .task(id: fileURL) {
            image = UIImage(contentsOfFile: fileURL.path)
        }
    }
}

private extension IllustrationPresentation {
    var componentLabel: String {
        componentNames.isEmpty ? "Current scene" : componentNames.joined(separator: ", ")
    }
}

private extension IllustrationPhase {
    var isInProgress: Bool {
        switch self {
        case .generating, .downloading, .retrying: true
        case .ready, .failed, .cancelled: false
        }
    }

    var displayText: String {
        switch self {
        case .generating: "Creating illustration…"
        case .downloading: "Downloading illustration…"
        case .retrying: "Retrying illustration…"
        case .ready: "Illustration ready"
        case .failed(let message): message
        case .cancelled: "Illustration stopped"
        }
    }
}
