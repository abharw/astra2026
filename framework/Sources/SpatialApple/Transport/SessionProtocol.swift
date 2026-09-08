import Foundation
import SpatialCore

struct SessionHello: Encodable {
    let type = "session.hello"
    let protocolVersion = 1
    var sessionId: String
    var sceneId: String
    var revision: UInt64
    var intentEpoch: UInt64
    let sceneSchemaVersions = [1]
    let geometrySemanticsVersions = [1]
    // Illustration delivery is independent of the editable geometry contract.
    let capabilities = SceneCapability.allCases.map(\.rawValue) + ["illustration.v1"]
    var authToken: String?
}

struct PhoneSnapshot: Encodable {
    let type = "phone.snapshot"
    var sceneId: String
    var revision: UInt64
    var intentEpoch: UInt64
    var document: SceneDocument
    var availableAssetDetails: [AvailableAssetDetail]? = nil
    var nodeLocalBounds: [NodeLocalBounds]? = nil
}

struct UserRequest: Encodable {
    struct Selection: Encodable { var nodeIds: [String] }

    let type = "user.request"
    var requestId: String
    var text: String
    var selection: Selection?
}

struct IntentControl: Encodable {
    var type: String
    var requestId: String
    var sceneId: String
    var intentEpoch: UInt64
}

struct IncomingHeader: Decodable {
    var type: String
}

struct SessionAccepted: Decodable {
    var protocolVersion: Int
    var sessionId: String
    var sceneSchemaVersion: Int
    var geometrySemanticsVersion: Int
    var illustrationEnabled: Bool?
}

struct SessionExplanation: Decodable {
    var requestId: String
    var proposalRequestIds: [String]
    var intentEpoch: UInt64
    var text: String
}

struct SessionProgress: Decodable {
    var requestId: String
    var status: String
    var intentEpoch: UInt64
}

struct SessionErrorMessage: Decodable {
    var requestId: String?
    var code: String
    var message: String
}
