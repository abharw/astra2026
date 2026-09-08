import AVFoundation
import Foundation

@MainActor final class RealtimeAudio {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var converter: AVAudioConverter?
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
  private let inputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
  private var running = false
  private var recording = false
  var onAudio: ((String) -> Void)?
  var onError: ((String) -> Void)?
  func requestPermission() async -> Bool {
    await withCheckedContinuation { cont in
      AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
    }
  }
  func start(inputEnabled: Bool = true) throws {
    guard !running else { return }
    let audio = AVAudioSession.sharedInstance()
    if !inputEnabled {
      try audio.setCategory(.playback, mode: .spokenAudio)
      try audio.setActive(true)
      engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
      engine.prepare(); try engine.start(); player.play(); running = true; recording = false
      return
    }
    try audio.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try audio.setActive(true)
    try? audio.overrideOutputAudioPort(.speaker)
    let input = engine.inputNode
    try input.setVoiceProcessingEnabled(true)
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
    let hardware = input.outputFormat(forBus: 0)
    guard hardware.sampleRate > 0, let conv = AVAudioConverter(from: hardware, to: inputFormat)
    else {
      throw NSError(
        domain: "Audio", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Microphone format is unavailable"])
    }
    converter = conv
    let format = inputFormat
    recording = true
    input.installTap(onBus: 0, bufferSize: 2048, format: hardware) { [weak self] buffer, _ in
      let capacity = AVAudioFrameCount(
        Double(buffer.frameLength) * 24000 / hardware.sampleRate + 32)
      guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
        return
      }
      var fed = false
      var error: NSError?
      conv.convert(to: converted, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      guard error == nil, converted.frameLength > 0, let ptr = converted.int16ChannelData?[0] else {
        return
      }
      let data = Data(bytes: ptr, count: Int(converted.frameLength) * 2)
      let encoded = data.base64EncodedString()
      Task { @MainActor in
        guard let self, self.running else { return }
        self.onAudio?(encoded)
      }
    }
    engine.prepare()
    try engine.start()
    player.play()
    running = true
  }
  func play(_ base64: String) {
    guard running, let d = Data(base64Encoded: base64), d.count >= 2,
      let b = AVAudioPCMBuffer(
        pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(d.count / 2)),
      let out = b.floatChannelData?[0]
    else { return }
    b.frameLength = AVAudioFrameCount(d.count / 2)
    d.withUnsafeBytes { raw in
      for i in 0..<Int(b.frameLength) {
        let x = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
        out[i] = Float(Int16(littleEndian: x)) / 32768
      }
    }
    player.scheduleBuffer(b, completionHandler: nil)
  }
  func interrupt() {
    guard running else { return }
    player.stop()
    player.play()
  }
  func stop() {
    guard running else { return }
    running = false
    if recording { engine.inputNode.removeTap(onBus: 0) }; recording = false
    engine.stop()
    player.stop()
    engine.detach(player)
    converter = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
