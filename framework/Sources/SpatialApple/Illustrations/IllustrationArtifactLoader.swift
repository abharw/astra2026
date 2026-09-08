import CryptoKit
import Foundation
import ImageIO

/// Immutable server metadata. Bytes are fetched separately and verified before display.
public struct IllustrationArtifact: Codable, Equatable, Sendable {
    public let artifactId: String
    public let sha256: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let model: String
    public let sourceRevision: Int
    public let path: String
    public let createdAt: String
    public let sourceArtifactId: String?

    public init(artifactId: String, sha256: String, mimeType: String, width: Int, height: Int,
                byteCount: Int, model: String, sourceRevision: Int, path: String,
                createdAt: String, sourceArtifactId: String? = nil) {
        self.artifactId = artifactId
        self.sha256 = sha256
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.model = model
        self.sourceRevision = sourceRevision
        self.path = path
        self.createdAt = createdAt
        self.sourceArtifactId = sourceArtifactId
    }
}

public enum IllustrationArtifactError: Error, Equatable, LocalizedError {
    case invalidMetadata
    case invalidServerURL
    case invalidResponse
    case redirectRejected
    case byteCountMismatch
    case checksumMismatch
    case invalidImage
    case cacheCapacityExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: "The illustration has invalid artifact metadata."
        case .invalidServerURL: "The illustration server address is invalid."
        case .invalidResponse: "The illustration server returned an invalid response."
        case .redirectRejected: "The illustration download attempted an unexpected redirect."
        case .byteCountMismatch: "The illustration download size does not match its metadata."
        case .checksumMismatch: "The illustration download failed its integrity check."
        case .invalidImage: "The illustration is not a complete PNG with the expected dimensions."
        case .cacheCapacityExceeded: "The illustration is larger than the local image cache."
        }
    }
}

/// A bounded disk cache keyed only by verified image content, never a prompt or credential.
public actor IllustrationArtifactLoader {
    private let cacheDirectory: URL
    private let maxBytes: Int
    private let configuration: URLSessionConfiguration
    private var activeDownloadNames = Set<String>()

    public init(cacheDirectory: URL? = nil, maxBytes: Int = 32 * 1024 * 1024, session: URLSession? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AstraIllustrations", isDirectory: true)
        self.maxBytes = max(0, min(maxBytes, 32 * 1024 * 1024))
        // Copying the configuration preserves URLProtocol test seams while this loader
        // owns redirect handling, cancellation, and its finite resource deadline.
        self.configuration = session?.configuration ?? .ephemeral
    }

    public func load(_ artifact: IllustrationArtifact, serverURL: URL, authToken: String?) async throws -> URL {
        try Task.checkCancellation()
        let url = try Self.artifactURL(artifact, serverURL: serverURL)
        guard artifact.byteCount <= maxBytes else { throw IllustrationArtifactError.cacheCapacityExceeded }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try removeInterruptedDownloads()
        let cached = cacheDirectory.appendingPathComponent("\(artifact.sha256).png")
        if FileManager.default.fileExists(atPath: cached.path) {
            var valid = false
            do {
                try Self.validateFile(cached, artifact: artifact)
                valid = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try FileManager.default.removeItem(at: cached)
            }
            if valid {
                try evict(toFit: 0, preserving: cached)
                return cached
            }
        }

        let temporary = cacheDirectory.appendingPathComponent(".partial-\(UUID().uuidString)")
        activeDownloadNames.insert(temporary.lastPathComponent)
        defer {
            activeDownloadNames.remove(temporary.lastPathComponent)
            try? FileManager.default.removeItem(at: temporary)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        if let authToken, !authToken.isEmpty {
            // The URL is constructed from the configured server origin only, and the
            // delegate rejects every redirect before credentials could be forwarded.
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        let download = try ArtifactDownload(destination: temporary, expectedBytes: artifact.byteCount, expectedURL: url)
        try await download.run(request: request, configuration: configuration)
        try Task.checkCancellation()
        try Self.validateFile(temporary, artifact: artifact)

        // Another caller can finish this content while the actor is awaiting the network.
        if FileManager.default.fileExists(atPath: cached.path) {
            try Self.validateFile(cached, artifact: artifact)
            try evict(toFit: 0, preserving: cached)
        } else {
            try evict(toFit: artifact.byteCount, preserving: nil)
            try FileManager.default.moveItem(at: temporary, to: cached)
        }
        return cached
    }

    private static func artifactURL(_ artifact: IllustrationArtifact, serverURL: URL) throws -> URL {
        guard isSHA256(artifact.sha256),
              artifact.artifactId == "sha256:\(artifact.sha256)",
              artifact.path == "/illustrations/artifacts/\(artifact.sha256).png",
              artifact.mimeType == "image/png", (1...2048).contains(artifact.width),
              (1...2048).contains(artifact.height), (1...(12 * 1024 * 1024)).contains(artifact.byteCount),
              artifact.model == "gpt-image-2.5-flare", artifact.sourceRevision >= 0,
              artifact.createdAt.utf8.count <= 64, isISO8601Date(artifact.createdAt),
              artifact.sourceArtifactId.map({ $0.hasPrefix("sha256:") && isSHA256(String($0.dropFirst(7))) }) ?? true
        else { throw IllustrationArtifactError.invalidMetadata }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { throw IllustrationArtifactError.invalidServerURL }
        components.scheme = ["wss", "https"].contains(scheme) ? "https" : "http"
        components.path = artifact.path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw IllustrationArtifactError.invalidServerURL }
        return url
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isISO8601Date(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func validateFile(_ url: URL, artifact: IllustrationArtifact) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == artifact.byteCount
        else { throw IllustrationArtifactError.byteCountMismatch }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count = 0
        var header = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= artifact.byteCount else { throw IllustrationArtifactError.byteCountMismatch }
            if header.isEmpty { header = chunk.prefix(24) }
            digest.update(data: chunk)
        }
        guard count == artifact.byteCount else { throw IllustrationArtifactError.byteCountMismatch }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256
        else { throw IllustrationArtifactError.checksumMismatch }
        guard header.count == 24, Array(header.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(header[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82]
        else { throw IllustrationArtifactError.invalidImage }
        let width = header[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let height = header[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        guard width == artifact.width, height == artifact.height,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == artifact.width, image.height == artifact.height
        else { throw IllustrationArtifactError.invalidImage }
        try Task.checkCancellation()
    }

    private func evict(toFit incomingBytes: Int, preserving preservedURL: URL?) throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys))
        let entries = try files.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.utf8
            return url.pathExtension == "png" && name.count == 64
                && name.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }.compactMap { url -> (URL, Int, Date)? in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(incomingBytes) { $0 + $1.1 }
        for (url, size, _) in entries where total > maxBytes && url.lastPathComponent != preservedURL?.lastPathComponent {
            try FileManager.default.removeItem(at: url)
            total -= size
        }
        guard total <= maxBytes else { throw IllustrationArtifactError.cacheCapacityExceeded }
    }

    private func removeInterruptedDownloads() throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys))
        // Compare names within this one directory: Foundation may enumerate /var
        // using /private/var, so equivalent file URLs need not compare equal.
        for url in files where !activeDownloadNames.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            guard name.hasPrefix(".partial-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// URLSession delegate calls are serial, but cancellation may arrive concurrently.
/// Every mutable field is protected by `lock`, including the single continuation.
private final class ArtifactDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let expectedBytes: Int
    private let expectedURL: URL
    private var handle: FileHandle?
    private var receivedBytes = 0
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    init(destination: URL, expectedBytes: Int, expectedURL: URL) throws {
        self.expectedBytes = expectedBytes
        self.expectedURL = expectedURL
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: destination)
    }

    func run(request: URLRequest, configuration source: URLSessionConfiguration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = source.copy() as! URLSessionConfiguration
                configuration.timeoutIntervalForResource = 30
                configuration.timeoutIntervalForRequest = 30
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(error: CancellationError())
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == expectedURL, response.mimeType?.lowercased() == "image/png",
              response.expectedContentLength == -1 || response.expectedContentLength == expectedBytes else {
            completionHandler(.cancel)
            finish(error: IllustrationArtifactError.invalidResponse)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        receivedBytes += data.count
        guard receivedBytes <= expectedBytes else {
            lock.unlock()
            finish(error: IllustrationArtifactError.byteCountMismatch)
            return
        }
        do {
            try handle?.write(contentsOf: data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(error: IllustrationArtifactError.redirectRejected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error: error)
    }

    private func finish(error: (any Error)?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        var resultError = error
        if resultError == nil, receivedBytes != expectedBytes { resultError = IllustrationArtifactError.byteCountMismatch }
        do { try handle?.close() } catch { if resultError == nil { resultError = error } }
        handle = nil
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        if let resultError { continuation?.resume(throwing: resultError) }
        else { continuation?.resume() }
    }
}
