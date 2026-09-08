import Foundation
import RealityKit
import SpatialCore
import simd

#if os(macOS)
import AppKit
private typealias FlowColor = NSColor
#else
import UIKit
private typealias FlowColor = UIColor
#endif

/// Event cadence and marker-loop CPU measurements, not GPU frame timings.
public struct FlowRenderMetrics: Codable, Sendable {
    public let flowCount: Int
    public let visibleFlowCount: Int
    public let markerCount: Int
    public let meshCount: Int
    public let vertexCount: Int
    public let triangleCount: Int
    public let meshRebuildCount: UInt64
    public let updateCount: UInt64
    public let sampleCount: Int
    public let meanFrameIntervalMs: Double
    public let p95FrameIntervalMs: Double
    public let meanMarkerUpdateMs: Double
    public let p95MarkerUpdateMs: Double
    public let maximumMarkerUpdateMs: Double
    public let animationEnabled: Bool
}

enum FlowPreparationError: Error {
    case invalidTransform(String)
    case missingBinding(String)
    case resourceBudget
}

struct FlowShapeKey: Hashable {
    let controls: [SIMD3<Double>]
    let width: Double
}

@MainActor
final class PreparedFlowShape {
    let path: FlowPath
    let mesh: FlowMesh?
    let selectionShapes: [ShapeResource]

    init(path: FlowPath, width: Double) throws {
        self.path = path
        mesh = path.isDegenerate ? nil : try compileFlowMesh(path: path, width: width)
        guard !path.isDegenerate else { selectionShapes = []; return }
        // Small segment proxies preserve the opening inside a curved path. A
        // single convex hull would intercept taps on the enclosed real parts.
        let count = min(24, max(1, path.points.count - 1))
        selectionShapes = (0..<count).compactMap { index in
            let a = path.sample(at: path.length * Double(index) / Double(count)).position
            let b = path.sample(at: path.length * Double(index + 1) / Double(count)).position
            let length = simd_length(b - a)
            guard length > 1e-7 else { return nil }
            return ShapeResource.generateBox(size: [Float(width * 2), length, Float(width * 2)])
                .offsetBy(rotation: simd_quatf(from: [0, 1, 0], to: (b - a) / length), translation: (a + b) / 2)
        }
    }
}

struct FlowLabelMesh {
    let resource: MeshResource
    let vertexCount: Int
    let triangleCount: Int
}

struct PreparedFlow {
    let shape: PreparedFlowShape
    let recipe: FlowRecipe
    let color: [Double]
    let label: FlowLabelMesh?
    let labelPosition: SIMD3<Float>
    let worldLengths: [Double]
    var worldLength: Double { worldLengths.last ?? 0 }
}

struct PreparedFlows {
    var byNodeID: [String: PreparedFlow] = [:]
    var shapes: [FlowShapeKey: PreparedFlowShape] = [:]
    var labels: [String: FlowLabelMesh] = [:]
    var marker: FlowLabelMesh?
    var labelBackground: FlowLabelMesh?
}

/// Native resources are derived from accepted scene values. Preparation keeps
/// candidate resources separate; install is the only change to the live cache.
@MainActor
final class FlowRenderer {
    private final class LiveFlow {
        let root: Entity
        var prepared: PreparedFlow
        var body: ModelEntity?
        var markers: [ModelEntity] = []
        var label: Entity?
        var distance = 0.0

        init(root: Entity, prepared: PreparedFlow) {
            self.root = root
            self.prepared = prepared
        }
    }

    private var shapes: [FlowShapeKey: PreparedFlowShape] = [:]
    private var labels: [String: FlowLabelMesh] = [:]
    private var marker: FlowLabelMesh?
    private var labelBackground: FlowLabelMesh?
    private var live: [String: LiveFlow] = [:]
    private var animationEnabled = true
    private var metricsEnabled = false
    private var rebuildCount: UInt64 = 0
    private var updateCount: UInt64 = 0
    private var intervals = [Double](repeating: 0, count: 300)
    private var updateDurations = [Double](repeating: 0, count: 300)
    private var sampleCount = 0
    private var sampleIndex = 0

    func prepare(_ document: SceneDocument) throws -> PreparedFlows {
        let geometries = Dictionary(uniqueKeysWithValues: document.geometryDefinitions.map { ($0.geometryId, $0.recipe) })
        let materials = Dictionary(uniqueKeysWithValues: document.materials.map { ($0.materialId, $0.baseColorLinear) })
        let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.nodeId, $0) })
        let flowNodes = document.nodes.filter { node in
            guard let geometryID = node.geometryId, case .flow? = geometries[geometryID] else { return false }
            return true
        }
        guard flowNodes.count <= 32 else { throw FlowPreparationError.resourceBudget }
        guard !flowNodes.isEmpty else { return PreparedFlows() }
        var matrices: [String: simd_double4x4] = [:]
        var visiting = Set<String>()
        func world(_ id: String) throws -> simd_double4x4 {
            if let matrix = matrices[id] { return matrix }
            guard let node = nodes[id], visiting.insert(id).inserted else { throw FlowPreparationError.missingBinding(id) }
            defer { visiting.remove(id) }
            let local = try node.transform.flowMatrix(nodeID: id)
            let result = try node.parentId.map { try world($0) * local } ?? local
            let nativeDouble = simd_double4x4([result.columns.0, result.columns.1, result.columns.2, result.columns.3]
                .map { SIMD4<Double>(SIMD4<Float>($0)) })
            guard result.isFinite, nativeDouble.isFinite,
                  abs(simd_determinant(result)) > Double.leastNormalMagnitude,
                  abs(simd_determinant(nativeDouble)) > Double.leastNormalMagnitude else {
                throw FlowPreparationError.invalidTransform(id)
            }
            matrices[id] = result
            return result
        }
        var prepared = PreparedFlows()
        var expandedTriangles = 0
        var expandedVertices = 0
        for node in flowNodes {
            guard let geometryID = node.geometryId, case .flow(let recipe)? = geometries[geometryID] else { continue }
            let annotationWorld = try world(node.nodeId)
            let inverse = simd_inverse(annotationWorld)
            guard inverse.isFinite else { throw FlowPreparationError.invalidTransform(node.nodeId) }
            func resolve(_ attachment: FlowAttachment) throws -> SIMD3<Double> {
                let point = try inverse * world(attachment.nodeId) * SIMD4(attachment.localPoint.flowVector, 1)
                let result = SIMD3(point.x, point.y, point.z)
                guard result.isFinite, SIMD3<Float>(result).isFinite else { throw FlowPreparationError.invalidTransform(attachment.nodeId) }
                return result
            }
            var controls = try [resolve(recipe.source)] + recipe.routePoints.map(\.flowVector) + [resolve(recipe.target)]
            if recipe.direction == .reverse { controls.reverse() }
            let key = FlowShapeKey(controls: controls, width: recipe.width)
            let shape: PreparedFlowShape
            if let cached = prepared.shapes[key] ?? shapes[key] { shape = cached }
            else {
                shape = try PreparedFlowShape(path: FlowPath(controlPoints: controls), width: recipe.width)
                if shape.mesh != nil { rebuildCount &+= 1 }
            }
            prepared.shapes[key] = shape
            var label: FlowLabelMesh?
            if !recipe.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !shape.path.isDegenerate {
                if let cached = prepared.labels[recipe.label] ?? labels[recipe.label] { label = cached }
                else {
                    let mesh = MeshResource.generateText(recipe.label, extrusionDepth: 0,
                        font: .systemFont(ofSize: 1, weight: .medium),
                        containerFrame: CGRect(x: 0, y: 0, width: 22, height: 6),
                        alignment: .center, lineBreakMode: .byWordWrapping)
                    let counted = Self.counted(mesh)
                    if counted.vertexCount > 0, mesh.bounds.center.isFinite { label = counted }
                }
                prepared.labels[recipe.label] = label
            }
            if label != nil, prepared.labelBackground == nil {
                // Every label scales this shared unit XY plane to its measured
                // text bounds. No per-label or per-frame backing meshes.
                prepared.labelBackground = labelBackground ?? Self.counted(MeshResource.generatePlane(width: 1, height: 1))
            }
            if !shape.path.isDegenerate, prepared.marker == nil {
                if let marker { prepared.marker = marker }
                else {
                    let recipe = GeometryRecipe.sphere(radius: 1, segments: 12)
                    let definition = GeometryDefinition(geometryId: "flow.marker", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
                    prepared.marker = Self.counted(try GeometryCompiler().resource(for: definition))
                }
            }
            // Motion advances at a physical rate even under nonuniformly scaled
            // ancestors. Interpolation still returns annotation-local positions.
            var worldLengths = [Double]()
            worldLengths.reserveCapacity(shape.path.points.count)
            var previous: SIMD3<Double>?
            var distance = 0.0
            for point in shape.path.points {
                let transformed = annotationWorld * SIMD4(point, 1)
                let position = SIMD3(transformed.x, transformed.y, transformed.z)
                if let previous { distance += simd_length(position - previous) }
                guard distance.isFinite else { throw FlowPreparationError.invalidTransform(node.nodeId) }
                worldLengths.append(distance)
                previous = position
            }
            let panelHeight = label.map { $0.resource.bounds.extents.y + Self.labelVerticalPadding * 2 } ?? 0
            let labelLift = panelHeight * Self.labelScale / 2 + Float(recipe.width * 2 + 0.02)
            let value = PreparedFlow(shape: shape, recipe: recipe,
                color: node.materialId.flatMap { materials[$0] } ?? [0.04, 0.62, 1, 1], label: label,
                labelPosition: SIMD3<Float>((annotationWorld * SIMD4(SIMD3<Double>(shape.path.sample(at: shape.path.length / 2).position), 1)).xyz) + [0, labelLift, 0],
                worldLengths: worldLengths)
            prepared.byNodeID[node.nodeId] = value
            expandedTriangles += (shape.mesh?.triangleCount ?? 0) + (label?.triangleCount ?? 0) + 4 * (prepared.marker?.triangleCount ?? 0)
            expandedVertices += (shape.mesh?.vertexCount ?? 0) + (label?.vertexCount ?? 0) + 4 * (prepared.marker?.vertexCount ?? 0)
            if label != nil {
                expandedTriangles += prepared.labelBackground?.triangleCount ?? 0
                expandedVertices += prepared.labelBackground?.vertexCount ?? 0
            }
            guard expandedTriangles <= 250_000, expandedVertices <= 500_000 else { throw FlowPreparationError.resourceBudget }
        }
        return prepared
    }

    func install(_ prepared: PreparedFlows, entities: [String: Entity], labelParent: Entity? = nil) {
        for id in live.keys where prepared.byNodeID[id] == nil {
            removeVisuals(from: live.removeValue(forKey: id)!)
        }
        for (id, value) in prepared.byNodeID {
            guard let root = entities[id] else { continue }
            let flow: LiveFlow
            if let existing = live[id], existing.root === root { flow = existing }
            else {
                if let old = live[id] { removeVisuals(from: old) }
                flow = LiveFlow(root: root, prepared: value)
                live[id] = flow
            }
            let changed = flow.body == nil || flow.prepared.shape !== value.shape || flow.prepared.color != value.color
                || flow.prepared.recipe.label != value.recipe.label
            flow.prepared = value
            if changed {
                removeVisuals(from: flow)
                if let mesh = value.shape.mesh {
                    let body = ModelEntity(mesh: mesh.resource, materials: [Self.material(value.color)])
                    body.name = "astra.flow.body"
                    root.addChild(body)
                    flow.body = body
                    root.components.set(CollisionComponent(shapes: value.shape.selectionShapes))
                    if let marker = prepared.marker {
                        for _ in 0..<4 {
                            let entity = ModelEntity(mesh: marker.resource, materials: [UnlitMaterial(color: .white)])
                            entity.name = "astra.flow.marker"
                            entity.scale = SIMD3(repeating: Float(value.recipe.width * 0.7))
                            root.addChild(entity)
                            flow.markers.append(entity)
                        }
                    }
                    if let mesh = value.label {
                        let anchor = Entity()
                        anchor.name = "astra.flow.label"
                        anchor.position = value.labelPosition
                        anchor.components.set(BillboardComponent())
                        let label = ModelEntity(mesh: mesh.resource, materials: [UnlitMaterial(color: .white)])
                        label.name = "astra.flow.label.text"
                        label.position = -mesh.resource.bounds.center
                        anchor.scale = SIMD3(repeating: Self.labelScale)
                        if let backing = prepared.labelBackground {
                            let background = ModelEntity(mesh: backing.resource,
                                materials: [UnlitMaterial(color: FlowColor(white: 0.035, alpha: 1))])
                            background.name = "astra.flow.label.background"
                            background.scale = [mesh.resource.bounds.extents.x + Self.labelHorizontalPadding * 2,
                                mesh.resource.bounds.extents.y + Self.labelVerticalPadding * 2, 1]
                            background.position.z = -0.04
                            anchor.addChild(background)
                        }
                        anchor.addChild(label)
                        (labelParent ?? root).addChild(anchor)
                        flow.label = anchor
                    }
                }
            }
            flow.label?.position = value.labelPosition
            flow.label?.isEnabled = Self.isVisible(root)
            updateMarkers(flow, deltaTime: 0)
        }
        shapes = prepared.shapes
        labels = prepared.labels
        marker = prepared.marker
        labelBackground = prepared.labelBackground
    }

    func setAnimationEnabled(_ enabled: Bool) {
        guard animationEnabled != enabled else { return }
        animationEnabled = enabled
        for flow in live.values { updateMarkers(flow, deltaTime: 0) }
    }

    func update(deltaTime: TimeInterval) {
        let elapsed = deltaTime.isFinite ? min(max(deltaTime, 0), 0.1) : 0
        guard metricsEnabled else {
            if animationEnabled {
                for flow in live.values where Self.isVisible(flow.root) { updateMarkers(flow, deltaTime: elapsed) }
            }
            return
        }
        let start = ContinuousClock.now
        for flow in live.values where Self.isVisible(flow.root) {
            updateMarkers(flow, deltaTime: elapsed)
        }
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        updateDurations[sampleIndex] = milliseconds
        intervals[sampleIndex] = deltaTime.isFinite && deltaTime >= 0 ? deltaTime * 1_000 : 0
        sampleIndex = (sampleIndex + 1) % intervals.count
        sampleCount = min(sampleCount + 1, intervals.count)
        updateCount &+= 1
    }

    func setMetricsEnabled(_ enabled: Bool) { metricsEnabled = enabled }

    func resetMetrics() {
        rebuildCount = 0
        updateCount = 0
        sampleCount = 0
        sampleIndex = 0
    }

    var metrics: FlowRenderMetrics {
        let cadence = Array(intervals.prefix(sampleCount))
        let cpu = Array(updateDurations.prefix(sampleCount))
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func p95(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            return values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)]
        }
        let meshValues = shapes.values.compactMap(\.mesh)
        return FlowRenderMetrics(flowCount: live.count, visibleFlowCount: live.values.filter { $0.body != nil && Self.isVisible($0.root) }.count,
            markerCount: live.values.reduce(0) { $0 + $1.markers.count },
            meshCount: meshValues.count + labels.count + (marker == nil ? 0 : 1) + (labelBackground == nil ? 0 : 1),
            vertexCount: meshValues.reduce(0) { $0 + $1.vertexCount } + labels.values.reduce(0) { $0 + $1.vertexCount }
                + (marker?.vertexCount ?? 0) + (labelBackground?.vertexCount ?? 0),
            triangleCount: meshValues.reduce(0) { $0 + $1.triangleCount } + labels.values.reduce(0) { $0 + $1.triangleCount }
                + (marker?.triangleCount ?? 0) + (labelBackground?.triangleCount ?? 0),
            meshRebuildCount: rebuildCount, updateCount: updateCount, sampleCount: sampleCount,
            meanFrameIntervalMs: mean(cadence), p95FrameIntervalMs: p95(cadence), meanMarkerUpdateMs: mean(cpu),
            p95MarkerUpdateMs: p95(cpu), maximumMarkerUpdateMs: cpu.max() ?? 0, animationEnabled: animationEnabled)
    }

    private func updateMarkers(_ flow: LiveFlow, deltaTime: Double) {
        let path = flow.prepared.shape.path
        let length = flow.prepared.worldLength
        let enabled = animationEnabled && flow.prepared.recipe.animated && !path.isDegenerate && length > 1e-8
        if enabled { flow.distance = (flow.distance + deltaTime * 0.12).truncatingRemainder(dividingBy: length) }
        for (index, marker) in flow.markers.enumerated() {
            marker.isEnabled = enabled
            guard enabled else { continue }
            let distance = (flow.distance + length * Double(index) / Double(flow.markers.count)).truncatingRemainder(dividingBy: length)
            let lengths = flow.prepared.worldLengths
            var low = 0
            var high = lengths.count - 1
            while low + 1 < high {
                let middle = (low + high) / 2
                if lengths[middle] <= distance { low = middle } else { high = middle }
            }
            let segmentLength = lengths[high] - lengths[low]
            let fraction = segmentLength > 0 ? (distance - lengths[low]) / segmentLength : 0
            marker.position = SIMD3<Float>(path.points[low] + (path.points[high] - path.points[low]) * fraction)
        }
    }

    private func removeVisuals(from flow: LiveFlow) {
        flow.body?.removeFromParent()
        flow.body = nil
        flow.markers.forEach { $0.removeFromParent() }
        flow.markers.removeAll(keepingCapacity: true)
        flow.label?.removeFromParent()
        flow.label = nil
        flow.root.components.remove(CollisionComponent.self)
    }

    private static func isVisible(_ entity: Entity) -> Bool {
        var cursor: Entity? = entity
        while let value = cursor {
            if !value.isEnabled { return false }
            cursor = value.parent
        }
        return true
    }

    private static func material(_ color: [Double]) -> UnlitMaterial {
        let channels = color.count == 4 ? color : [0.04, 0.62, 1, 1]
        return UnlitMaterial(color: FlowColor(red: CGFloat(MaterialCompiler.linearToSRGB(channels[0])),
            green: CGFloat(MaterialCompiler.linearToSRGB(channels[1])), blue: CGFloat(MaterialCompiler.linearToSRGB(channels[2])), alpha: 1))
    }

    private static func counted(_ mesh: MeshResource) -> FlowLabelMesh {
        var vertices = 0
        var triangles = 0
        for part in mesh.contents.models.flatMap({ $0.parts }) {
            vertices += part.positions.count
            triangles += (part.triangleIndices?.count ?? 0) / 3
        }
        return FlowLabelMesh(resource: mesh, vertexCount: vertices, triangleCount: triangles)
    }

    // Physical metres per font unit, independent of bound-node/ancestor scales.
    private static let labelScale: Float = 0.035
    private static let labelHorizontalPadding: Float = 0.4
    private static let labelVerticalPadding: Float = 0.275
}

private extension Transform3D {
    func flowMatrix(nodeID: String) throws -> simd_double4x4 {
        let scales = SIMD3<Float>(Float(scale.x), Float(scale.y), Float(scale.z))
        guard scales.isFinite, simd_reduce_min(scales) > 0 else { throw FlowPreparationError.invalidTransform(nodeID) }
        var matrix = simd_double4x4(simd_quatd(ix: rotation.x, iy: rotation.y, iz: rotation.z, r: rotation.w))
        matrix.columns.0 *= scale.x
        matrix.columns.1 *= scale.y
        matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(translation.flowVector, 1)
        guard matrix.isFinite else { throw FlowPreparationError.invalidTransform(nodeID) }
        return matrix
    }
}

private extension Vec3 {
    var flowVector: SIMD3<Double> { [x, y, z] }
}

private extension SIMD3 where Scalar: BinaryFloatingPoint {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension simd_double4x4 {
    var isFinite: Bool {
        [columns.0, columns.1, columns.2, columns.3].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
    }
}

private extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { [x, y, z] }
}
