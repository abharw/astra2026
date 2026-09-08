import Foundation
import Observation
import SwiftUI
import SpatialCore
import SpatialApple

@MainActor
@Observable
final class DemoSessionModel {
    let controller: SceneController

    @ObservationIgnored private var speechLocks: [String: PointingSpeechLock] = [:]
    @ObservationIgnored private var latestSpeechLock: PointingSpeechLock?

    @ObservationIgnored private lazy var voiceSession = VoiceSession(
        selectionProvider: { [weak self] in
            guard let self else { return nil }
            if self.isPointingEnabled {
                self.latestSpeechLock = nil
                guard let lock = self.controller.beginSpeech() else { return nil }
                self.latestSpeechLock = lock
                return [lock.selection.nodeID]
            }
            return self.controller.selection?.nodeIDs ?? []
        },
        onSpeechStarted: { [weak self] binding in
            guard let self, let lock = self.latestSpeechLock else { return }
            self.speechLocks[binding.requestID] = lock
            self.latestSpeechLock = nil
        },
        onFinalTranscript: { [weak self] utterance in
            guard let self else { return }
            if let lock = self.speechLocks.removeValue(forKey: utterance.requestID) {
                self.controller.request(text: utterance.text, speechLock: lock)
                self.controller.endSpeech(lock)
                return
            }
            let selection = utterance.nodeIDs.isEmpty
                ? nil
                : SceneSelection(nodeIDs: utterance.nodeIDs)
            self.controller.request(text: utterance.text, selection: selection)
        },
        onSpeechDiscarded: { [weak self] binding in
            guard let self,
                  let lock = self.speechLocks.removeValue(forKey: binding.requestID)
            else { return }
            self.controller.endSpeech(lock)
        },
        narrationGate: { cue in
            guard cue.intentEpoch == Int(self.controller.acceptedScene.intentEpoch) else { return false }
            let knownNodeIDs = Set(self.controller.acceptedScene.document.nodes.map(\.nodeId))
            return cue.requiredNodeIDs.allSatisfy(knownNodeIDs.contains)
        }
    )

    init() {
        let controller = SceneController()
        self.controller = controller
        controller.onInstalledExplanation = { [weak self] explanation in
            guard let self else { return }
            guard self.voiceSession.isActive else { return }
            let cue = VoiceNarrationCue(
                requestID: explanation.requestID,
                intentEpoch: Int(explanation.intentEpoch),
                requiredNodeIDs: self.controller.selection?.nodeIDs ?? [],
                text: explanation.text
            )
            Task { await self.voiceSession.speak(cue) }
        }
    }

    var backendURL = DemoSessionModel.defaultBackendURL
    var sessionAuthToken = DemoSessionModel.defaultSessionAuthToken
    var composerText = ""
    var isSettingsPresented = false
    var isComposerFocused = false
    var isMicrophoneRequested = false
    var isPointingEnabled = false
    var runtimeUnavailableReason: String?

    var connectionLabel: String {
        String(describing: controller.connectionState)
    }

    var selectionLabel: String {
        guard let selection = controller.selection,
              let primaryNodeID = selection.primaryNodeID
        else {
            return "Nothing selected"
        }
        let name = semanticName(for: primaryNodeID)
        let additionalCount = max(selection.nodeIDs.count - 1, 0)
        return additionalCount == 0 ? name : "\(name) + \(additionalCount)"
    }

    func semanticName(for nodeID: String) -> String {
        controller.acceptedScene.document.nodes
            .first(where: { $0.nodeId == nodeID })?
            .semantic.name ?? nodeID
    }

    var canSend: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var voiceStatusText: String { voiceSession.statusText }
    var isVoiceActive: Bool { voiceSession.isActive }

    var isConnected: Bool {
        controller.connectionState == .connected
    }

    var isConnecting: Bool {
        controller.connectionState == .connecting
    }

    private static var defaultBackendURL: String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ASTRA_BACKEND_URL"] ?? "http://127.0.0.1:8787"
        #else
        return "http://127.0.0.1:8787"
        #endif
    }

    private static var defaultSessionAuthToken: String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ASTRA_SESSION_TOKEN"] ?? ""
        #else
        return ""
        #endif
    }

    func togglePointing() {
        #if targetEnvironment(simulator)
        runtimeUnavailableReason = "Hand pointing requires a physical iPhone or iPad camera. Touch selection remains available in the simulator."
        #else
        isPointingEnabled.toggle()
        #endif
    }

    func loadRack() {
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "json") else {
            runtimeUnavailableReason = "The authored rack scene is not bundled in this build."
            return
        }
        do {
            let document = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: url))
            try controller.loadScene(document)
        } catch {
            runtimeUnavailableReason = "Could not load the authored rack scene: \(error.localizedDescription)"
        }
    }

    func connect() {
        guard let url = URL(string: backendURL), url.scheme != nil else {
            runtimeUnavailableReason = "Enter a valid backend URL."
            return
        }
        controller.connect(url: url, authToken: sessionAuthToken)
    }

    func sendComposer() {
        let request = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        controller.request(text: request, selection: controller.selection)
        composerText = ""
    }

    func requestMicrophone() {
        isMicrophoneRequested = true
        if voiceSession.isActive {
            voiceSession.stop()
            return
        }
        guard let url = URL(string: backendURL), url.scheme != nil else {
            runtimeUnavailableReason = "Enter a valid backend URL before starting voice."
            return
        }
        let configuration = VoiceSessionConfiguration(
            backendBaseURL: url,
            sessionID: "spatial-demo",
            sessionAuthToken: sessionAuthToken.isEmpty ? nil : sessionAuthToken
        )
        Task { await voiceSession.start(configuration: configuration) }
    }

    func stop() {
        controller.stop()
        Task { await voiceSession.invalidateNarration() }
    }

    func undo() {
        controller.undo()
        Task { await voiceSession.invalidateNarration() }
    }
}
