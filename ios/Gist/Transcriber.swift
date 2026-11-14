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
  /// A finished piece of speech, whose voice it was ("me" for the wearer, "them", or "" when
  /// that cannot be told yet), and the piece's number. Called on the main thread.
  var onSegment: ((String, String, Int) -> Void)?
  /// Earlier pieces that could not be told apart when they were heard, now that both voices
  /// have been: piece number to "me" or "them". Called on the main thread, before `onSegment`
  /// for the piece that settled it.
  var onRelabel: (([Int: String]) -> Void)?
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
  private var lifting = true
  private var liftShown: Float = 1
  private var secondsIn: Double = 0
  private var wordsToExpect: [String] = []

  // The leveller's own state, guarded by `levelLock` (audio can arrive on more than one thread
  // for a moment when the microphone is switched).
  private let levelLock = NSLock()
  private var envelope: Float = 0.02
  private var floorLevel: Float = 0.003
  private var gain: Float = 1
  // Whose voice. For the speech since the last finished piece: how many hundredths of a second
  // fell in each 2 dB step of loudness, from -70 dB up. And for this listening session: how loud
  // the loudest and the quietest pieces so far were (the wearer's voice and the other person's).
  private var pieceLevels = [Int](repeating: 0, count: 36)
  private var pieceBlocks = 0
  private var loudVoice: Float?
  private var quietVoice: Float?
  private var tellingVoicesApart = false
  private var pieceNumber = 0
  /// Pieces heard before both voices had been: their number and how loud they were.
  private var unmarked: [(number: Int, level: Float)] = []

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
    liftShown = 1
    lock.unlock()
    levelLock.lock()
    envelope = 0.02
    floorLevel = 0.003
    gain = 1
    pieceLevels = [Int](repeating: 0, count: 36)
    pieceBlocks = 0
    levelLock.unlock()
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

  /// Names and unusual words the recogniser should expect (a company, a product, a person).
  /// Without this a name it has never met comes out as the nearest ordinary word.
  func setWordsToExpect(_ words: [String]) {
    lock.lock()
    wordsToExpect = Array(words.prefix(100))
    lock.unlock()
  }

  /// Whether the sound comes from microphones worn on the face (the glasses' own). Only then
  /// does loudness say whose voice it is. Each listening session starts from nothing: how loud
  /// the glasses' feed is can differ by ten decibels from one session to the next.
  func setWornMicrophones(_ value: Bool) {
    levelLock.lock()
    tellingVoicesApart = value
    pieceLevels = [Int](repeating: 0, count: 36)
    pieceBlocks = 0
    loudVoice = nil
    quietVoice = nil
    unmarked = []
    levelLock.unlock()
  }

  /// Whose voice the speech since the last call was: "me" (the wearer), "them", or "" when the
  /// sound cannot tell.
  ///
  /// The glasses' microphones are a hand's width from the wearer's mouth, so the wearer arrives
  /// fifteen to twenty decibels louder than anyone across a table (measured on Ray-Ban Display:
  /// peaks near -8 dB against -25 to -35 in one session, -19 against -35 to -44 in the next).
  /// The gap holds; the absolute level does not. So nothing is assumed about how loud the
  /// wearer is. Once this session has heard both a loud voice and one at least twelve decibels
  /// quieter, the line between "me" and "them" is drawn halfway between the two. A piece with a
  /// good share of its speech above the line is the wearer's; one with next to none is someone
  /// else's; in between (two people in one piece) it is left open.
  ///
  /// Before both voices have been heard, only a voice too loud to be anyone else is marked.
  /// Marking the other person as the wearer is the mistake that matters (their question would
  /// stop counting as put to the wearer), so when in doubt nothing is marked.
  private func takeWho() -> (who: String, number: Int, earlier: [Int: String]) {
    levelLock.lock()
    defer { levelLock.unlock() }
    pieceNumber += 1
    let number = pieceNumber
    let levels = pieceLevels
    let blocks = pieceBlocks
    pieceLevels = [Int](repeating: 0, count: 36)
    pieceBlocks = 0
    guard tellingVoicesApart, blocks >= 15 else { return ("", number, [:]) }

    // How loud the piece was: the level only its loudest tenth went above.
    var above = 0
    var step = 35
    while step > 0 {
      above += levels[step]
      if above * 10 >= blocks { break }
      step -= 1
    }
    let piece = Float(step) * 2 - 69      // the middle of that step, in dB

    // The loudest and the quietest voices so far drift slowly towards the newest piece, so one
    // odd piece does not set them for good.
    let loud = max(piece, (loudVoice ?? piece) - 0.1)
    let quiet = min(piece, (quietVoice ?? piece) + 0.1)
    loudVoice = loud
    quietVoice = quiet

    // Both voices heard, and the loud one loud enough to be at the frame itself.
    if loud >= -30, loud - quiet >= 12 {
      let line = (loud + quiet) / 2
      // Pieces from before the line could be drawn are settled now, by how loud they were.
      var earlier: [Int: String] = [:]
      for old in unmarked {
        if old.level > line + 3 { earlier[old.number] = "me" } else if old.level < line - 3 { earlier[old.number] = "them" }
      }
      unmarked = []
      var over = 0
      for index in 0..<36 where Float(index) * 2 - 69 > line { over += levels[index] }
      let share = Double(over) / Double(blocks)
      if share >= 0.25 { return ("me", number, earlier) }
      if share <= 0.04 { return ("them", number, earlier) }
      return ("", number, earlier)
    }
    // Only one voice so far. Louder than anyone across a table gets: the wearer.
    if piece >= -22 { return ("me", number, [:]) }
    unmarked.append((number, piece))
    if unmarked.count > 40 { unmarked.removeFirst(unmarked.count - 40) }
    return ("", number, [:])
  }

  /// Whether quiet voices are lifted (and the wearer's own voice held down) before recognition.
  func setLifting(_ value: Bool) {
    lock.lock()
    lifting = value
    if !value { liftShown = 1 }
    lock.unlock()
  }

  /// The loudest sample since the last call (0...1), as it arrived, before any lifting, and how
  /// many buffers have arrived so far.
  func takeLevel() -> (Float, Int) {
    lock.lock()
    let level = peak
    let count = bufferCount
    peak = 0
    lock.unlock()
    return (level, count)
  }

  /// How many seconds of sound have arrived since this transcriber was made. Set against the
  /// clock, it says whether any sound is going missing on the way from the glasses.
  func secondsHeard() -> Double {
    lock.lock()
    let value = secondsIn
    lock.unlock()
    return value
  }

  /// How much the sound is being lifted right now (1 means not at all).
  func liftNow() -> Float {
    lock.lock()
    let value = liftShown
    lock.unlock()
    return value
  }

  // MARK: - Recognition (main thread)

  private func beginTask() {
    guard running, let recognizer else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.addsPunctuation = true
    request.taskHint = .dictation
    lock.lock()
    let expected = wordsToExpect
    lock.unlock()
    if !expected.isEmpty { request.contextualStrings = expected }

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
    let voice = takeWho()
    if !voice.earlier.isEmpty { onRelabel?(voice.earlier) }
    onSegment?(text, voice.who, voice.number)
  }

  // MARK: - Audio in (any thread)

  func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let target else { return }

    lock.lock()
    let request = self.request
    let isMuted = muted
    let lift = lifting
    var converter = self.converter
    let sameFormat = buffer.format == target
    if request != nil, !sameFormat {
      if converter == nil || converter?.inputFormat != buffer.format {
        converter = AVAudioConverter(from: buffer.format, to: target)
        // Two or more microphones are mixed into one, not cut down to the first.
        if buffer.format.channelCount > 1 { converter?.downmix = true }
        self.converter = converter
      }
    }
    bufferCount += 1
    if buffer.format.sampleRate > 0 { secondsIn += Double(buffer.frameLength) / buffer.format.sampleRate }
    lock.unlock()

    guard let request, !isMuted else { return }

    if sameFormat {
      measure(buffer)
      request.append(levelled(buffer, lift: lift))
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
    request.append(levelled(converted, lift: lift))
  }

  /// Evens out loudness before the words are recognised. The glasses' microphones sit next to
  /// the wearer's mouth, so the wearer arrives many times louder than the person across the
  /// table, and a recogniser follows the loud voice. This lifts quiet speech towards a normal
  /// level (up to twenty-four times) and holds a loud voice down, ten milliseconds at a time.
  ///
  /// It never lifts the room's own hum above a low ceiling, so a silent stretch stays quiet
  /// instead of turning into noise the recogniser would try to read.
  ///
  /// Returns a new buffer: the one that came in is left as it was (the glasses' SDK asks for that).
  /// With `lift` off the sound is only listened to (for whose voice it is) and handed back unchanged.
  private func levelled(_ buffer: AVAudioPCMBuffer, lift: Bool) -> AVAudioPCMBuffer {
    guard let source = buffer.floatChannelData else { return buffer }
    let out = lift ? AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) : nil
    let count = Int(buffer.frameLength)
    out?.frameLength = buffer.frameLength
    let input = source[0]
    let output = out?.floatChannelData?[0]

    let wantedLevel: Float = 0.1      // where speech should sit (about -20 dB)
    let humCeiling: Float = 0.022     // the room's hum is never lifted above this (about -33 dB)
    let mostLift: Float = 24          // +28 dB
    let leastLift: Float = 0.5        // a very loud voice is turned down by at most half

    levelLock.lock()
    var start = 0
    while start < count {
      let end = min(count, start + 160)
      let length = Float(end - start)
      var sum: Float = 0
      var index = start
      while index < end {
        let value = input[index]
        sum += value * value
        index += 1
      }
      let loudness = (sum / length).squareRoot()

      // The room's hum: follows the quietest moments down quickly, and creeps up slowly.
      if loudness < floorLevel {
        floorLevel += (loudness - floorLevel) * 0.3
      } else {
        floorLevel = min(loudness, floorLevel * 1.0017)
      }
      if floorLevel < 0.00003 { floorLevel = 0.00003 }

      // The voice: jumps up at once, and falls back within a quarter of a second. It has to be
      // that quick: when the wearer stops and the other person answers straight away, a slower
      // lift leaves their first words far too quiet (a full second, on the first version).
      if loudness > envelope {
        envelope = loudness
      } else {
        envelope += (loudness - envelope) * 0.12
      }

      // Whose voice: anything clearly above the room's hum counts as speech, and is filed
      // under how loud it was.
      if tellingVoicesApart, loudness > max(floorLevel * 3, 0.002) {
        let decibels = 20 * log10f(loudness)
        pieceLevels[min(35, max(0, Int((decibels + 70) / 2)))] += 1
        pieceBlocks += 1
      }

      var wanted = wantedLevel / max(envelope, 0.00003)
      wanted = min(wanted, mostLift, max(1, humCeiling / floorLevel))
      wanted = max(wanted, leastLift)
      // Down at once (a loud voice must not clip), up quickly but not in one step.
      let next = wanted < gain ? wanted : gain + (wanted - gain) * 0.3

      if let output {
        index = start
        while index < end {
          let position = Float(index - start) / length
          var value = input[index] * (gain + (next - gain) * position)
          // Anything still too loud is rounded off, not cut.
          if value > 0.7 {
            value = 0.7 + 0.3 * tanhf((value - 0.7) / 0.3)
          } else if value < -0.7 {
            value = -0.7 - 0.3 * tanhf((-value - 0.7) / 0.3)
          }
          output[index] = value
          index += 1
        }
      }
      gain = next
      start = end
    }
    let shown = lift ? gain : 1
    levelLock.unlock()

    lock.lock()
    liftShown = shown
    lock.unlock()
    return out ?? buffer
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
