import ARKit
import CoreImage
import OSLog
import RealityKit
import SwiftUI

@MainActor final class ARController: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
  @Published var tracking = "Starting camera…"
  @Published var surface = "Move slowly to map nearby surfaces"
  @Published var phase = "Aim at an object"
  @Published var error: String?
  @Published var busy = false
  @Published var progressParts = 0
  @Published var elapsed = 0
  @Published var assembly: Assembly?
  @Published var selectedID: String?
  @Published var explosion: Double = 0
  @Published var hologram = true
  @Published var inferred = true
  @Published var extracted = false
  @Published var voiceOn = false
  @Published var voiceConnecting = false
  @Published var transcript = ""
  @Published var question = ""
  @Published var answering = false
  private var pendingQuestion: String?
  @Published var macTestEnabled = false
  @Published var macTestStatus = "Mac camera test off"
  private let macTest = BridgeClient()
  @Published var tapToCreate = true
  @Published var targetLocked = false
  @Published var targetScreen: CGPoint?
  @Published var generationInfo = ""
  @Published var researchProgress = ""
  @Published var refinement = ""
  @Published var partExplanation = ""
  private var refinementID: String?
  private var refinementObject: UUID?
  @Published var roomStatus = "Mapping this place…"
  @Published var savedRooms: [SavedRoom] = []
  @Published var restoringRoom = false
  private let roomStore = RoomStore()
  private var roomID = UUID()
  private var placed: [AssemblyRenderer] = []
  private var pendingRoom: SavedRoom?
  private var candidates: [SavedRoom] = []
  private var restoreStarted = Date()
  private var lastRoomSave = Date.distantPast
  private var savingRoom = false
  private var cachedMap: Data?
  private var sessionEpoch = UUID()
  private var sessionRunning = false
  private var firstSession = true
  private var sawRelocalizing = false
  let bridge = BridgeClient()
  let audio = RealtimeAudio()
  let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
  private lazy var renderer = AssemblyRenderer(view: view)
  private let ci = CIContext(options: [.useSoftwareRenderer: false])
  private var targetWorld: SIMD3<Float>?
  private var targetAnchor: AnchorEntity?
  private var capture: Capture?
  private var timer: Timer?
  private var started = Date()
  private var lastUpdate: TimeInterval = 0
  private var installed = false
  private let logger = Logger(subsystem: "com.akeil.spatialassembly", category: "AR")
  struct Capture {
    var id: String
    var camera: ARCamera
    var viewport: CGSize
    var world: SIMD3<Float>
    var imageToView: CGAffineTransform
    var distance: Float
    var depth: DepthSnapshot?
    var rawTarget: CGPoint
  }
  override init() {
    super.init()
    bridge.onEvent = { [weak self] event in self?.handle(event) }
    audio.onAudio = { [weak self] chunk in
      self?.bridge.send(["type": "voice.audio", "audio": chunk])
    }
  }
  func start() {
    guard !sessionRunning else { return }
    sessionRunning = true
    guard ARWorldTrackingConfiguration.isSupported else {
      error = "AR world tracking requires a supported physical iPhone or iPad."
      return
    }
    view.session.delegate = self
    view.session.delegateQueue = .main
    if !firstSession {
      if cachedMap != nil && !savedRooms.isEmpty {
        saveCachedRoom()
        removeScene()
        candidates = savedRooms
        nextPlace()
      } else { view.session.run(configuration()) }
      bridge.connect()
      return
    }
    firstSession = false
    do { savedRooms = try roomStore.rooms() } catch { self.error = "Could not read saved places: " + error.localizedDescription }
    candidates = savedRooms
    nextPlace()
    if !installed {
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      view.addGestureRecognizer(tap)
      installed = true
    }
    bridge.connect()
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--mac-camera-test") { toggleMacTest() }
    #endif
  }
  func toggleMacTest() {
    if macTestEnabled { macTest.disconnect(); macTestEnabled = false; macTestStatus = "Mac camera test off"; UIApplication.shared.isIdleTimerDisabled = false; return }
    guard let url = Bundle.main.url(forResource: "Connection", withExtension: "plist"),
      let data = try? Data(contentsOf: url), let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String:String],
      let endpoint = config["controlURL"], let token = config["controlToken"] else { error = "Pair the Mac camera test connection before building"; return }
    macTest.baseURL = endpoint; macTest.token = token
    macTest.onEvent = { [weak self] event in
      guard let self else { return }
      if event["type"] as? String == "connected" { self.macTestStatus = "Mac camera test connected" }
      if event["type"] as? String == "disconnected" { self.macTestStatus = "Mac test disconnected · stop and retry" }
      if event["type"] as? String == "test.command" { self.testCommand(event) }
    }
    macTestEnabled = true; macTestStatus = "Connecting Mac camera test…"; UIApplication.shared.isIdleTimerDisabled = true; macTest.connect()
  }
  private func testState() -> [String:Any] {
    let frame = view.session.currentFrame
    return ["tracking":tracking,"phase":phase,"busy":busy,"roomStatus":roomStatus,"restoring":restoringRoom,
      "frameTimestamp":frame?.timestamp ?? -1,"frameAge":frame.map{ProcessInfo.processInfo.systemUptime - $0.timestamp} ?? -1,
      "viewSize":[view.bounds.width,view.bounds.height],"bridgeConnected":bridge.connected,"voiceOn":voiceOn,
      "object":assembly?.name ?? "","objectID":assembly == nil ? "" : renderer.objectID.uuidString,
      "parts":assembly?.parts.map{["id":$0.id,"name":$0.name]} ?? [],"selectedPart":selectedID ?? "",
      "explosion":explosion,"extracted":extracted,"error":error ?? "","macTestEnabled":macTestEnabled,"transcript":transcript,"answering":answering,
      "homePose":renderer.snapshot()?.home ?? [],"currentPose":renderer.snapshot()?.pose ?? [],
      "objects":objects().map{["id":$0.id.uuidString,"name":$0.assembly.name]}]
  }
  private func testCommand(_ e:[String:Any]) {
    guard macTestEnabled else { return }
    let id = e["id"] as? String ?? ""
    func reply(_ ok:Bool,_ message:String) { macTest.send(["type":"test.result","id":id,"ok":ok,"message":message,"state":testState()]) }
    switch e["action"] as? String {
    case "state": reply(true,"Current app state")
    case "snapshot":
      guard let frame = view.session.currentFrame, ProcessInfo.processInfo.systemUptime - frame.timestamp < 2 else { reply(false,"No fresh physical camera frame; exit Mirroring and unlock the phone"); return }
      view.snapshot(saveToHDR:false) { [weak self] image in
        Task { @MainActor in
          guard let self else { return }
          guard self.macTestEnabled, let image, let data = image.jpegData(compressionQuality:0.8) else { reply(false,"AR snapshot unavailable"); return }
          self.macTest.send(["type":"test.result","id":id,"ok":true,"message":"Actual ARView camera and virtual geometry snapshot; native toolbar not included","image":data.base64EncodedString(),"state":self.testState()])
        }
      }
    case "tap":
      guard let x = e["x"] as? Double, let y = e["y"] as? Double, (0...1).contains(x), (0...1).contains(y), !busy, !restoringRoom else { reply(false,"Tap unavailable while busy/restoring or invalid coordinates"); return }
      tapObject(at:CGPoint(x:x*view.bounds.width,y:y*view.bounds.height)); reply(error == nil,"Invoked the same object-tap handler used on the phone")
    case "reconstruct": guard !busy else { reply(false,"Already reconstructing"); return }; reconstruct(); reply(busy,"Reconstruction requested; completion is reported separately")
    case "drag":
      guard !busy, extracted, let fx=e["fromX"] as? Double, let fy=e["fromY"] as? Double, let x=e["x"] as? Double, let y=e["y"] as? Double,
        [fx,fy,x,y].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { reply(false,"Extract the model before dragging; use normalized coordinates"); return }
      let ok=renderer.drag(from:CGPoint(x:fx*view.bounds.width,y:fy*view.bounds.height),to:CGPoint(x:x*view.bounds.width,y:y*view.bounds.height)); reply(ok,ok ? "Dragging selected model across the view" : "Drag projection unavailable")
    case "ask": ask(e["question"] as? String ?? ""); reply(pendingQuestion != nil || answering || voiceOn,"Question submitted to the active object context")
    case "cancel": cancel(); reply(true,"Cancelled")
    case "manipulate":
      let result = command(["action":e["operation"] as? String ?? "","amount":e["amount"] as? Double ?? 0,"part":e["part"] as? String ?? ""]); reply(result.0,result.1)
    case "voice.start": if !voiceOn && !voiceConnecting { toggleVoice() }; reply(true,"Voice requested; inspect state for readiness")
    case "voice.stop": stopVoice(); reply(true,"Voice stopped")
    case "explain": explainSelected(); reply(true,"Part explanation requested")
    case "refine": refine(); reply(busy,"Refinement requested")
    default: reply(false,"Unsupported test action")
    }
  }
  private func configuration() -> ARWorldTrackingConfiguration {
    let c = ARWorldTrackingConfiguration()
    c.planeDetection = [.horizontal, .vertical]
    c.environmentTexturing = .automatic
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      c.sceneReconstruction = .mesh
      view.environment.sceneUnderstanding.options.insert(.occlusion)
    }
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      c.frameSemantics.insert(.sceneDepth)
    }
    if let pendingRoom { c.initialWorldMap = try? roomStore.map(pendingRoom) }
    return c
  }
  private func objects() -> [SavedObject] {
    (placed + [renderer]).compactMap { $0.snapshot() }
  }
  // Try maps without showing their models. ARKit must relocalize before content is restored.
  private func nextPlace() {
    sessionEpoch = UUID()
    savingRoom = false
    cachedMap = nil
    lastRoomSave = .distantPast
    if !candidates.isEmpty {
      let next = candidates.removeFirst()
      do { _ = try roomStore.map(next) } catch {
        self.error = "A saved place could not be opened. Its file has been preserved."
        nextPlace(); return
      }
      pendingRoom = next
      restoringRoom = true
      restoreStarted = Date()
      sawRelocalizing = false
      roomStatus = "Looking for: " + next.title + " · look around"
    } else {
      pendingRoom = nil
      restoringRoom = false
      roomID = UUID()
      roomStatus = "New place · mapping automatically"
    }
    view.session.run(configuration(), options: [.resetTracking, .removeExistingAnchors])
  }
  func openPlace(_ room: SavedRoom) {
    guard !busy else { error = "Wait for reconstruction before changing places."; return }
    saveCachedRoom()
    removeScene()
    candidates = [room]
    nextPlace()
  }
  func newPlace() {
    guard !busy else { error = "Wait for reconstruction before changing places."; return }
    saveCachedRoom()
    removeScene()
    candidates = []
    nextPlace()
  }
  private func removeScene() {
    renderer.clear()
    placed.forEach { $0.clear() }
    placed = []
    assembly = nil
    selectedID = nil
    explosion = 0
    extracted = false
    resetTarget()
  }
  private func restorePlace() {
    guard let room = pendingRoom else { return }
    do {
      var restored: [AssemblyRenderer] = []
      do {
        for item in room.objects {
          let r = AssemblyRenderer(view: view)
          try r.restore(item)
          restored.append(r)
        }
      } catch { restored.forEach { $0.clear() }; throw error }
      renderer.clear()
      placed = restored
      if let active = placed.popLast() { renderer = active; synchronizeSelection() }
      roomID = room.id
      cachedMap = room.map
      pendingRoom = nil
      restoringRoom = false
      candidates = []
      roomStatus = "Place recognized · \(room.objects.count) objects restored"
      view.environment.sceneUnderstanding.options.remove(.occlusion)
      logger.info("Restored room with \(room.objects.count) objects")
    } catch {
      self.error = "Could not restore this place: " + error.localizedDescription
      nextPlace()
    }
  }
  private func synchronizeSelection() {
    assembly = renderer.assembly
    selectedID = nil
    explosion = Double(renderer.explosionAmount)
    extracted = renderer.extracted
    hologram = renderer.hologram
    inferred = renderer.showInferred
    syncScene()
  }
  // Map and poses share one coordinate system; never save while testing a different room map.
  private func saveCachedRoom() {
    guard !restoringRoom, let map = cachedMap else { return }
    let records = objects()
    guard !records.isEmpty else { return }
    do {
      try roomStore.write(SavedRoom(id: roomID, updated: Date(), map: map, objects: records))
      savedRooms = try roomStore.rooms()
      roomStatus = "Saved on this iPhone · \(records.count) objects"
    } catch { roomStatus = "Save failed"; self.error = "Could not save this place: " + error.localizedDescription }
  }
  private func saveRoom(frame: ARFrame) {
    guard !restoringRoom, !savingRoom, !objects().isEmpty,
      Date().timeIntervalSince(lastRoomSave) > 5 else { return }
    guard case .normal = frame.camera.trackingState else { return }
    guard frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else {
      roomStatus = "Look around more to save this place"; return
    }
    savingRoom = true
    lastRoomSave = Date()
    // Discard callbacks from an older session so they cannot overwrite a newly selected place.
    let epoch = sessionEpoch
    view.session.getCurrentWorldMap { [weak self] map, failure in
      Task { @MainActor in
        guard let self, self.sessionEpoch == epoch else { return }
        self.savingRoom = false
        guard let map else { self.roomStatus = "Map not saved yet · keep looking around"; return }
        do {
          self.cachedMap = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
          self.saveCachedRoom()
        } catch { self.error = "Could not save room map: " + error.localizedDescription }
      }
    }
  }
  func pause() {
    sessionRunning = false
    if macTestEnabled { toggleMacTest() }
    if busy { cancel() }
    saveCachedRoom()
    stopVoice()
    view.session.pause()
  }
  @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
    tapObject(at: recognizer.location(in: view))
  }
  func tapObject(at p: CGPoint) {
    guard !restoringRoom, !busy else { return }
    if let index = placed.firstIndex(where: { $0.contains(p) }) {
      let picked = placed.remove(at: index)
      if renderer.assembly != nil { placed.append(renderer) }
      renderer = picked
      synchronizeSelection()
    }
    if assembly != nil, let id = renderer.partID(at: p) {
      select(id)
      setExplosion(explosion > 0.05 ? 0 : 1)
      return
    }
    guard !busy else { return }
    if lock(at: p), tapToCreate { reconstruct() }
  }
  private func surfacePoint(at point: CGPoint, frame supplied: ARFrame? = nil) -> SIMD3<Float>? {
    guard let frame = supplied ?? view.session.currentFrame else { return nil }
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return nil }
    let raw = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(frame.displayTransform(for: .portrait, viewportSize: size).inverted())
    if let measured = DepthSnapshot(frame: frame)?.point(raw) { return measured }
    return view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first?.worldTransform.translation
  }
  @discardableResult func lock(at point: CGPoint) -> Bool {
    guard let world = surfacePoint(at: point) else {
      error = "No surface at that point yet. Move the phone slightly, then tap the object again."
      return false
    }
    targetWorld = world
    targetLocked = true
    targetScreen = point
    phase = "Target locked · say ‘reconstruct that’"
    if let targetAnchor { view.scene.removeAnchor(targetAnchor) }
    let anchor = AnchorEntity(world: world)
    let dot = ModelEntity(
      mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .cyan)])
    anchor.addChild(dot)
    view.scene.addAnchor(anchor)
    targetAnchor = anchor
    return true
  }
  func resetTarget() {
    if let targetAnchor { view.scene.removeAnchor(targetAnchor) }
    targetAnchor = nil
    targetWorld = nil
    targetLocked = false
    targetScreen = nil
    phase = "Aim at an object"
  }
  func clear() {
    bridge.send(["type": "reconstruction.cancel"])
    capture = nil
    busy = false
    timer?.invalidate()
    if renderer.assembly != nil { placed.append(renderer); renderer = AssemblyRenderer(view: view) }
    saveCachedRoom()
    assembly = nil
    selectedID = nil
    explosion = 0
    extracted = false
    resetTarget()
    error = nil
  }
  func reconstruct(id: String = UUID().uuidString, hint: String = "") {
    guard !restoringRoom else { failCapture(id, "Recognizing this place first. Look around, or choose New place."); return }
    guard bridge.connected else {
      error = "Reconnect to the Mac bridge before reconstructing."
      bridge.send(["type": "capture.error", "request_id": id, "message": "Bridge not connected"])
      return
    }
    guard !busy else { return }
    guard let frame = view.session.currentFrame, case .normal = frame.camera.trackingState else {
      failCapture(id, "Move the phone slowly until tracking is ready.")
      return
    }
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return }
    var point = CGPoint(x: size.width / 2, y: size.height / 2)
    if let world = targetWorld, let projected = view.project(world),
      CGRect(origin: .zero, size: size).contains(projected)
    {
      point = projected
    } else if targetLocked {
      failCapture(
        id, "The locked target is outside the camera view. Point back at it or unlock the target.")
      return
    }
    let world: SIMD3<Float>
    if let targetWorld {
      world = targetWorld
    } else if let surface = surfacePoint(at: point, frame: frame) {
      world = surface
    } else {
      failCapture(
        id, "No depth or surface at the reticle yet. Move a little closer and tap the object.")
      return
    }
    let distance = simd_distance(world, frame.camera.transform.translation)
    guard distance > 0.12, distance < 8 else {
      failCapture(id, "Move between 0.2 and 5 metres from the object for a useful scan.")
      return
    }
    let transform = frame.displayTransform(for: .portrait, viewportSize: size)
    let rawPoint = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(
      transform.inverted())
    let target = [min(1, max(0, 1 - rawPoint.y)), min(1, max(0, rawPoint.x))]
    let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
    let factor = min(1, 1536 / max(image.extent.width, image.extent.height))
    let resized = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    guard let cg = ci.createCGImage(resized, from: resized.extent),
      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82)
    else {
      failCapture(id, "Camera image could not be captured.")
      return
    }
    capture = Capture(
      id: id, camera: frame.camera, viewport: size, world: world, imageToView: transform,
      distance: distance, depth: DepthSnapshot(frame: frame), rawTarget: rawPoint)
    busy = true
    started = Date()
    elapsed = 0
    progressParts = 0
    error = nil
    phase = "GPT‑6 is reconstructing your object"
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.elapsed = Int(Date().timeIntervalSince(self.started))
      }
    }
    bridge.send([
      "type": "reconstruct", "request_id": id, "mode": refinementID == id ? "refine" : "new", "object_id": refinementID == id ? renderer.objectID.uuidString : id,
      "image": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "target": target,
      "distance": distance, "hint": hint,
    ])
    logger.info("Camera capture sent for reconstruction")
  }
  private func failCapture(_ id: String, _ message: String) {
    error = message
    bridge.send(["type": "capture.error", "request_id": id, "message": message])
  }
  func cancel() {
    bridge.send(["type": "reconstruction.cancel"])
    capture = nil
    refinementID = nil
    refinementObject = nil
    busy = false
    timer?.invalidate()
    phase = assembly == nil ? "Aim at an object" : "Ready to inspect"
  }
  private func install(_ spec: Assembly, from capture: Capture) throws {
    let validated = try spec.validated()
    let c = capture.camera
    let box = validated.bounds
    func screen(_ x: Float, _ y: Float) -> CGPoint {
      let raw = CGPoint(x: CGFloat(y), y: CGFloat(1 - x))
      let q = raw.applying(capture.imageToView)
      return CGPoint(x: q.x * capture.viewport.width, y: q.y * capture.viewport.height)
    }
    // Freeze the source surface pose once. Camera motion never updates this anchor.
    let towardCamera = simd_normalize(c.transform.translation - capture.world)
    let front = capture.depth?.frontNormal(near: capture.rawTarget) ?? towardCamera
    let up: SIMD3<Float> = abs(simd_dot(front, SIMD3<Float>(0, 1, 0))) > 0.95
      ? SIMD3(c.transform.columns.1.x, c.transform.columns.1.y, c.transform.columns.1.z)
      : SIMD3(0, 1, 0)
    let xAxis = simd_normalize(simd_cross(up, front))
    let yAxis = simd_normalize(simd_cross(front, xAxis))
    var world = matrix_identity_float4x4
    world.columns.0 = SIMD4(xAxis, 0)
    world.columns.1 = SIMD4(yAxis, 0)
    world.columns.2 = SIMD4(front, 0)
    var plane = world
    plane.columns.1 = SIMD4(front, 0)
    plane.columns.2 = SIMD4(-yAxis, 0)
    plane.columns.3 = SIMD4(capture.world, 1)
    let left = screen(box[0], (box[1] + box[3]) / 2)
    let right = screen(box[2], (box[1] + box[3]) / 2)
    let top = screen((box[0] + box[2]) / 2, box[1])
    let bottom = screen((box[0] + box[2]) / 2, box[3])
    let center = screen((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
    let maxDimension = validated.sizeMeters.max() ?? 0.4
    var scale = maxDimension
    var origin = capture.world
    var scaleSource = "Estimated scale"
    if let l = c.unprojectPoint(
      left, ontoPlane: plane, orientation: .portrait, viewportSize: capture.viewport),
      let r = c.unprojectPoint(
        right, ontoPlane: plane, orientation: .portrait, viewportSize: capture.viewport),
      let t = c.unprojectPoint(
        top, ontoPlane: plane, orientation: .portrait, viewportSize: capture.viewport),
      let b = c.unprojectPoint(
        bottom, ontoPlane: plane, orientation: .portrait, viewportSize: capture.viewport),
      let o = c.unprojectPoint(
        center, ontoPlane: plane, orientation: .portrait, viewportSize: capture.viewport)
    {
      let width = simd_distance(l, r)
      let height = simd_distance(t, b)
      let scaleX = width / max(validated.sizeMeters[0] / maxDimension, 0.01)
      let scaleY = height / max(validated.sizeMeters[1] / maxDimension, 0.01)
      scale = min(3, max(0.04, (scaleX + scaleY) / 2))
      origin = o
      scaleSource = "Depth-assisted scale estimate"
    }
    world.translation =
      origin - SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
      * (validated.sizeMeters[2] / maxDimension * scale * 0.5)
    if renderer.assembly != nil { placed.append(renderer); renderer = AssemblyRenderer(view: view) }
    try renderer.install(validated, world: world, scale: scale)
    renderer.hologram = hologram
    renderer.showInferred = inferred
    view.environment.sceneUnderstanding.options.remove(.occlusion)
    assembly = validated
    selectedID = nil
    explosion = 0
    extracted = false
    generationInfo = scaleSource + " · " + validated.confidence + " confidence"
    phase = "Anchored · tap to take apart or assemble"
    resetTarget()
    phase = "Anchored · tap to take apart or assemble"
    logger.info("Generated assembly placed in AR: \(validated.parts.count) parts")
  }
  func select(_ id: String) {
    selectedID = id
    renderer.select(id)
    syncScene()
  }
  private func syncScene() {
    var event: [String: Any] = ["type": "scene.update", "object_id": renderer.objectID.uuidString, "selected_part": selectedID ?? ""]
    if let assembly, let data = try? JSONEncoder().encode(assembly), let json = try? JSONSerialization.jsonObject(with: data) { event["assembly"] = json }
    bridge.send(event)
  }
  func refine() {
    guard assembly != nil, !busy, bridge.connected else { return }
    syncScene()
    let id = UUID().uuidString
    refinementID = id
    refinementObject = renderer.objectID
    busy = true
    researchProgress = "Searching references to improve this model…"
    startProgressTimer()
    bridge.send(["type": "rebuild", "request_id": id, "hint": refinement.isEmpty ? "Improve fidelity using relevant technical references" : refinement])
  }
  private func startProgressTimer() {
    started = Date(); elapsed = 0
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in guard let self else { return }; self.elapsed = Int(Date().timeIntervalSince(self.started)) }
    }
  }
  func explainSelected() {
    guard let id = selectedID ?? assembly?.parts.first?.id else { return }
    select(id)
    bridge.send(["type":"part.explain", "part":id])
  }
  private func sendView(_ id: String) {
    guard let frame = view.session.currentFrame else { failCapture(id, "Camera unavailable"); return }
    let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
    let resized = image.transformed(by: CGAffineTransform(scaleX: min(1,1280/image.extent.width), y: min(1,1280/image.extent.width)))
    guard let cg = ci.createCGImage(resized, from: resized.extent), let data = UIImage(cgImage:cg).jpegData(compressionQuality:0.75) else { failCapture(id,"Capture failed"); return }
    bridge.send(["type":"view.frame", "request_id":id, "image":"data:image/jpeg;base64,"+data.base64EncodedString()])
  }
  func setExplosion(_ amount: Double) {
    explosion = min(1, max(0, amount))
    renderer.explode(Float(explosion))
  }
  func setHologram(_ value: Bool) {
    hologram = value
    renderer.hologram = value
  }
  func setInferred(_ value: Bool) {
    inferred = value
    renderer.showInferred = value
  }
  func extract() {
    guard let camera = view.session.currentFrame?.camera.transform else { return }
    renderer.extract(camera: camera)
    view.environment.sceneUnderstanding.options.insert(.occlusion)
    extracted = true
  }
  func returnHome() {
    setExplosion(0)
    renderer.returnHome()
    view.environment.sceneUnderstanding.options.remove(.occlusion)
    extracted = false
  }
  func moveCloser() {
    guard extracted else { error = "Pull out the model before moving it."; return }
    if let camera = view.session.currentFrame?.camera.transform {
      renderer.move("move_forward", amount: 0.2, camera: camera)
    }
  }
  func rotate() {
    guard extracted else { error = "Pull out the model before rotating it."; return }
    renderer.rotate(30)
  }
  func ask(_ text: String) {
    let value=String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(2000))
    guard !value.isEmpty, bridge.connected else { error="Enter a question and connect the bridge"; return }
    syncScene(); transcript=""
    if voiceOn || (answering && !voiceConnecting) { bridge.send(["type":"voice.text","text":value]); return }
    pendingQuestion=value
    if !voiceConnecting { answering=true; voiceConnecting=true; bridge.send(["type":"voice.start"]) }
  }
  func toggleVoice() {
    if voiceOn || voiceConnecting || answering {
      stopVoice()
      return
    }
    guard bridge.connected else {
      error = "Reconnect before starting voice."
      return
    }
    voiceConnecting = true
    Task {
      let allowed = await audio.requestPermission()
      guard voiceConnecting else { return }
      guard allowed else {
        voiceConnecting = false
        error = "Microphone permission is needed for voice commands. Enable it in Settings."
        return
      }
      bridge.send(["type": "voice.start"])
    }
  }
  func stopVoice() {
    voiceConnecting = false
    voiceOn = false
    answering = false; pendingQuestion = nil
    audio.stop()
    bridge.send(["type": "voice.stop"])
  }
  private func handle(_ e: [String: Any]) {
    guard let type = e["type"] as? String else { return }
    switch type {
    case "connected": syncScene()
    case "view.request": sendView(e["request_id"] as? String ?? "")
    case "rebuild.request":
      let id = e["request_id"] as? String ?? UUID().uuidString
      refinementID = id; refinementObject = renderer.objectID
      targetWorld = renderer.sourcePosition; targetLocked = true
      busy = false
      reconstruct(id:id,hint:e["hint"] as? String ?? "Improve this assembly")
      if !busy { refinementID = nil; refinementObject = nil }
    case "reconstruction.started":
      if e["mode"] as? String == "refine" {
        refinementID = e["request_id"] as? String
        refinementObject = renderer.objectID
        busy = true; startProgressTimer()
      }
    case "part.explanation":
      if let p = e["part"] as? [String:Any] { partExplanation = [p["function"] as? String,p["description"] as? String,p["uncertainty"] as? String].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:"\n\n") }
    case "research.warning": researchProgress = e["message"] as? String ?? "Search unavailable"
    case "capture.request":
      reconstruct(
        id: e["request_id"] as? String ?? UUID().uuidString, hint: e["hint"] as? String ?? "")
    case "reconstruction.progress":
      if e["request_id"] as? String == capture?.id || e["request_id"] as? String == refinementID {
        progressParts = e["parts"] as? Int ?? 0
        researchProgress = e["message"] as? String ?? "Generating components…"
      }
    case "reconstruction.complete":
      let isRefinement = e["mode"] as? String == "refine"
      guard (isRefinement && e["request_id"] as? String == refinementID && refinementObject == renderer.objectID) || (!isRefinement && e["request_id"] as? String == capture?.id) else { return }
      defer {
        busy = false
        timer?.invalidate()
        capture = nil
        refinementID = nil; refinementObject = nil
      }
      do {
        guard let object = e["assembly"],
          let data = try? JSONSerialization.data(withJSONObject: object)
        else { throw AssemblyError.invalid }
        let spec = try JSONDecoder().decode(Assembly.self, from: data)
        if isRefinement {
          try renderer.rebuild(spec)
          assembly = spec
          synchronizeSelection()
          saveCachedRoom()
        } else if let current = capture {
          try install(spec, from: current)
          if let id = e["object_id"] as? String, let uuid = UUID(uuidString:id) { renderer.objectID = uuid }
          syncScene()
        }
      } catch {
        self.error = error.localizedDescription
        phase = "Reconstruction could not be displayed"
      }
    case "reconstruction.error":
      guard e["request_id"] as? String == capture?.id || e["request_id"] as? String == refinementID else { return }
      refinementID = nil; refinementObject = nil
      busy = false
      capture = nil
      timer?.invalidate()
      error = e["message"] as? String ?? "Reconstruction failed"
      phase = "Try another view"
    case "voice.ready":
      guard voiceConnecting else { return }
      do {
        try audio.start(inputEnabled: !answering)
        voiceOn = !answering
        voiceConnecting = false
        transcript = answering ? "Thinking…" : "Listening. Try ‘reconstruct that’."
        if let pendingQuestion { self.pendingQuestion=nil; bridge.send(["type":"voice.text","text":pendingQuestion]) }
      } catch {
        self.error = error.localizedDescription
        stopVoice()
      }
    case "voice.audio": if let audio = e["audio"] as? String { self.audio.play(audio) }
    case "voice.transcript.delta":
      if let text = e["text"] as? String {
        if transcript == "Listening. Try ‘reconstruct that’." || transcript == "Thinking…" { transcript = "" }
        transcript += text
      }
    case "voice.transcript": transcript = e["text"] as? String ?? ""
    case "voice.speech_started":
      audio.interrupt()
      transcript = "Listening…"
    case "voice.closed":
      answering = false; pendingQuestion = nil
      voiceOn = false
      voiceConnecting = false
      audio.stop()
    case "voice.error":
      error = e["message"] as? String ?? "Voice connection failed"
      stopVoice()
    case "disconnected":
      stopVoice()
      if busy {
        busy = false
        capture = nil
        timer?.invalidate()
        error = "Connection lost during reconstruction. Reconnect and try again."
      }
    case "command":
      let result = command(e)
      bridge.send([
        "type": "command.result", "call_id": e["call_id"] as? String ?? "",
        "action": e["action"] as? String ?? "", "ok": result.0, "message": result.1,
      ])
    default: break
    }
  }
  func command(_ event: [String: Any]) -> (Bool, String) {
    guard let assembly else {
      return (false, "No generated object yet. Point at a real object and reconstruct it first.")
    }
    let action = event["action"] as? String ?? ""
    let amount = Float((event["amount"] as? NSNumber)?.doubleValue ?? 0)
    if ["move_forward", "move_back", "move_left", "move_right", "move_up", "move_down", "rotate", "scale"].contains(action), !extracted {
      return (false, "The model is fixed to its source position. Use extract to pull it out before moving, rotating or scaling it.")
    }
    switch action {
    case "explode": setExplosion(amount > 0 ? Double(min(amount, 1)) : 1)
    case "assemble": setExplosion(0)
    case "extract": extract()
    case "return": returnHome()
    case "move_forward", "move_back", "move_left", "move_right", "move_up", "move_down":
      guard let camera = view.session.currentFrame?.camera.transform else {
        return (false, "Camera tracking unavailable")
      }
      renderer.move(action, amount: amount == 0 ? 0.2 : amount, camera: camera)
    case "rotate": renderer.rotate(amount == 0 ? 30 : amount)
    case "scale": renderer.scale(amount == 0 ? 1.2 : amount)
    case "select":
      let query = (event["part"] as? String ?? "").lowercased()
      guard !query.isEmpty,
        let p = assembly.parts.first(where: {
          $0.id.lowercased() == query || $0.name.lowercased().contains(query)
            || query.contains($0.name.lowercased())
        })
      else {
        return (
          false,
          "Part not found. Available parts: " + assembly.parts.map(\.name).joined(separator: ", ")
        )
      }
      select(p.id)
    case "show_inferred": setInferred(true)
    case "hide_inferred": setInferred(false)
    case "hologram": setHologram(true)
    case "solid": setHologram(false)
    default: return (false, "Unknown action")
    }
    logger.info("Applied AR command: \(action)")
    return (true, "Applied \(action) to \(assembly.name)")
  }
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard frame.timestamp - lastUpdate > 0.3 else { return }
    lastUpdate = frame.timestamp
    if restoringRoom {
      if case .limited(.relocalizing) = frame.camera.trackingState { sawRelocalizing = true }
      if case .normal = frame.camera.trackingState, sawRelocalizing { restorePlace() }
      else if Date().timeIntervalSince(restoreStarted) > 15 { nextPlace(); return }
    }
    saveRoom(frame: frame)
    switch frame.camera.trackingState {
    case .normal: tracking = "Tracking ready"
    case .notAvailable: tracking = "Tracking unavailable"
    case .limited(let reason):
      switch reason {
      case .initializing: tracking = "Move slowly to begin"
      case .excessiveMotion: tracking = "Move more slowly"
      case .insufficientFeatures: tracking = "Point at a detailed surface"
      case .relocalizing: tracking = "Finding your room again"
      @unknown default: tracking = "Tracking limited"
      }
    }
    let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    if let measured = surfacePoint(at: point, frame: frame) {
      let d = simd_distance(measured, frame.camera.transform.translation)
      surface = String(format: "Surface %.2f m away · tap to lock", d)
    } else {
      surface = "Move slowly to find a surface"
    }
    if let targetWorld { targetScreen = view.project(targetWorld) }
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    self.error = error.localizedDescription
    tracking = "AR session failed"
  }
  func sessionWasInterrupted(_ session: ARSession) {
    tracking = "Camera interrupted"
    stopVoice()
  }
  func sessionInterruptionEnded(_ session: ARSession) { sessionRunning = false; start() }
}
