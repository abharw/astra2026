import Foundation
import RealityKit
import SpatialCore

#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformColor = UIColor
#endif

@MainActor
final class MaterialCompiler {
    private var materials: [String: PhysicallyBasedMaterial] = [:]

    func resource(for definition: SpatialCore.Material) -> PhysicallyBasedMaterial {
        let linearColor = paddedColor(definition.baseColorLinear)
        let displayColor = [
            Self.linearToSRGB(linearColor[0]),
            Self.linearToSRGB(linearColor[1]),
            Self.linearToSRGB(linearColor[2]),
            min(max(linearColor[3], 0), 1),
        ]
        let colorKey = linearColor.map { String($0) }.joined(separator: ",")
        let key = "\(definition.materialId):\(colorKey):\(definition.metallic):\(definition.roughness)"
        if let cached = materials[key] {
            return cached
        }

        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: PlatformColor(
            red: CGFloat(displayColor[0]),
            green: CGFloat(displayColor[1]),
            blue: CGFloat(displayColor[2]),
            alpha: CGFloat(displayColor[3])
        ))
        material.metallic = .init(floatLiteral: Float(definition.metallic))
        material.roughness = .init(floatLiteral: Float(definition.roughness))
        materials[key] = material
        return material
    }

    func prune(keeping definitions: [SpatialCore.Material]) {
        let retainedIDs = Set(definitions.map(\.materialId))
        materials = materials.filter { entry in
            retainedIDs.contains { entry.key.hasPrefix("\($0):") }
        }
    }

    private func paddedColor(_ components: [Double]) -> [Double] {
        guard components.count >= 3 else { return [0.7, 0.7, 0.72, 1] }
        return [
            components[0],
            components[1],
            components[2],
            components.count > 3 ? components[3] : 1,
        ]
    }

    static func linearToSRGB(_ component: Double) -> Double {
        let linear = min(max(component, 0), 1)
        guard linear < 1 else { return 1 }
        if linear <= 0.003_130_8 {
            return linear * 12.92
        }
        return 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}
