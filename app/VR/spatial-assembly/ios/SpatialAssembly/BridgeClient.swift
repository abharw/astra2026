import Foundation
import OSLog

@MainActor final class BridgeClient: ObservableObject {
  @Published var connected = false
  @Published var status = "Connecting to your Mac…"
  var onEvent: (([String: Any]) -> Void)?
  private var socket: URLSessionWebSocketTask?
  private let session = URLSession(configuration: .default)
  private var pingTimer: Timer?
  private var connectionID = UUID()
  private var wantsConnection = false
  var baseURL: String = ""
  var token: String = ""
  init() {
    if let url = Bundle.main.url(forResource: "Connection", withExtension: "plist"),
      let data = try? Data(contentsOf: url),
      let c = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: String]
    {
      baseURL = UserDefaults.standard.string(forKey: "bridgeURL") ?? c["url"] ?? ""
      token = c["token"] ?? ""
    }
  }
  func connect() {
    guard socket == nil else { return }
    wantsConnection = true
    connectionID = UUID()
    let id = connectionID
    guard var components = URLComponents(string: baseURL), components.scheme == "https",
      !token.isEmpty
    else {
      status = "Bridge is not configured"
      return
    }
    components.scheme = "wss"
    components.path = "/session"
    components.query = nil
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 20
    let task = session.webSocketTask(with: request)
    socket = task
    task.resume()
    receive(task, id: id)
    pingTimer?.invalidate()
    pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.send(["type": "ping"]) }
    }
  }
  private func receive(_ task: URLSessionWebSocketTask, id: UUID) {
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self, self.connectionID == id else { return }
        switch result {
        case .success(let message):
          let data: Data
          switch message {
          case .string(let text): data = Data(text.utf8)
          case .data(let d): data = d
          @unknown default: return
          }
          if let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if e["type"] as? String == "connected" {
              self.connected = true
              self.status = "GPT‑6 + Realtime connected"
            }
            self.onEvent?(e)
          }
          self.receive(task, id: id)
        case .failure:
          self.connected = false
          self.status = "Bridge disconnected · tap Reconnect"
          self.socket = nil
          self.pingTimer?.invalidate()
          self.onEvent?(["type": "disconnected"])
        }
      }
    }
  }
  func send(_ event: [String: Any]) {
    guard let socket, let d = try? JSONSerialization.data(withJSONObject: event),
      let s = String(data: d, encoding: .utf8)
    else { return }
    socket.send(.string(s)) { [weak self] error in
      if error != nil { Task { @MainActor in self?.status = "Connection interrupted" } }
    }
  }
  func disconnect() {
    wantsConnection = false
    connectionID = UUID()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    connected = false
    pingTimer?.invalidate()
  }
  func reconnect() {
    disconnect()
    status = "Reconnecting…"
    connect()
  }
}
