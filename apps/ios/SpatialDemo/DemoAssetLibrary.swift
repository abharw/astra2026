import Foundation
import SpatialApple

/// Application-owned asset choices. The SDK receives ordinary approved resources
/// and arbitrary hierarchy templates; it has no knowledge of the rack example.
enum DemoAssetLibrary {
    static func descriptor(named name: String) throws -> ImportedAssetDescriptor {
        var descriptor: ImportedAssetDescriptor = try decode(name)
        if descriptor.sourceURL.scheme == "bundle" {
            let resource = descriptor.sourceURL.deletingPathExtension().lastPathComponent
            guard let file = Bundle.main.url(forResource: resource, withExtension: "usdz") else {
                throw ImportedAssetError.invalidDescriptor("the approved asset is not bundled")
            }
            descriptor.sourceURL = file
        }
        return descriptor
    }

    static func registerDetails(on controller: SceneController) throws {
        let templates: [ImportedAssetDetailTemplate] = try decode("detail-templates")
        try controller.registerAssetDetails(templates, resources: [descriptor(named: "detail-catalog")])
    }

    private static func decode<T: Decodable>(_ name: String) throws -> T {
        guard let file = Bundle.main.url(forResource: name, withExtension: "json") else {
            throw ImportedAssetError.invalidDescriptor("the approved \(name) catalog is not bundled")
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
}
