//
// Transcriber.swift
//
// Turns microphone audio into text on the phone itself (Apple's on-device recogniser) and
// hands the text on in small finished pieces. Audio is never written anywhere.
//
// Whatever format the audio arrives in (16 kHz from the glasses' camera stream, 8 or 16 kHz
// from their Bluetooth mic, 48 kHz from the phone), it is converted to 16 kHz mono first.
//

import AVFoundation
import Foundation
import Speech

/// The two permissions the phone itself asks for. Kept out of any actor on purpose: the system
/// answers these on a background thread.
enum Permissions {
  static func speech() async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  static func microphone() async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }
}

final class Transcriber: @unchecked Sendable {
  /// A finished piece of speech. Called on the main thread.
  var onSegment: ((String) -> Void)?
  /// The words being heard right now; they may still change. Called on the main thread.
  var onPartial: ((String) -> Void)?
  /// Something the wearer should know about. Called on the main thread.
  var onProblem: ((String) -> Void)?

  // Shared with the audio thread, guarded by `lock`.
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var converter: AVAudioConverter?
  private var muted = false
  private var peak: Float = 0
  private var bufferCount = 0

  // Main thread only.
  private var recognizer: SFSpeechRecognizer?
  private var task: SFSpeechRecognitionTask?
  private var timer: Timer?
  private var running = false
  private var generation = 0
  private var latest = ""
  private var sentWords = 0
  private var lastChangeAt = Date()
  private var taskStartedAt = Date()
  private var failures = 0

  /// True when recognition runs entirely on this phone.
  private(set) var onDevice = false

  private let target = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )

  // MARK: - Start and stop (main thread)

  @discardableResult
  func start(language: String) -> Bool {
    stop()
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
      onProblem?("This iPhone cannot transcribe that language.")
      return false
    }
    guard recognizer.isAvailable else {
      onProblem?("Speech recognition is not available right now. Check that Siri & Dictation are on.")
      return false
    }
    self.recognizer = recognizer
    onDevice = recognizer.supportsOnDeviceRecognition
    failures = 0
    running = true
    beginTask()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.checkPause()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    return true
  }

  func stop() {
    if running { flush(holdingBack: 0) }
    running = false
    timer?.invalidate()
    timer = nil
    lock.lock()
    let previous = request
    request = nil
    converter = nil
    peak = 0
    lock.unlock()
    previous?.endAudio()
    task?.cancel()
    task = nil
    generation += 1
    latest = ""
    sentWords = 0
  }

  /// While muted, incoming audio is dropped (used while Gist itself is speaking).
  func setMuted(_ value: Bool) {
    lock.lock()
    muted = value
    lock.unlock()
  }

  /// The loudest sample since the last call (0...1) and how many buffers have arrived so far.
  func takeLevel() -> (Float, Int) {
    lock.lock()
    let level = peak
    let count = bufferCount
    peak = 0
    lock.unlock()
    return (level, count)
  }

  // MARK: - Recognition (main thread)

  private func beginTask() {
    guard running, let recognizer else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.addsPunctuation = true
    request.taskHint = .dictation

    generation += 1
    let mine = generation
    latest = ""
    sentWords = 0
    lastChangeAt = Date()
    taskStartedAt = Date()

    lock.lock()
    let previous = self.request
    self.request = request
    lock.unlock()
    previous?.endAudio()
    task?.cancel()

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failure = error?.localizedDescription
      DispatchQueue.main.async {
        self?.handle(generation: mine, text: text, isFinal: isFinal, failure: failure)
      }
    }
  }

  private func handle(generation mine: Int, text: String?, isFinal: Bool, failure: String?) {
    guard running, mine == generation else { return }   // a retired task still reporting
    let failed = failure != nil
    if let text, text != latest {
      failures = 0
      latest = text
      lastChangeAt = Date()
      let pending = unsentWords()
      if !pending.isEmpty { onPartial?(pending.joined(separator: " ")) }
      // A speaker who does not pause still gets sent on; the newest two words may yet change.
      if pending.count >= 20 { flush(holdingBack: 2) }
    }
    if isFinal || failed {
      // The recogniser closed this task itself: its own time limit, or an error such as a long silence.
      flush(holdingBack: 0)
      // A task that ran for a while and then closed is normal (a long silence does it).
      // Only tasks that die the moment they start count as trouble.
      let diedAtOnce = Date().timeIntervalSince(taskStartedAt) < 1.0
      if failed, diedAtOnce { failures += 1 } else { failures = 0 }
      if failures == 6 {
        onProblem?("Speech recognition keeps stopping (\(failure ?? "no reason given")). On a first run, give the iPhone a minute to fetch its language model, then start again.")
      }
      let delay: TimeInterval = !failed ? 0 : (failures > 5 ? 2.0 : 0.4)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, self.running, self.generation == mine else { return }
        self.beginTask()
      }
    }
  }

  private func checkPause() {
    guard running else { return }
    let now = Date()
    let quiet = now.timeIntervalSince(lastChangeAt)
    if !unsentWords().isEmpty, quiet > 0.8 {
      // The speaker paused: send what was said and start a fresh task for what comes next.
      flush(holdingBack: 0)
      beginTask()
    } else if now.timeIntervalSince(taskStartedAt) > 45, quiet > 0.8 {
      beginTask()   // a fresh task now and then keeps recognition quick
    }
  }

  private func unsentWords() -> [Substring] {
    let all = latest.split(whereSeparator: { $0 == " " || $0 == "\n" })
    return Array(all.dropFirst(sentWords))
  }

  private func flush(holdingBack: Int) {
    let pending = unsentWords()
    let count = max(0, pending.count - holdingBack)
    guard count > 0 else { return }
    let text = pending.prefix(count).joined(separator: " ")
    sentWords += count
    onSegment?(text)
  }

  // MARK: - Audio in (any thread)

  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let target else { return }

    lock.lock()
    let request = self.request
    let isMuted = muted
    var converter = self.converter
    let sameFormat = buffer.format == target
    if request != nil, !sameFormat {
      if converter == nil || converter?.inputFormat != buffer.format {
        converter = AVAudioConverter(from: buffer.format, to: target)
        self.converter = converter
      }
    }
    bufferCount += 1
    lock.unlock()

    guard let request, !isMuted else { return }

    if sameFormat {
      measure(buffer)
      request.append(buffer)
      return
    }
    guard let converter else { return }

    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

    // One buffer in, then "no more for now": the converter pulls its input.
    var supplied = false
    var conversionError: NSError?
    converter.convert(to: converted, error: &conversionError) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard conversionError == nil, converted.frameLength > 0 else { return }
    measure(converted)
    request.append(converted)
  }

  private func measure(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let samples = channels[0]
    let count = Int(buffer.frameLength)
    var top: Float = 0
    var index = 0
    while index < count {
      let value = abs(samples[index])
      if value > top { top = value }
      index += 8
    }
    lock.lock()
    if top > peak { peak = top }
    lock.unlock()
  }
}
