import ARKit
import RealityKit
import UIKit
import simd

@MainActor final class AssemblyRenderer {
  private(set) var anchor: AnchorEntity?
  private(set) var root: ModelEntity?
  private(set) var assembly: Assembly?
  private var groups: [String: Entity] = [:]
  private var meshes: [String: [(ModelEntity, Primitive)]] = [:]
  var objectID = UUID()
  private(set) var explosionAmount: Float = 0
  private var home = matrix_identity_float4x4
  private(set) var extracted = false
  private var selected: String?
  var hologram = true { didSet { restyle() } }
  var showInferred = true { didSet { restyle() } }
  private var installedGestures: [UIGestureRecognizer] = []
  weak var view: ARView?
  init(view: ARView) { self.view = view }
  func clear() {
    if let anchor { view?.scene.removeAnchor(anchor) }
    for g in installedGestures { view?.removeGestureRecognizer(g) }
    installedGestures = []
    anchor = nil
    root = nil
    groups = [:]
    meshes = [:]
    assembly = nil
    selected = nil
    extracted = false
  }
  func install(_ spec: Assembly, world: simd_float4x4, scale: Float) throws {
    guard let view else { return }
    let newAnchor = AnchorEntity(world: world)
    let newRoot = ModelEntity()
    newRoot.name = "assembly-root"
    newRoot.scale = SIMD3(repeating: scale)
    var newGroups: [String: Entity] = [:]
    var newMeshes: [String: [(ModelEntity, Primitive)]] = [:]
    for part in spec.parts {
      let group = Entity()
      group.name = "part:\(part.id)"
      for primitive in part.primitives {
        let geometry: MeshResource
        switch primitive.kind {
        case "sphere": geometry = .generateSphere(radius: 0.5)
        case "cylinder": geometry = .generateCylinder(height: 1, radius: 0.5)
        case "cone": geometry = try Self.cone()
        case "torus":
          geometry = try Self.torus(
            tubeRatio: min(0.45, max(0.02, primitive.size[1] / max(primitive.size[0], 0.001))))
        default: geometry = .generateBox(size: 1, cornerRadius: 0.012)
        }
        let m = ModelEntity(
          mesh: geometry, materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
        m.name = "part:\(part.id)"
        m.position = primitive.position.vector
        m.scale = primitive.size.vector
        if primitive.kind == "torus" {
          m.scale = SIMD3(primitive.size[0], primitive.size[0], primitive.size[2])
        }
        let r = primitive.rotation.vector * (.pi / 180)
        m.orientation =
          simd_quatf(angle: r.z, axis: [0, 0, 1]) * simd_quatf(angle: r.y, axis: [0, 1, 0])
          * simd_quatf(angle: r.x, axis: [1, 0, 0])
        m.generateCollisionShapes(recursive: false)
        group.addChild(m)
        newMeshes[part.id, default: []].append((m, primitive))
      }
      newRoot.addChild(group)
      newGroups[part.id] = group
    }
    let bounds = newRoot.visualBounds(relativeTo: newRoot)
    newRoot.collision = CollisionComponent(shapes: [
      .generateBox(size: simd_max(bounds.extents, SIMD3(repeating: 0.01))).offsetBy(
        translation: bounds.center)
    ])
    clear()
    assembly = spec
    anchor = newAnchor
    root = newRoot
    groups = newGroups
    meshes = newMeshes
    newAnchor.addChild(newRoot)
    view.scene.addAnchor(newAnchor)
    home = newRoot.transformMatrix(relativeTo: nil)
    installedGestures = view.installGestures([.translation, .rotation, .scale], for: newRoot).map {
      $0 as UIGestureRecognizer
    }
    installedGestures.forEach { $0.isEnabled = false }
    restyle()
  }
  func select(_ id: String?) {
    selected = id
    restyle()
  }
  func partID(at point: CGPoint) -> String? {
    guard let view else { return nil }
    let hits = view.hitTest(point, query: .all, mask: .all)
    for hit in hits {
      var ancestor: Entity? = hit.entity
      while ancestor != nil && ancestor !== root { ancestor = ancestor?.parent }
      guard ancestor != nil else { continue }
      var node: Entity? = hit.entity
      while let n = node {
        if n.name.hasPrefix("part:") { return String(n.name.dropFirst(5)) }
        node = n.parent
      }
    }
    return nil
  }
  private func restyle() {
    guard let assembly else { return }
    for part in assembly.parts {
      groups[part.id]?.isEnabled = showInferred || part.evidence != "inferred"
      for (m, p) in meshes[part.id] ?? [] {
        let chosen = selected == part.id
        if hologram {
          let color: UIColor =
            chosen
            ? .white
            : (part.evidence == "inferred"
              ? UIColor(red: 1, green: 0.66, blue: 0.23, alpha: 1)
              : UIColor(red: 0.18, green: 0.88, blue: 1, alpha: 1))
          var material = UnlitMaterial(color: color)
          material.blending = .transparent(opacity: .init(floatLiteral: chosen ? 0.88 : 0.48))
          m.model?.materials = [material]
        } else {
          let color =
            chosen
            ? UIColor(red: 0.45, green: 0.94, blue: 1, alpha: 1)
            : UIColor(
              red: CGFloat(p.color[0]), green: CGFloat(p.color[1]), blue: CGFloat(p.color[2]),
              alpha: 1)
          m.model?.materials = [SimpleMaterial(color: color, roughness: 0.5, isMetallic: false)]
        }
      }
    }
  }
  // Animate component-local offsets only, leaving the assembly source pose unchanged.
  func explode(_ amount: Float) {
    explosionAmount = min(1, max(0, amount))
    guard let assembly else { return }
    for part in assembly.parts {
      guard let g = groups[part.id] else { continue }
      var t = g.transform
      t.translation = part.explode.vector * min(1, max(0, amount))
      g.move(to: t, relativeTo: root, duration: 0.25, timingFunction: .easeInOut)
    }
  }
  func extract(camera: simd_float4x4) {
    guard let root else { return }
    installedGestures.forEach { $0.isEnabled = true }
    var t = Transform(matrix: root.transformMatrix(relativeTo: nil))
    let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
    t.translation = camera.translation + forward * 0.8 + SIMD3(0, -0.12, 0)
    root.move(to: t, relativeTo: nil, duration: 0.8, timingFunction: .easeInOut)
    extracted = true
  }
  func returnHome() {
    guard let root else { return }
    root.move(
      to: Transform(matrix: home), relativeTo: nil, duration: 0.8, timingFunction: .easeInOut)
    extracted = false
    installedGestures.forEach { $0.isEnabled = false }
  }
  func move(_ action: String, amount: Float, camera: simd_float4x4) {
    guard let root, extracted else { return }
    let step = min(1, max(0.05, abs(amount)))
    let right = SIMD3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z)
    let towardCamera = SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
    let direction: SIMD3<Float>
    switch action {
    case "move_left": direction = -right
    case "move_right": direction = right
    case "move_up": direction = [0, 1, 0]
    case "move_down": direction = [0, -1, 0]
    case "move_back": direction = -towardCamera
    default: direction = towardCamera
    }
    var t = Transform(matrix: root.transformMatrix(relativeTo: nil))
    t.translation += direction * step
    root.move(to: t, relativeTo: nil, duration: 0.3, timingFunction: .easeInOut)
  }
  func rotate(_ degrees: Float) {
    guard let root, extracted else { return }
    root.orientation = simd_quatf(angle: degrees * .pi / 180, axis: [0, 1, 0]) * root.orientation
  }
  func scale(_ multiplier: Float) {
    guard let root, extracted else { return }
    let s = min(3, max(0.25, multiplier))
    root.scale = simd_clamp(root.scale * s, SIMD3(repeating: 0.02), SIMD3(repeating: 5))
  }
  func contains(_ point: CGPoint) -> Bool { partID(at: point) != nil }
  func snapshot() -> SavedObject? {
    guard let assembly, let root else { return nil }
    return SavedObject(id: objectID, assembly: assembly, home: home.savedValues,
      pose: root.transformMatrix(relativeTo: nil).savedValues, explosion: explosionAmount,
      hologram: hologram, inferred: showInferred, extracted: extracted)
  }
  // Restore both poses: current placement for display, home placement for the Return action.
  func restore(_ saved: SavedObject) throws {
    guard let homePose = simd_float4x4(savedValues: saved.home), let pose = simd_float4x4(savedValues: saved.pose) else { throw AssemblyError.invalid }
    try install(try saved.assembly.validated(), world: homePose, scale: 1)
    objectID = saved.id
    root?.setTransformMatrix(pose, relativeTo: nil)
    home = homePose
    extracted = saved.extracted
    installedGestures.forEach { $0.isEnabled = extracted }
    hologram = saved.hologram
    showInferred = saved.inferred
    explode(saved.explosion)
  }
  private static func cone() throws -> MeshResource {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var triangles: [UInt32] = []
    let steps = 40
    for i in 0..<steps {
      let a = Float(i) * 2 * .pi / Float(steps)
      let b = Float(i + 1) * 2 * .pi / Float(steps)
      let base = UInt32(positions.count)
      let p = SIMD3<Float>(cos(a) * 0.5, -0.5, sin(a) * 0.5)
      let q = SIMD3<Float>(cos(b) * 0.5, -0.5, sin(b) * 0.5)
      let top = SIMD3<Float>(0, 0.5, 0)
      positions += [p, top, q, p, q, [0, -0.5, 0]]
      let n = simd_normalize(simd_cross(top - p, q - p))
      normals += [n, n, n, [0, -1, 0], [0, -1, 0], [0, -1, 0]]
      triangles += [base, base + 1, base + 2, base + 3, base + 4, base + 5]
    }
    var d = MeshDescriptor(name: "cone")
    d.positions = MeshBuffer(positions)
    d.normals = MeshBuffer(normals)
    d.primitives = .triangles(triangles)
    return try MeshResource.generate(from: [d])
  }
  private static func torus(tubeRatio: Float) throws -> MeshResource {
    var p: [SIMD3<Float>] = []
    var n: [SIMD3<Float>] = []
    var idx: [UInt32] = []
    let a = 48
    let b = 12
    let tube = tubeRatio * 0.5
    let ring = 0.5 - tube
    for i in 0...a {
      let u = Float(i) * 2 * .pi / Float(a)
      for j in 0...b {
        let v = Float(j) * 2 * .pi / Float(b)
        p.append([(ring + tube * cos(v)) * cos(u), tube * sin(v), (ring + tube * cos(v)) * sin(u)])
        n.append([cos(v) * cos(u), sin(v), cos(v) * sin(u)])
      }
    }
    for i in 0..<a {
      for j in 0..<b {
        let k = UInt32(i * (b + 1) + j)
        let l = k + UInt32(b + 1)
        idx += [k, l, k + 1, k + 1, l, l + 1]
      }
    }
    var d = MeshDescriptor(name: "torus")
    d.positions = MeshBuffer(p)
    d.normals = MeshBuffer(n)
    d.primitives = .triangles(idx)
    return try MeshResource.generate(from: [d])
  }
}
