import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import SpatialApple
import SpatialCore
import Synchronization
import Testing
import UniformTypeIdentifiers

private final class ArtifactURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        var body: Data
        var status = 200
        var mimeType = "image/png"
        var redirect: URL?
        var stall = false
        var requests: [URLRequest] = []
        var stopped = false
    }

    static let fixtures = Mutex<[String: Fixture]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let fixture = Self.fixtures.withLock { fixtures -> Fixture? in
            guard var fixture = fixtures[host] else { return nil }
            fixture.requests.append(request)
            fixtures[host] = fixture
            return fixture
        }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if fixture.stall { return }
        let response = HTTPURLResponse(url: url, statusCode: fixture.redirect == nil ? fixture.status : 302,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fixture.mimeType])!
        if let redirect = fixture.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Multiple chunks exercise the cumulative bound independent of Content-Length.
        let split = fixture.body.count / 2
        client?.urlProtocol(self, didLoad: fixture.body.prefix(split))
        client?.urlProtocol(self, didLoad: fixture.body.suffix(from: split))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.fixtures.withLock { $0[host]?.stopped = true }
    }
}

private func illustrationPNG(width: Int = 2, height: Int = 2, red: CGFloat = 0.25) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: red, green: 0.5, blue: 0.75, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let result = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return result as Data
}

private func illustrationMetadata(_ bytes: Data, width: Int = 2, height: Int = 2,
                                  path: String? = nil, hash: String? = nil, byteCount: Int? = nil,
                                  model: String = "gpt-image-2.5-flare", createdAt: String = "2026-09-08T12:00:00Z",
                                  sourceArtifactId: String? = nil) -> IllustrationArtifact {
    let digest = hash ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return IllustrationArtifact(artifactId: "sha256:\(digest)", sha256: digest, mimeType: "image/png",
        width: width, height: height, byteCount: byteCount ?? bytes.count, model: model,
        sourceRevision: 4, path: path ?? "/illustrations/artifacts/\(digest).png", createdAt: createdAt,
        sourceArtifactId: sourceArtifactId)
}

private struct ArtifactTestContext {
    let host = "\(UUID().uuidString.lowercased()).example.test"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("illustration-test-\(UUID().uuidString)")

    func loader(maxBytes: Int = 32 * 1024 * 1024) -> IllustrationArtifactLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return IllustrationArtifactLoader(cacheDirectory: directory, maxBytes: maxBytes, session: session)
    }

    var serverURL: URL { URL(string: "wss://\(host):9443/session?secret=discard#discard")! }

    func set(_ fixture: ArtifactURLProtocol.Fixture) {
        ArtifactURLProtocol.fixtures.withLock { $0[host] = fixture }
    }

    var fixture: ArtifactURLProtocol.Fixture? { ArtifactURLProtocol.fixtures.withLock { $0[host] } }

    func cleanUp() {
        ArtifactURLProtocol.fixtures.withLock { _ = $0.removeValue(forKey: host) }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func illustrationArtifactUsesAuthenticatedOriginAndVerifiedDiskCache() async throws {
    let bytes = try illustrationPNG()
    let artifact = illustrationMetadata(bytes)
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes))
    let loader = context.loader()
    let url = try await loader.load(artifact, serverURL: context.serverURL, authToken: "fixture-token")
    #expect(try Data(contentsOf: url) == bytes)
    let request = try #require(context.fixture?.requests.first)
    #expect(request.url?.absoluteString == "https://\(context.host):9443\(artifact.path)")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    #expect(try await loader.load(artifact, serverURL: context.serverURL, authToken: "changed-token") == url)
    #expect(context.fixture?.requests.count == 1)

    // A corrupt cache entry must be verified and replaced instead of reaching display.
    try Data(repeating: 0, count: bytes.count).write(to: url)
    #expect(try await loader.load(artifact, serverURL: context.serverURL, authToken: nil) == url)
    #expect(context.fixture?.requests.count == 2)
    #expect(try Data(contentsOf: url) == bytes)
}

@Test(arguments: ["https://other.example/image.png", "//other.example/image.png", "/illustrations/artifacts/../secret", "/wrong.png"])
func illustrationArtifactRejectsNoncanonicalRouteBeforeNetwork(path: String) async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes))
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await context.loader().load(illustrationMetadata(bytes, path: path), serverURL: context.serverURL, authToken: "secret")
    }
    #expect(context.fixture?.requests.isEmpty == true)
}

@Test func illustrationArtifactRejectsMetadataBeforeCacheHit() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes))
    let loader = context.loader()
    _ = try await loader.load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: nil)
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, width: 2049), serverURL: context.serverURL, authToken: nil)
    }
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, model: "other-image-model"), serverURL: context.serverURL, authToken: nil)
    }
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, createdAt: "not-a-date"), serverURL: context.serverURL, authToken: nil)
    }
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, createdAt: String(repeating: "0", count: 65)),
                              serverURL: context.serverURL, authToken: nil)
    }
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, sourceArtifactId: "arbitrary-parent"),
                              serverURL: context.serverURL, authToken: nil)
    }
    await #expect(throws: IllustrationArtifactError.invalidMetadata) {
        try await loader.load(illustrationMetadata(bytes, byteCount: 12 * 1024 * 1024 + 1),
                              serverURL: context.serverURL, authToken: nil)
    }
    let sourceDigest = "sha256:" + String(repeating: "a", count: 64)
    _ = try await loader.load(illustrationMetadata(bytes, createdAt: "2026-09-08T12:00:00.123Z", sourceArtifactId: sourceDigest),
                              serverURL: context.serverURL, authToken: nil)
    #expect(context.fixture?.requests.count == 1)
}

@Test func illustrationArtifactRejectsCorruptContentAndCleansPartialFiles() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: Data(repeating: 0, count: bytes.count)))
    let loader = context.loader()
    await #expect(throws: IllustrationArtifactError.checksumMismatch) {
        try await loader.load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty)
    context.set(.init(body: bytes))
    await #expect(throws: IllustrationArtifactError.invalidImage) {
        try await loader.load(illustrationMetadata(bytes, width: 1), serverURL: context.serverURL, authToken: nil)
    }
    let fakePNG = Data(repeating: 0, count: 100)
    context.set(.init(body: fakePNG))
    await #expect(throws: IllustrationArtifactError.invalidImage) {
        try await loader.load(illustrationMetadata(fakePNG), serverURL: context.serverURL, authToken: nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty)
}

@Test func illustrationArtifactEnforcesActualByteBoundWithoutContentLength() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes + bytes))
    await #expect(throws: IllustrationArtifactError.byteCountMismatch) {
        try await context.loader().load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty)
}

@Test func illustrationArtifactRejectsRedirectsWithoutForwardingBearer() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    let destination = ArtifactTestContext()
    defer { context.cleanUp(); destination.cleanUp() }
    context.set(.init(body: bytes, redirect: destination.serverURL))
    destination.set(.init(body: bytes))
    await #expect(throws: IllustrationArtifactError.redirectRejected) {
        try await context.loader().load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: "secret")
    }
    #expect(destination.fixture?.requests.isEmpty == true)
}

@Test func illustrationArtifactCancellationStopsDownloadAndRemovesPartialFile() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes, stall: true))
    let loader = context.loader()
    let task = Task { try await loader.load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: nil) }
    for _ in 0..<100 where context.fixture?.requests.isEmpty == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(context.fixture?.requests.count == 1)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty)
}

@Test func illustrationArtifactEvictsOldestFileWithinCacheBudget() async throws {
    let firstBytes = try illustrationPNG(red: 0.1)
    let secondBytes = try illustrationPNG(red: 0.9)
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    let loader = context.loader(maxBytes: max(firstBytes.count, secondBytes.count))
    context.set(.init(body: firstBytes))
    let first = try await loader.load(illustrationMetadata(firstBytes), serverURL: context.serverURL, authToken: nil)
    context.set(.init(body: secondBytes))
    let second = try await loader.load(illustrationMetadata(secondBytes), serverURL: context.serverURL, authToken: nil)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).count == 1)
}

@Test func illustrationArtifactCacheHitRemovesInterruptedPartialsOnly() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes))
    let loader = context.loader()
    let artifact = illustrationMetadata(bytes)
    let cached = try await loader.load(artifact, serverURL: context.serverURL, authToken: nil)
    let orphan = context.directory.appendingPathComponent(".partial-\(UUID().uuidString)")
    let unrelated = context.directory.appendingPathComponent(".partial-unrelated")
    try bytes.write(to: orphan)
    try bytes.write(to: unrelated)
    #expect(try await loader.load(artifact, serverURL: context.serverURL, authToken: nil) == cached)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(context.fixture?.requests.count == 1)
}

@Test func illustrationArtifactCacheEvictionPreservesRequestedOldFile() async throws {
    let firstBytes = try illustrationPNG(red: 0.1)
    let secondBytes = try illustrationPNG(red: 0.9)
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    let loader = context.loader()
    context.set(.init(body: firstBytes))
    let firstArtifact = illustrationMetadata(firstBytes)
    let first = try await loader.load(firstArtifact, serverURL: context.serverURL, authToken: nil)
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: first.path)
    context.set(.init(body: secondBytes))
    let second = try await loader.load(illustrationMetadata(secondBytes), serverURL: context.serverURL, authToken: nil)
    let smallerCache = context.loader(maxBytes: max(firstBytes.count, secondBytes.count))
    #expect(try await smallerCache.load(firstArtifact, serverURL: context.serverURL, authToken: nil) == first)
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(context.fixture?.requests.count == 1)
}

@Test func illustrationArtifactConcurrentCacheCleanupPreservesActiveTransfer() async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    let second = ArtifactTestContext()
    defer { context.cleanUp(); second.cleanUp() }
    context.set(.init(body: bytes, stall: true))
    let loader = context.loader()
    let firstTask = Task { try await loader.load(illustrationMetadata(bytes), serverURL: context.serverURL, authToken: nil) }
    defer { firstTask.cancel() }
    for _ in 0..<100 where context.fixture?.requests.isEmpty == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(context.fixture?.requests.count == 1)
    let active = try #require(FileManager.default.contentsOfDirectory(at: context.directory,
        includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".partial-") })
    let secondBytes = try illustrationPNG(red: 0.9)
    second.set(.init(body: secondBytes))
    let cached = try await loader.load(illustrationMetadata(secondBytes), serverURL: second.serverURL, authToken: nil)
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: cached.path))
    firstTask.cancel()
    await #expect(throws: CancellationError.self) { try await firstTask.value }
    #expect(!FileManager.default.fileExists(atPath: active.path))
}

@MainActor
@Test(arguments: ["stop", "retire", "stale"])
func illustrationArtifactPendingTransferCannotReattachAfterRetirement(action: String) async throws {
    let bytes = try illustrationPNG()
    let context = ArtifactTestContext()
    defer { context.cleanUp() }
    context.set(.init(body: bytes, stall: true))
    let images = IllustrationSession(loader: context.loader())
    let scene = try SceneState(document: SceneDocument(documentId: "pending-image-document"),
                               sceneId: "pending-image-scene", revision: 4)
    let ready = IllustrationStateEvent(jobId: "pending-image-job", requestId: "pending-image-request",
        sceneId: scene.sceneId, revision: scene.revision, intentEpoch: scene.intentEpoch,
        componentNodeIds: [], status: .ready, artifact: illustrationMetadata(bytes))
    images.register(requestID: ready.requestId, scene: scene)
    images.receive(ready, scene: scene, serverURL: context.serverURL, authToken: "fixture-token")
    #expect(images.presentation?.phase == .downloading)
    for _ in 0..<100 where context.fixture?.requests.isEmpty == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(context.fixture?.requests.count == 1)
    switch action {
    case "stop":
        #expect(images.cancel() == ready.jobId)
    case "stale":
        var stale = ready
        stale.status = .stale
        images.receive(stale, scene: scene, serverURL: context.serverURL, authToken: nil)
    default:
        images.retire()
    }
    // The continuation returns promptly on cancellation even while HTTP is stalled.
    for _ in 0..<100 {
        if try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: context.directory.path).isEmpty)
    images.receive(ready, scene: scene, serverURL: context.serverURL, authToken: "fixture-token")
    if action == "stop" { #expect(images.presentation?.phase == .cancelled) }
    else { #expect(images.presentation == nil) }
    #expect(images.presentation?.fileURL == nil)
    #expect(context.fixture?.requests.count == 1)
    images.retire()
}
