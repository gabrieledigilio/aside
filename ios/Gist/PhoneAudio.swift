//
// PhoneAudio.swift
//
// Microphone audio that reaches the phone directly, for the two lanes that do not ride on the
// glasses' camera stream:
//
//   glassesBluetooth   the glasses' own microphone, over Bluetooth (the way a headset works)
//   phone              the iPhone's microphone, for trying Gist with no glasses at hand
//
// When the glasses' Bluetooth mic is asked for and is not there, this fails rather than
// quietly listening with the phone instead.
//

import AVFoundation
import Foundation

final class PhoneAudio: @unchecked Sendable {
  enum Source {
    case glassesBluetooth
    case phone
  }

  enum Failure: LocalizedError {
    case noGlassesMicrophone
    case noInput

    var errorDescription: String? {
      switch self {
      case .noGlassesMicrophone:
        return "The glasses’ Bluetooth microphone is not available. Check that the glasses are on, unfolded and connected to this iPhone."
      case .noInput:
        return "No microphone is available right now."
      }
    }
  }

  /// Called on the main thread if the microphone in use goes away (the glasses were folded, say).
  var onLost: (() -> Void)?

  private var engine = AVAudioEngine()
  private var running = false
  private var source: Source = .phone
  private var routeObserver: NSObjectProtocol?

  /// Starts capturing and returns the name of the microphone in use.
  /// `onBuffer` is called on an audio thread.
  func start(_ source: Source, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws -> String {
    stop()
    self.source = source
    let session = AVAudioSession.sharedInstance()

    switch source {
    case .glassesBluetooth:
      try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetoothHFP, .mixWithOthers])
      try session.setActive(true)
      guard let microphone = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        throw Failure.noGlassesMicrophone
      }
      try session.setPreferredInput(microphone)
      guard session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) else {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        throw Failure.noGlassesMicrophone
      }
    case .phone:
      try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
        try session.setPreferredInput(builtIn)
      }
    }

    engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.inputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw Failure.noInput
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      onBuffer(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw error
    }
    running = true

    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.routeChanged()
    }
    return session.currentRoute.inputs.first?.portName ?? "Microphone"
  }

  func stop() {
    if let routeObserver {
      NotificationCenter.default.removeObserver(routeObserver)
    }
    routeObserver = nil
    guard running else { return }
    running = false
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func routeChanged() {
    guard running, source == .glassesBluetooth else { return }
    let stillGlasses = AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    if !stillGlasses {
      stop()
      onLost?()
    }
  }
}

/// Says a short line through whatever the glasses use as their speaker. For glasses with no display.
final class Whisperer: NSObject, AVSpeechSynthesizerDelegate {
  /// Called on the main thread when speaking starts (true) and ends (false).
  var onSpeakingChanged: ((Bool) -> Void)?

  private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  /// True when what is said lands in an ear (the glasses, or headphones) rather than in the room.
  var hasPrivateOutput: Bool {
    AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
      output.portType == .bluetoothA2DP || output.portType == .bluetoothHFP
        || output.portType == .bluetoothLE || output.portType == .headphones
    }
  }

  func say(_ text: String, language: String) {
    // Never out loud: a prompt meant for the wearer must not come out of the phone's speaker.
    guard hasPrivateOutput else { return }
    // Only away from the system default. A category a microphone lane chose is left alone.
    let session = AVAudioSession.sharedInstance()
    if session.category == .soloAmbient {
      try? session.setCategory(.playback, mode: .spokenAudio)
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    utterance.rate = 0.5
    utterance.volume = 0.9
    if synthesizer.isSpeaking {
      _ = synthesizer.stopSpeaking(at: .immediate)
    }
    synthesizer.speak(utterance)
  }

  func hush() {
    if synthesizer.isSpeaking {
      _ = synthesizer.stopSpeaking(at: .immediate)
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    report(true)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    report(false)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    report(false)
  }

  private func report(_ speaking: Bool) {
    DispatchQueue.main.async { [weak self] in
      self?.onSpeakingChanged?(speaking)
    }
  }
}
