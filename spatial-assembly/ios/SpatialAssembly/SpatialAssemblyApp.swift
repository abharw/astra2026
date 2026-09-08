import RealityKit
import SwiftUI

@main struct SpatialAssemblyApp: App {
  var body: some SwiftUI.Scene { WindowGroup { AssemblyScreen().preferredColorScheme(.dark) } }
}
struct ARSurface: UIViewRepresentable {
  let controller: ARController
  func makeUIView(context: Context) -> ARView {
    controller.start()
    return controller.view
  }
  func updateUIView(_ uiView: ARView, context: Context) {}
}
struct AssemblyScreen: View {
  @StateObject private var ar = ARController()
  @Environment(\.scenePhase) private var scenePhase
  @State private var showPlaces = false
  @State private var showParts = false
  @State private var showSettings = false
  @State private var showHelp = false
  private let cyan = Color(red: 0.37, green: 0.92, blue: 1)
  var body: some View {
    ZStack {
      ARSurface(controller: ar).ignoresSafeArea()
      LinearGradient(
        colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.65)], startPoint: .top,
        endPoint: .bottom
      ).ignoresSafeArea().allowsHitTesting(false)
      GeometryReader { proxy in
        let point = ar.targetScreen ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        Image(systemName: ar.targetLocked ? "scope" : "viewfinder").font(
          .system(size: 38, weight: .ultraLight)
        ).foregroundStyle(cyan).shadow(color: .black, radius: 3).position(point)
      }.ignoresSafeArea().allowsHitTesting(false)
      VStack(spacing: 0) {
        header
        Spacer()
        if !ar.transcript.isEmpty && (ar.voiceOn || ar.voiceConnecting) {
          Text(ar.transcript).font(.subheadline).lineLimit(3).padding(12).frame(
            maxWidth: .infinity, alignment: .leading
          ).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(
            .bottom, 10)
        }
        if let error = ar.error {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
              ar.error = nil
            } label: {
              Image(systemName: "xmark")
            }.accessibilityLabel("Dismiss error")
          }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.bottom, 10)
        }
        if ar.busy {
          progressPanel
        } else if let model = ar.assembly {
          modelPanel(model)
        } else {
          capturePanel
        }
      }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
    }.tint(cyan).sheet(isPresented: $showPlaces) { placesSheet }.sheet(isPresented: $showParts) { partsSheet }.sheet(isPresented: $showSettings) {
      BridgeSettings(bridge: ar.bridge)
    }.sheet(isPresented: $showHelp) { helpSheet }.onChange(of: scenePhase) { _, p in
      if p == .active { ar.start() } else { ar.pause() }
    }
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Image(systemName: "cube.transparent").font(.title2).foregroundStyle(cyan)
        VStack(alignment: .leading, spacing: 3) {
          Text("SPATIAL ASSEMBLY").font(.system(size: 15, weight: .semibold, design: .monospaced))
            .tracking(1.8)
          Text(ar.tracking).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
        Spacer()
        Button {
          showHelp = true
        } label: {
          Image(systemName: "questionmark.circle").font(.title3)
        }.accessibilityLabel("How to use Spatial Assembly")
        Button {
          showSettings = true
        } label: {
          Image(systemName: "antenna.radiowaves.left.and.right").font(.title3)
        }.accessibilityLabel("Connection settings")
      }
      ConnectionBadge(bridge: ar.bridge)
      Button { ar.toggleMacTest() } label: { Label(ar.macTestStatus, systemImage: ar.macTestEnabled ? "stop.circle.fill" : "desktopcomputer").font(.caption) }.accessibilityIdentifier("macCameraTestButton")
      HStack {
        Text(ar.roomStatus).font(.caption2).foregroundStyle(ar.restoringRoom ? .orange : .secondary).lineLimit(2)
        Spacer()
        Button { showPlaces = true } label: { Image(systemName: "square.stack.3d.up") }.accessibilityLabel("Saved places")
      }
    }.padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
  }
  private var capturePanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(ar.restoringRoom ? "Recognizing this place…" : ar.targetLocked ? "Target locked." : "Tap an object. Make it 3D.").font(
        .system(size: 25, weight: .medium)
      ).tracking(-0.5)
      Text(ar.targetLocked ? "Keep the object in view, then reconstruct it." : ar.surface).font(
        .subheadline
      ).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Button {
          ar.reconstruct()
        } label: {
          Label("Reconstruct that", systemImage: "cube.transparent.fill").frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }.buttonStyle(.borderedProminent).foregroundStyle(.black).accessibilityIdentifier(
          "reconstructButton").disabled(ar.restoringRoom)
        voiceButton
      }
      Toggle("Tap objects to reconstruct", isOn: $ar.tapToCreate).font(.subheadline).accessibilityIdentifier("tapToCreateToggle")
      if ar.restoringRoom { Button("I’m somewhere new") { ar.newPlace() }.font(.subheadline) }
      if ar.targetLocked { Button("Unlock target") { ar.resetTarget() }.font(.subheadline) }
      Text("Selected camera images go to OpenAI. Generated shapes and hidden parts are estimates.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
  }
  private var progressPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        ProgressView().tint(cyan)
        Text("Reconstructing your object").font(.headline)
        Spacer()
        Text("\(ar.elapsed)s").monospacedDigit().foregroundStyle(cyan)
      }
      Text(
        ar.progressParts == 0
          ? (ar.researchProgress.isEmpty ? "GPT‑6 is reading the selected camera frame…" : ar.researchProgress)
          : "\(ar.progressParts) components described so far…"
      ).font(.subheadline).foregroundStyle(.secondary)
      Text("Your capture is fixed in the room.").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Cancel") { ar.cancel() }.buttonStyle(.bordered)
        Spacer()
        voiceButton
      }
    }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
  }
  private func modelPanel(_ model: Assembly) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.name).font(.headline).lineLimit(2)
          Text("Generated approximation · \(model.parts.count) parts").font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        voiceButton
      }
      HStack {
        Text("Assembled")
        Slider(value: Binding(get: { ar.explosion }, set: { ar.setExplosion($0) }), in: 0...1)
          .accessibilityLabel("Explode assembly")
        Text("Exploded")
      }.font(.caption)
      HStack(spacing: 8) {
        Button {
          ar.extracted ? ar.returnHome() : ar.extract()
        } label: {
          Label(
            ar.extracted ? "Return" : "Pull out",
            systemImage: ar.extracted
              ? "arrow.uturn.backward" : "arrow.down.forward.and.arrow.up.backward"
          ).frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).foregroundStyle(.black)
        Button {
          showParts = true
        } label: {
          Label("Parts", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
        }.buttonStyle(.bordered)
      }
      HStack(spacing: 10) {
        Button("Research & rebuild") { ar.refine() }.buttonStyle(.bordered)
        Button("Explain part") { ar.explainSelected(); showParts = true }.buttonStyle(.bordered)
      }.font(.caption)
      HStack(spacing: 14) {
        Button {
          ar.moveCloser()
        } label: {
          Label("Closer", systemImage: "arrow.down.right.and.arrow.up.left")
        }
        Button {
          ar.rotate()
        } label: {
          Label("Rotate", systemImage: "rotate.3d")
        }
        Spacer()
        Button {
          ar.setHologram(!ar.hologram)
        } label: {
          Image(systemName: ar.hologram ? "cube.fill" : "cube.transparent")
        }.accessibilityLabel(ar.hologram ? "Show solid model" : "Show hologram")
        Button {
          ar.clear()
        } label: {
          Image(systemName: "plus.viewfinder")
        }.accessibilityLabel("Scan a new object")
      }.font(.subheadline)
      if let p = model.parts.first(where: { $0.id == ar.selectedID }) {
        Text("\(p.name) · \(p.evidence)").font(.caption).foregroundStyle(
          p.evidence == "inferred" ? .orange : cyan)
      }
      Text(ar.extracted ? "Drag to move · pinch to scale · twist to rotate" : "Anchored to source · tap model to explode / assemble").font(.caption2).foregroundStyle(
        .secondary)
    }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
  }
  private var voiceButton: some View {
    Button {
      ar.toggleVoice()
    } label: {
      Image(systemName: ar.voiceConnecting ? "ellipsis" : ar.voiceOn ? "mic.fill" : "mic").font(
        .title3
      ).frame(width: 35, height: 35)
    }.buttonStyle(.bordered).tint(ar.voiceOn ? .red : cyan).accessibilityLabel(
      ar.voiceOn ? "Stop voice" : "Start voice"
    ).accessibilityIdentifier("voiceButton")
  }
  private var placesSheet: some View {
    NavigationStack {
      List {
        Section {
          Text(ar.roomStatus)
          Text("Places save automatically on this iPhone. When you return, look at the same surroundings to restore your objects. Changed rooms and poor lighting can prevent recognition.").font(.caption).foregroundStyle(.secondary)
          Button("Start a new place") { ar.newPlace(); showPlaces = false }.disabled(ar.busy)
        }
        Section("Saved places") {
          if ar.savedRooms.isEmpty { Text("Generate an object, then look around until Saved appears.").foregroundStyle(.secondary) }
          ForEach(ar.savedRooms) { room in
            Button {
              ar.openPlace(room)
              showPlaces = false
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(room.title)
                Text("\(room.objects.count) objects · \(room.updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
              }
            }.disabled(ar.busy)
          }
        }
      }.navigationTitle("Your places").toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { showPlaces = false } }
      }
    }
  }
  private var partsSheet: some View {
    NavigationStack {
      List {
        if let model = ar.assembly {
          Section {
            Text(model.description).font(.subheadline)
            Text(ar.generationInfo).font(.caption).foregroundStyle(.secondary)
            Toggle(
              "Show inferred parts",
              isOn: Binding(get: { ar.inferred }, set: { ar.setInferred($0) }))
          }
          Section("Improve this reconstruction") {
            TextField("Correction or part to improve", text: $ar.refinement)
            Button("Find references and rebuild") { ar.refine(); showParts = false }
          }
          if !ar.partExplanation.isEmpty { Section("Part explanation") { Text(ar.partExplanation) } }
          if let research = ar.assembly?.research {
            Section("Technical references") {
              Text(research.summary).font(.subheadline)
              ForEach(research.sources) { source in
                VStack(alignment: .leading, spacing: 5) {
                  if let url = URL(string: source.url), ["https","http"].contains(url.scheme ?? "") {
                    Link(source.title, destination: url)
                  }
                  Text(source.match == "exact" ? "Exact-model reference" : "Similar/general reference · not proof of this object's internals").font(.caption).foregroundStyle(source.match == "exact" ? .cyan : .orange)
                  Text(source.findings).font(.caption)
                }
              }
              ForEach(research.gaps, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
          }
          Section("Select a component") {
            ForEach(model.parts) { p in
              Button {
                ar.select(p.id)
                showParts = false
              } label: {
                HStack {
                  Image(systemName: ar.selectedID == p.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(cyan)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).foregroundStyle(.primary)
                    Text(p.function ?? p.description).font(.caption).foregroundStyle(.secondary)
                    Text(p.evidence.uppercased()).font(.caption2.monospaced()).foregroundStyle(
                      p.evidence == "inferred" ? .orange : cyan)
                  }
                }.padding(.vertical, 5)
              }
            }
          }
        }
      }.navigationTitle("Assembly parts").toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { showParts = false } }
      }
    }
  }
  private var helpSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text("From your room into your hands.").font(.largeTitle.bold())
          Text(
            "1. Move the phone slowly until Tracking ready appears.\n\n2. Tap a real object to reconstruct it. Turn off Tap objects to reconstruct if you prefer to lock the target first.\n\n3. You can also turn on the microphone and say reconstruct that, or use the Reconstruct that button.\n\n4. The overlay stays anchored over the source. Tap it to take it apart, then tap again to assemble it there.\n\n5. Use Pull out to move it; Return restores its original pose."
          )
          Text("Try saying").font(.headline)
          Text(
            "‘Take it apart.’\n‘Bring it closer.’\n‘Select the handle.’\n‘Make it bigger.’\n‘Put it back together.’"
          ).foregroundStyle(cyan)
          Text(
            "This prototype uses one camera image and a depth estimate. It creates editable geometric approximations, not exact scans. Internal components are inferred. The Mac bridge must stay running. Voice sends microphone audio only while the mic is enabled."
          ).font(.subheadline).foregroundStyle(.secondary)
        }.padding(24)
      }.navigationTitle("How it works").toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { showHelp = false } }
      }
    }
  }
}
struct ConnectionBadge: View {
  @ObservedObject var bridge: BridgeClient
  var body: some View {
    HStack(spacing: 7) {
      Circle().fill(bridge.connected ? .mint : .orange).frame(width: 6, height: 6)
      Text(bridge.status).font(.caption2).lineLimit(2)
      Spacer()
      if !bridge.connected { Button("Reconnect") { bridge.reconnect() }.font(.caption) }
    }
  }
}
struct BridgeSettings: View {
  @ObservedObject var bridge: BridgeClient
  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  var body: some View {
    NavigationStack {
      Form {
        Section("Mac bridge") {
          TextField("HTTPS bridge URL", text: $url).textInputAutocapitalization(.never)
            .autocorrectionDisabled().keyboardType(.URL)
          Text(bridge.status).font(.caption)
          Button("Save and reconnect") {
            guard URL(string: url)?.scheme == "https" else { return }
            bridge.baseURL = url
            UserDefaults.standard.set(url, forKey: "bridgeURL")
            bridge.reconnect()
            dismiss()
          }
        }
        Section {
          Text(
            "GPT‑6 Astra generates component geometry. OpenAI Realtime handles voice and tools. The OpenAI API key stays on your Mac; this device has a scoped bridge credential."
          ).font(.subheadline)
        }
      }.navigationTitle("Connection").toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
      }.onAppear { url = bridge.baseURL }
    }
  }

}
