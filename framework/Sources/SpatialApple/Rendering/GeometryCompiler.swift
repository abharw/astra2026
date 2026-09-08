import Foundation
import RealityKit
import SpatialCore
import simd

@MainActor
public final class GeometryCompiler {
    public enum CompilationError: LocalizedError {
        case emptyMesh(String)
        case sceneBindingRequired(String)
        case invalidFlowWidth

        public var errorDescription: String? {
            switch self {
            case let .emptyMesh(geometryID):
                "Geometry \(geometryID) produced no triangles."
            case let .sceneBindingRequired(geometryID):
                "Flow geometry \(geometryID) requires resolved scene endpoint bindings."
            case .invalidFlowWidth:
                "Flow shaft width must be finite and positive."
            }
        }
    }

    private var meshes: [String: MeshResource] = [:]

    public init() {}

    public func resource(for definition: GeometryDefinition) throws -> MeshResource {
        let key = "\(definition.geometryId):\(definition.contentHash)"
        if let cached = meshes[key] {
            return cached
        }

        let resource: MeshResource
        switch definition.recipe {
        case .flow:
            throw CompilationError.sceneBindingRequired(definition.geometryId)
        case let .importedAsset(assetID, partID):
            throw ImportedAssetError.unknownReference("\(assetID)/\(partID) requires an approved entity prototype")
        case let .box(size):
            resource = .generateBox(size: size.simdFloat)
        case let .sphere(radius, segments):
            resource = try generate(
                sphere(radius: Float(radius), segments: segments),
                name: definition.geometryId
            )
        case let .cylinder(radius, height, radialSegments):
            resource = try generate(
                frustum(
                    bottomRadius: Float(radius),
                    topRadius: Float(radius),
                    height: Float(height),
                    segments: radialSegments
                ),
                name: definition.geometryId
            )
        case let .cone(bottomRadius, topRadius, height, radialSegments):
            resource = try generate(
                frustum(
                    bottomRadius: Float(bottomRadius),
                    topRadius: Float(topRadius),
                    height: Float(height),
                    segments: radialSegments
                ),
                name: definition.geometryId
            )
        case let .tube(points, radius, radialSegments):
            resource = try generate(
                tube(points: points.map(\.simdDouble), radius: Float(radius), segments: radialSegments),
                name: definition.geometryId
            )
        case let .arrow(start, end, shaftRadius, headRadius, headLength, radialSegments):
            resource = try generate(
                arrow(
                    start: start.simdFloat,
                    end: end.simdFloat,
                    shaftRadius: Float(shaftRadius),
                    headRadius: Float(headRadius),
                    headLength: Float(headLength),
                    segments: radialSegments
                ),
                name: definition.geometryId
            )
        }
        meshes[key] = resource
        return resource
    }

    public func prune(keeping definitions: [GeometryDefinition]) {
        let retained = Set(definitions.map { "\($0.geometryId):\($0.contentHash)" })
        meshes = meshes.filter { retained.contains($0.key) }
    }
}

struct FlowMesh {
    let resource: MeshResource
    let vertexCount: Int
    let triangleCount: Int
}

@MainActor
func compileFlowMesh(path: FlowPath, width: Double) throws -> FlowMesh {
    guard width.isFinite, width > 0, Float(width).isFinite else {
        throw GeometryCompiler.CompilationError.invalidFlowWidth
    }
    guard !path.isDegenerate, let endpoint = path.points.last else {
        throw GeometryCompiler.CompilationError.emptyMesh("flow")
    }

    let terminalTangent = path.sample(at: path.length).tangent
    var terminalRun = 0.0
    for index in (0..<(path.points.count - 1)).reversed() {
        let direction = simd_normalize(path.points[index + 1] - path.points[index])
        // Keep the cone within the final low-curvature run. A long path ending
        // in a tiny turn must not pull its shaft far outside the authored route.
        guard simd_dot(direction, SIMD3<Double>(terminalTangent)) >= 0.94 else { break }
        terminalRun += path.cumulativeLengths[index + 1] - path.cumulativeLengths[index]
    }
    let headLength = min(width * 3, path.length * 0.35, terminalRun * 0.8)
    let base = endpoint - SIMD3<Double>(terminalTangent) * headLength
    let shaftEndDistance = path.length - headLength
    var shaftPoints = zip(path.points, path.cumulativeLengths)
        .prefix { $0.1 < shaftEndDistance }
        .map(\.0)
    if shaftPoints.last != base { shaftPoints.append(base) }

    var mesh = MeshData()
    if shaftPoints.count >= 2 {
        mesh.append(tube(points: shaftPoints, radius: Float(width / 2), segments: 8, endTangent: terminalTangent))
    }
    // Local +Y points at the semantic endpoint. The shaft stops at the cone
    // base, avoiding the blunt terminal ring left by a full-length tube.
    var headTransform = simd_float4x4(simd_quatf(from: SIMD3<Float>(0, 1, 0), to: terminalTangent))
    headTransform.columns.3 = SIMD4(SIMD3<Float>(endpoint) - terminalTangent * Float(headLength / 2), 1)
    mesh.append(
        frustum(
            bottomRadius: Float(max(width / 2, min(width, headLength / 2))),
            topRadius: 0,
            height: Float(headLength),
            segments: 8
        ),
        transform: headTransform
    )
    return FlowMesh(
        resource: try generate(mesh, name: "flow"),
        vertexCount: mesh.positions.count,
        triangleCount: mesh.indices.count / 3
    )
}

@MainActor
private func generate(_ data: MeshData, name: String) throws -> MeshResource {
    guard !data.positions.isEmpty, !data.indices.isEmpty else {
        throw GeometryCompiler.CompilationError.emptyMesh(name)
    }
    var descriptor = MeshDescriptor(name: name)
    descriptor.positions = MeshBuffers.Positions(data.positions)
    descriptor.normals = MeshBuffers.Normals(data.normals)
    descriptor.primitives = .triangles(data.indices)
    return try MeshResource.generate(from: [descriptor])
}

private struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    mutating func append(_ other: MeshData, transform: simd_float4x4 = matrix_identity_float4x4) {
        let offset = UInt32(positions.count)
        let normalMatrix = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        positions.append(contentsOf: other.positions.map {
            let transformed = transform * SIMD4($0, 1)
            return SIMD3(transformed.x, transformed.y, transformed.z)
        })
        normals.append(contentsOf: other.normals.map { simd_normalize(normalMatrix * $0) })
        indices.append(contentsOf: other.indices.map { $0 + offset })
    }
}

private func sphere(radius: Float, segments: Int) -> MeshData {
    let longitudeCount = max(3, segments)
    let latitudeCount = max(2, segments / 2)
    var mesh = MeshData()

    for latitude in 0...latitudeCount {
        let v = Float(latitude) / Float(latitudeCount)
        let phi = Float.pi * v
        for longitude in 0...longitudeCount {
            let u = Float(longitude) / Float(longitudeCount)
            let theta = 2 * Float.pi * u
            let normal = SIMD3<Float>(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            mesh.positions.append(normal * radius)
            mesh.normals.append(normal)
        }
    }

    let stride = longitudeCount + 1
    for latitude in 0..<latitudeCount {
        for longitude in 0..<longitudeCount {
            let a = UInt32(latitude * stride + longitude)
            let b = UInt32((latitude + 1) * stride + longitude)
            mesh.indices += [a, a + 1, b, a + 1, b + 1, b]
        }
    }
    return mesh
}

private func frustum(bottomRadius: Float, topRadius: Float, height: Float, segments: Int) -> MeshData {
    let count = max(3, segments)
    let halfHeight = height / 2
    let slope = (bottomRadius - topRadius) / height
    var mesh = MeshData()

    for index in 0...count {
        let angle = 2 * Float.pi * Float(index) / Float(count)
        let radial = SIMD3<Float>(cos(angle), 0, sin(angle))
        let normal = simd_normalize(SIMD3(radial.x, slope, radial.z))
        mesh.positions += [radial * bottomRadius + [0, -halfHeight, 0], radial * topRadius + [0, halfHeight, 0]]
        mesh.normals += [normal, normal]
    }
    for index in 0..<count {
        let bottom = UInt32(index * 2)
        let top = bottom + 1
        mesh.indices += [bottom, top, top + 2, bottom, top + 2, bottom + 2]
    }

    if bottomRadius > 0 {
        appendCap(to: &mesh, radius: bottomRadius, y: -halfHeight, segments: count, upward: false)
    }
    if topRadius > 0 {
        appendCap(to: &mesh, radius: topRadius, y: halfHeight, segments: count, upward: true)
    }
    return mesh
}

private func appendCap(to mesh: inout MeshData, radius: Float, y: Float, segments: Int, upward: Bool) {
    let center = UInt32(mesh.positions.count)
    let normal = SIMD3<Float>(0, upward ? 1 : -1, 0)
    mesh.positions.append([0, y, 0])
    mesh.normals.append(normal)
    for index in 0...segments {
        let angle = 2 * Float.pi * Float(index) / Float(segments)
        mesh.positions.append([cos(angle) * radius, y, sin(angle) * radius])
        mesh.normals.append(normal)
    }
    for index in 0..<segments {
        let current = center + 1 + UInt32(index)
        let next = current + 1
        mesh.indices += upward ? [center, next, current] : [center, current, next]
    }
}

private func tube(points: [SIMD3<Double>], radius: Float, segments: Int, endTangent: SIMD3<Float>? = nil) -> MeshData {
    let count = max(3, segments)
    // Derive directions before converting positions to Float: distinct validated
    // points can otherwise round to the same native position.
    let directions = zip(points, points.dropFirst()).map { start, end in
        let delta = end - start
        let magnitude = simd_reduce_max(simd_abs(delta))
        return magnitude > 0 ? SIMD3<Float>(simd_normalize(delta / magnitude)) : SIMD3<Float>(1, 0, 0)
    }
    var previousTangent = directions[0]
    let reference: SIMD3<Float> = abs(previousTangent.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
    var basisX = simd_normalize(simd_cross(reference, previousTangent))
    var mesh = MeshData()

    for pointIndex in points.indices {
        let tangent: SIMD3<Float>
        if pointIndex == points.startIndex {
            tangent = directions[0]
        } else if pointIndex == points.index(before: points.endIndex) {
            tangent = endTangent ?? directions[pointIndex - 1]
        } else {
            let bisector = directions[pointIndex - 1] + directions[pointIndex]
            // A path may double back. Its cusp has no unique tangent; retain the
            // incoming direction rather than normalizing a zero vector.
            tangent = simd_length_squared(bisector) > 1e-8
                ? simd_normalize(bisector) : directions[pointIndex - 1]
        }
        if pointIndex > 0 {
            // Transport the frame instead of choosing a new reference axis for
            // each ring. At a reversal, rotate around basisX (which stays fixed).
            let transported = simd_dot(previousTangent, tangent) > -0.9999
                ? simd_quatf(from: previousTangent, to: tangent).act(basisX) : basisX
            basisX = simd_normalize(transported - tangent * simd_dot(transported, tangent))
        }
        let basisY = simd_normalize(simd_cross(tangent, basisX))
        previousTangent = tangent

        for ringIndex in 0..<count {
            let angle = 2 * Float.pi * Float(ringIndex) / Float(count)
            let normal = basisX * cos(angle) + basisY * sin(angle)
            mesh.positions.append(SIMD3<Float>(points[pointIndex]) + normal * radius)
            mesh.normals.append(normal)
        }
    }

    for pointIndex in 0..<(points.count - 1) {
        for ringIndex in 0..<count {
            let nextRing = (ringIndex + 1) % count
            let a = UInt32(pointIndex * count + ringIndex)
            let b = UInt32((pointIndex + 1) * count + ringIndex)
            let c = UInt32((pointIndex + 1) * count + nextRing)
            let d = UInt32(pointIndex * count + nextRing)
            mesh.indices += [a, c, b, a, d, c]
        }
    }
    return mesh
}

private func arrow(
    start: SIMD3<Float>,
    end: SIMD3<Float>,
    shaftRadius: Float,
    headRadius: Float,
    headLength: Float,
    segments: Int
) -> MeshData {
    let vector = end - start
    let length = simd_length(vector)
    let shaftLength = max(0, length - headLength)
    let midpoint = (start + end) / 2
    let rotation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(vector))
    var transform = simd_float4x4(rotation)
    transform.columns.3 = SIMD4(midpoint, 1)

    var local = MeshData()
    if shaftLength > 0 {
        var shaftTransform = matrix_identity_float4x4
        shaftTransform.columns.3.y = -headLength / 2
        local.append(
            frustum(bottomRadius: shaftRadius, topRadius: shaftRadius, height: shaftLength, segments: segments),
            transform: shaftTransform
        )
    }
    var headTransform = matrix_identity_float4x4
    headTransform.columns.3.y = shaftLength / 2
    local.append(
        frustum(bottomRadius: headRadius, topRadius: 0, height: headLength, segments: segments),
        transform: headTransform
    )

    var result = MeshData()
    result.append(local, transform: transform)
    return result
}

private extension Vec3 {
    var simdDouble: SIMD3<Double> {
        SIMD3(x, y, z)
    }

    var simdFloat: SIMD3<Float> {
        SIMD3(Float(x), Float(y), Float(z))
    }
}
