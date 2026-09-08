import RealityKit
import SpatialCore
import Testing
import simd
@testable import SpatialApple

struct FlowPathTests {
    @Test("Straight flow samples clamp to exact endpoints and interpolate by distance")
    func straightSamples() {
        let path = FlowPath(controlPoints: [[1, 2, 3], [1, 4, 3]])
        #expect(!path.isDegenerate)
        #expect(path.length == 2)
        #expect(path.sample(at: -1).position == [1, 2, 3])
        #expect(path.sample(at: .nan).position == [1, 2, 3])
        #expect(path.sample(at: 0.5).position == [1, 2.5, 3])
        #expect(path.sample(at: .infinity).position == [1, 4, 3])
        #expect(path.sample(at: 0.5).tangent == [0, 1, 0])
    }

    @Test("Smooth samples preserve route points, exact endpoints and reversal symmetry")
    func reversibleCurve() {
        let controls: [SIMD3<Double>] = [
            [0, 0, 0], [0.4, 0.1, 0.2], [0.7, 0.5, -0.1], [1, 0.8, 0.1],
        ]
        let forward = FlowPath(controlPoints: controls)
        let reverse = FlowPath(controlPoints: controls.reversed())
        #expect(forward.points.count > controls.count)
        #expect(forward.points.count <= 128)
        #expect(forward.points.first == controls.first)
        #expect(forward.points.last == controls.last)
        #expect(controls.allSatisfy { forward.points.contains($0) })
        #expect(forward.points.count == reverse.points.count)
        #expect(abs(forward.length - reverse.length) < 1e-12)
        for (point, reversedPoint) in zip(forward.points, reverse.points.reversed()) {
            #expect(simd_distance(point, reversedPoint) < 1e-12)
        }
        for distance in [0, forward.length * 0.37, forward.length] {
            let sample = forward.sample(at: distance)
            let reversed = reverse.sample(at: reverse.length - distance)
            #expect(simd_distance(sample.position, reversed.position) < 1e-6)
            #expect(simd_dot(sample.tangent, reversed.tangent) < -0.99999)
        }
        // A corner gains actual curvature, rather than densely resampling its
        // two straight chords. The first span bows away from the control polygon.
        let chord = controls[1] - controls[0]
        #expect(forward.points.prefix(42).contains {
            simd_length(simd_cross($0 - controls[0], chord)) > 0.001
        })
    }

    @Test("Duplicate, near-duplicate, backtracking and maximum-route paths remain bounded and finite", arguments: [
        [SIMD3<Double>(0, 0, 0), [0, 0, 0], [0.3, 0, 0], [0.3, 0, 0], [0.5, 0.2, 0]],
        [[0, 0, 0], [0.2, 0, 0], [0, 0, 0], [-0.2, 0, 0]],
        [[1000, 0, 0], [1000.00000001, 0, 0], [1000.1, 0.1, 0]],
        [[-1, 0, 0], [0, 0, 0], [0, 1e-16, 0], [1, 1, 0]],
        [[-1, 0, 0], [0, 0, 0], [0, 1e-200, 0], [1, 1, 0]],
        [[-1, 0, 0], [0, 0, 0], [0, 1e-16, 0]],
        (0..<10).map { SIMD3<Double>(Double($0) * 0.2, Double($0 % 2) * 0.1, 0) },
    ])
    func robustSamples(controls: [SIMD3<Double>]) {
        let path = FlowPath(controlPoints: controls)
        #expect(!path.isDegenerate)
        #expect(path.points.count <= 128)
        #expect(path.points.first == controls.first)
        #expect(path.points.last == controls.last)
        #expect(path.cumulativeLengths.count == path.points.count)
        #expect(zip(path.cumulativeLengths, path.cumulativeLengths.dropFirst()).allSatisfy { $0 < $1 })
        for point in path.points {
            #expect(point.x.isFinite && point.y.isFinite && point.z.isFinite)
        }
        for index in 0...100 {
            let sample = path.sample(at: path.length * Double(index) / 100)
            #expect(sample.position.x.isFinite && sample.position.y.isFinite && sample.position.z.isFinite)
            #expect(sample.tangent.x.isFinite && sample.tangent.y.isFinite && sample.tangent.z.isFinite)
            #expect(abs(simd_length(sample.tangent) - 1) < 0.00001)
        }
    }

    @Test("Coincident endpoints suppress even a routed loop, and invalid coordinates are inert", arguments: [
        [SIMD3<Double>](),
        [SIMD3<Double>(1, 2, 3)],
        [[0, 0, 0], [0.5, 0.5, 0], [0, 0, 0]],
        [[0, 0, 0], [.nan, 0, 0], [1, 0, 0]],
        [[0, 0, 0], [.infinity, 0, 0]],
    ])
    func degenerateSamples(controls: [SIMD3<Double>]) {
        let path = FlowPath(controlPoints: controls)
        #expect(path.isDegenerate)
        #expect(path.points.isEmpty)
        #expect(path.cumulativeLengths.isEmpty)
        #expect(path.length == 0)
        #expect(path.sample(at: 5).position == .zero)
        #expect(path.sample(at: 5).tangent == [0, 1, 0])
    }
}

@MainActor
struct FlowMeshTests {
    @Test("Compiled flow triangles face outward for straight, curved, downward and reversed paths", arguments: [
        [SIMD3<Double>(0, 0, 0), [0.5, 0, 0]],
        [[0, 0, 0], [0.3, 0.1, 0.1], [0.6, 0.4, 0.2]],
        [[0, 0.5, 0], [0, 0, 0]],
        [[0.6, 0.4, 0.2], [0.3, 0.1, 0.1], [0, 0, 0]],
    ])
    func outwardWinding(controls: [SIMD3<Double>]) throws {
        let mesh = try compileFlowMesh(path: FlowPath(controlPoints: controls), width: 0.006)
        var outwardTriangles = 0
        var inwardTriangles = 0
        var vertices = 0
        var triangles = 0
        for part in mesh.resource.contents.models.flatMap({ $0.parts }) {
            let positions = Array(part.positions)
            let normals = Array(try #require(part.normals))
            let indices = Array(try #require(part.triangleIndices))
            vertices += positions.count
            triangles += indices.count / 3
            for index in stride(from: 0, to: indices.count, by: 3) {
                let a = Int(indices[index])
                let b = Int(indices[index + 1])
                let c = Int(indices[index + 2])
                let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                guard simd_length_squared(face) > 1e-16 else { continue }
                if simd_dot(face, normals[a] + normals[b] + normals[c]) > 0 {
                    outwardTriangles += 1
                } else {
                    inwardTriangles += 1
                }
            }
        }
        #expect(outwardTriangles > 0)
        #expect(inwardTriangles == 0)
        #expect(mesh.vertexCount == vertices)
        #expect(mesh.triangleCount == triangles)
        #expect(vertices <= 128 * 8 + 28)
        #expect(triangles <= 127 * 16 + 24)
    }

    @Test("A flow cone points to its endpoint without a blunt shaft ring", arguments: [
        [SIMD3<Double>(0, 0, 0), [0.5, 0.4, 0.3]],
        [[0.5, 0.4, 0.3], [0, 0, 0]],
        [[0, 0.5, 0], [0, 0, 0]],
        [[0, 0, 0], [0.4, 0.2, 0.1], [0.7, 0.7, 0.2]],
    ])
    func exactPointedTip(controls: [SIMD3<Double>]) throws {
        let path = FlowPath(controlPoints: controls)
        let mesh = try compileFlowMesh(path: path, width: 0.01)
        let endpoint = path.sample(at: path.length).position
        let tangent = path.sample(at: path.length).tangent
        let positions = mesh.resource.contents.models.flatMap { $0.parts.flatMap { Array($0.positions) } }
        let furthest = try #require(positions.map { simd_dot($0 - endpoint, tangent) }.max())
        #expect(abs(furthest) < 1e-6)
        let terminalVertices = positions.filter { simd_dot($0 - endpoint, tangent) > -1e-6 }
        #expect(!terminalVertices.isEmpty)
        #expect(terminalVertices.allSatisfy { simd_distance($0, endpoint) < 1e-6 })
    }

    @Test("Backtracking and near-coincident controls compile to finite mesh buffers", arguments: [
        [SIMD3<Double>(0, 0, 0), [0.2, 0, 0], [0, 0, 0], [-0.2, 0, 0]],
        [[0, 0, 0], [0, 0, 0], [0.2, 0.1, 0]],
        [[1000, 0, 0], [1000.00000001, 0, 0], [1000.1, 0.1, 0]],
        [[0, 0, 0], [0.000001, 0, 0]],
    ])
    func finiteBuffers(controls: [SIMD3<Double>]) throws {
        let mesh = try compileFlowMesh(path: FlowPath(controlPoints: controls), width: 0.01)
        for part in mesh.resource.contents.models.flatMap({ $0.parts }) {
            for position in part.positions {
                #expect(position.x.isFinite && position.y.isFinite && position.z.isFinite)
            }
            for normal in try #require(part.normals) {
                #expect(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
                #expect(abs(simd_length(normal) - 1) < 0.0001)
            }
        }
    }

    @Test("A degenerate flow never asks RealityKit to generate an empty resource")
    func rejectsEmptyMesh() {
        #expect(throws: GeometryCompiler.CompilationError.self) {
            try compileFlowMesh(path: FlowPath(controlPoints: [[0, 0, 0], [0, 0, 0]]), width: 0.01)
        }
    }

    @Test("A short terminal turn does not pull the shaft away from its route")
    func shortTerminalTurn() throws {
        let path = FlowPath(controlPoints: [[0, 0, 0], [1, 0.01, 0], [1, 0, 0]])
        let width = 0.1
        let mesh = try compileFlowMesh(path: path, width: width)
        let highestRoutePoint = try #require(path.points.map(\.y).max())
        let positions = mesh.resource.contents.models.flatMap { $0.parts.flatMap { Array($0.positions) } }
        let highestVertex = try #require(positions.map(\.y).max())
        #expect(Double(highestVertex) <= highestRoutePoint + width)
    }

    @Test("Ordinary geometry compilation reports that flows require scene bindings")
    func rejectsUnboundFlow() throws {
        let recipe = GeometryRecipe.flow(FlowRecipe(
            source: FlowAttachment(nodeId: "source", localPoint: Vec3(0, 0, 0)),
            target: FlowAttachment(nodeId: "target", localPoint: Vec3(0, 0, 0))
        ))
        let definition = GeometryDefinition(
            geometryId: "bound-flow", contentHash: try canonicalContentHash(for: recipe), recipe: recipe
        )
        do {
            _ = try GeometryCompiler().resource(for: definition)
            Issue.record("An unbound flow unexpectedly compiled as ordinary geometry")
        } catch GeometryCompiler.CompilationError.sceneBindingRequired(let id) {
            #expect(id == definition.geometryId)
        }
    }
}
