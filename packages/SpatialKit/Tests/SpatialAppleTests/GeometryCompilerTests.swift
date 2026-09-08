import RealityKit
import SpatialApple
import SpatialCore
import Testing
import simd

@MainActor
struct GeometryCompilerTests {
    @Test("Primitive triangles face the same direction as their vertex normals", arguments: [
        GeometryRecipe.box(size: Vec3(0.2, 0.1, 0.3)),
        .sphere(radius: 0.1, segments: 16),
        .cylinder(radius: 0.08, height: 0.2, radialSegments: 16),
        .cone(bottomRadius: 0.1, topRadius: 0.025, height: 0.2, radialSegments: 16),
        .cone(bottomRadius: 0.1, topRadius: 0, height: 0.2, radialSegments: 16),
        .cone(bottomRadius: 0, topRadius: 0.1, height: 0.2, radialSegments: 16),
        .tube(points: [Vec3(0, 0, 0), Vec3(0.2, 0, 0)], radius: 0.01, radialSegments: 12),
        .tube(points: [Vec3(0, 0, 0), Vec3(0.1, 0.05, 0), Vec3(0.2, 0.05, 0.1)], radius: 0.01, radialSegments: 12),
        .arrow(start: Vec3(0, 0, 0), end: Vec3(0.2, 0.15, 0.1), shaftRadius: 0.01, headRadius: 0.025, headLength: 0.06, radialSegments: 12),
        .arrow(start: Vec3(0, 0.2, 0), end: Vec3(0, 0, 0), shaftRadius: 0.01, headRadius: 0.025, headLength: 0.2, radialSegments: 12),
    ])
    func outwardWinding(recipe: GeometryRecipe) throws {
        let mesh = try compiledMesh(recipe)
        var outwardTriangles = 0
        var inwardTriangles = 0
        for part in mesh.contents.models.flatMap({ $0.parts }) {
            let positions = Array(part.positions)
            let normals = Array(try #require(part.normals))
            let indices = Array(try #require(part.triangleIndices))
            for index in stride(from: 0, to: indices.count, by: 3) {
                let a = Int(indices[index])
                let b = Int(indices[index + 1])
                let c = Int(indices[index + 2])
                let faceNormal = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
                // Sphere poles and cone tips intentionally share coincident positions.
                guard simd_length_squared(faceNormal) > 1e-16 else { continue }
                let alignment = simd_dot(faceNormal, normals[a] + normals[b] + normals[c])
                if alignment > 0 { outwardTriangles += 1 } else { inwardTriangles += 1 }
            }
        }
        #expect(outwardTriangles > 0)
        #expect(inwardTriangles == 0)
    }

    @Test("Valid backtracking and close-point tubes have finite vertices and normals", arguments: [
        [Vec3(0, 0, 0), Vec3(0.1, 0, 0), Vec3(0, 0, 0)],
        [Vec3(0, 0, 0), Vec3(0, 0.1, 0), Vec3(0, 0, 0), Vec3(0, -0.1, 0)],
        [Vec3(1000, 0, 0), Vec3(1000.00000001, 0, 0), Vec3(1000.1, 0, 0)],
    ])
    func backtrackingTubeIsFinite(points: [Vec3]) throws {
        let mesh = try compiledMesh(.tube(points: points, radius: 0.01, radialSegments: 12))
        for part in mesh.contents.models.flatMap({ $0.parts }) {
            for position in part.positions {
                #expect(position.x.isFinite && position.y.isFinite && position.z.isFinite)
            }
            for normal in try #require(part.normals) {
                #expect(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite)
                #expect(abs(simd_length(normal) - 1) < 0.0001)
            }
        }
    }

    @Test("A curved tube transports its frame across the old reference-axis threshold")
    func tubeFrameContinuity() throws {
        let directions = [0.895, 0.899, 0.903, 0.907].map { y in
            SIMD3<Float>(Float(sqrt(1 - y * y)), Float(y), 0)
        }
        var points: [SIMD3<Float>] = [.zero]
        for direction in directions { points.append(points[points.count - 1] + direction * 0.1) }
        let recipe = GeometryRecipe.tube(
            points: points.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) },
            radius: 0.01, radialSegments: 12
        )
        let mesh = try compiledMesh(recipe)
        let part = try #require(mesh.contents.models.flatMap({ $0.parts }).first)
        let normals = Array(try #require(part.normals))
        #expect(normals.count == points.count * 12)
        for ring in 1..<points.count {
            for index in 0..<12 {
                #expect(simd_dot(normals[(ring - 1) * 12 + index], normals[ring * 12 + index]) > 0.99)
            }
        }
    }

    private func compiledMesh(_ recipe: GeometryRecipe) throws -> MeshResource {
        let definition = GeometryDefinition(
            geometryId: "primitive",
            contentHash: try canonicalContentHash(for: recipe, geometrySemanticsVersion: 1),
            recipe: recipe
        )
        try SceneValidator().validate(SceneDocument(documentId: "primitive_fixture", geometryDefinitions: [definition]))
        return try GeometryCompiler().resource(for: definition)
    }
}
