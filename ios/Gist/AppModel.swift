//
// AppModel.swift
//
// Ties the pieces together: what Gist listens with, where the thinking happens, what goes to
// the glasses, and the day around it. The views only ever talk to this.
//

import AVFoundation
import Combine
import Foundation
import Security
import UIKit

// MARK: - Choices

/// What Gist listens with.
enum Ears: String, CaseIterable, Identifiable {
  case glassesStream
  case glassesSpeech
  case glassesBluetooth
  case phone

  var id: String { rawValue }

  var title: String {
    switch self {
    case .glassesStream: return "Glasses microphones"
    case .glassesSpeech: return "Glasses speech"
    case .glassesBluetooth: return "Glasses Bluetooth mic"
    case .phone: return "This iPhone (testing only)"
    }
  }

  var detail: String {
    switch self {
    case .glassesStream:
      return "The glasses’ own microphones, carried by their camera stream. Hears the room, so it hears the person talking to you. The capture light on the glasses stays on, which also tells the other person."
    case .glassesSpeech:
      return "The glasses turn speech into text themselves and send only the text. Lightest on battery. Tuned for the wearer’s voice, so it may miss the other person."
    case .glassesBluetooth:
      return "The glasses’ microphone the way a headset sends it. Works on every pair, lower quality, closest to the wearer."
    case .phone:
      return "The iPhone’s microphone. Only for trying Aside with no glasses at hand."
    }
  }

  /// The name the lens knows this source by.
  var lensName: String {
    switch self {
    case .glassesStream: return "glasses"
    case .glassesSpeech: return "speech"
    case .glassesBluetooth: return "hfp"
    case .phone: return "phone"
    }
  }

  var needsGlassesSession: Bool {
    self == .glassesStream || self == .glassesSpeech
  }
}

/// Where the thinking happens.
enum BrainPlace: String, CaseIterable, Identifiable {
  case phone
  case mac

  var id: String { rawValue }
}

// MARK: - What the views show

struct DayEvent: Identifiable {
  let id: String
  let title: String
  let start: Date
  let place: String
  let prep: [String]
}

struct PastTalk: Identifiable {
  let id: String
  let title: String
  let points: [String]
  let actions: [String]
  let open: String
  let at: Date
}

struct PlainLens {
  var title = ""
  var sub = ""
  var body = ""
  var say = ""
}

/// The model key is kept in the iPhone's keychain, not in plain settings.
enum Keychain {
  private static let service = "gist"

  static func read(_ name: String) -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func write(_ name: String, _ value: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: name,
    ]
    _ = SecItemDelete(base as CFDictionary)
    guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
    var entry = base
    entry[kSecValueData as String] = data
    entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    _ = SecItemAdd(entry as CFDictionary, nil)
  }
}

// MARK: - The model

@MainActor
final class AppModel: ObservableObject {
  let glasses: GlassesLink
  let lens: LensHost

  // Settings, kept between launches.
  @Published var ears: Ears { didSet { store.set(ears.rawValue, forKey: "ears"); restartIfListening() } }
  @Published var brainPlace: BrainPlace { didSet { store.set(brainPlace.rawValue, forKey: "brainPlace"); loadLens() } }
  @Published var showOnGlasses: Bool { didSet { store.set(showOnGlasses, forKey: "showOnGlasses"); restartIfListening() } }
  @Published var plainOnGlasses: Bool { didSet { store.set(plainOnGlasses, forKey: "plainOnGlasses"); sharpAgain(); lens.call("redraw") } }
  @Published var mobileDataBackup: Bool { didSet { store.set(mobileDataBackup, forKey: "mobileDataBackup"); lens.allowMobileData = mobileDataBackup } }
  @Published var cameraForLook: Bool { didSet { store.set(cameraForLook, forKey: "cameraForLook"); restartIfListening() } }
  @Published var whisper: Bool { didSet { store.set(whisper, forKey: "whisper"); if !whisper { whisperer.hush() } } }
  @Published var useCalendar: Bool { didSet { store.set(useCalendar, forKey: "useCalendar"); refreshDay() } }
  @Published var language: String { didSet { store.set(language, forKey: "language"); restartIfListening() } }
  @Published var practiceGlasses: Bool { didSet { store.set(practiceGlasses, forKey: "practiceGlasses"); applyPracticeGlasses() } }
  @Published var apiKey: String { didSet { Keychain.write("modelKey", apiKey); lens.apiKey = apiKey } }
  @Published var macAddress: String { didSet { store.set(macAddress, forKey: "macAddress") } }
  @Published var macCode: String { didSet { Keychain.write("macCode", macCode) } }

  // What is happening right now.
  @Published var isListening = false
  @Published var isStarting = false
  @Published var isSampling = false
  @Published var problem = ""
  @Published var hearing = ""
  @Published var lastHeard = ""
  @Published var level: Float = 0
  @Published var audioFlowing = false
  /// Where speech is being turned into text for this listening session.
  @Published var speechNote = ""
  @Published var microphoneName = ""
  @Published var phase = "standby"
  @Published var view = "standby"
  @Published var spokenLens = ""
  @Published var modelNote = ""
  /// The outcome of the last "test the mobile data fallback" in Settings.
  @Published var mobileDataCheck = ""
  @Published var modelError = ""
  @Published var lensReady = false
  @Published var brainNote = ""
  @Published var events: [DayEvent] = []
  @Published var talks: [PastTalk] = []
  @Published var showLinkPrompt = false
  @Published var linkPromptText = ""

  private let store = UserDefaults.standard
  private let transcriber = Transcriber()
  private let phoneAudio = PhoneAudio()
  private let dayReader = DayReader()
  private let whisperer = Whisperer()
  private var bag = Set<AnyCancellable>()
  private var meter: Timer?
  private var dayTimer: Timer?
  private var plain = PlainLens()
  private var lastSaid = ""
  private var lastSaidAt = Date.distantPast
  private var deafUntil = Date.distantPast
  private var lastBufferCount = 0
  private var quietTicks = 0
  private var practiceEvents: [CalendarEntry] = []
  private var pendingLinkAddress = ""
  private var pendingLinkCode = ""
  private var sampleRun = 0
  private var pushCount = 0
  /// The side of the picture sent to the glasses. It steps down when frames arrive slowly.
  @Published var frameSide = 600
  /// Set when even the lightest picture was too slow: the glasses then get words.
  @Published var wordsBecauseSlow = false
  private var slowFrames = 0
  /// When a model answer last had to come over mobile data because Wi-Fi had gone quiet.
  private var mobileDataAt = Date.distantPast
  private var quickFrames = 0
  private var quickNeeded = 5
  private var wordsSince = Date.distantPast
  /// True while the short menu is up on the glasses.
  @Published var menuOnGlasses = false
  private var menuTurn = 0
  /// False while the wearer has paused the lens.
  private var lensListening = true
  /// The lens alone, full screen and sideways, for a phone that is mirrored onto a big screen.
  @Published var showStage = false { didSet { if showStage != oldValue { turnScreen() } } }

  /// A short pitch, the kind Gist was made for. Played back as if someone were saying it.
  static let sampleSentences: [String] = [
    "Okay so hear me out, the idea is basically a marketplace, but for leftover hackathon hardware.",
    "Every event ends with boxes of sensors and dev boards that nobody takes home.",
    "Organizers have supply they don't want, and student teams have demand they can't afford.",
    "So we sit in the middle and we fix the liquidity problem.",
    "The trick is we don't hold inventory, we just match, so it's asset-light.",
    "We make money with a take rate, ten percent on each swap, and the average box is worth about forty euros.",
    "With two hundred events a year in Europe, that's the whole market.",
    "And there's a flywheel: more events means more boards, more boards means more students, and more students makes organizers list faster.",
    "For shipping there are two options.",
    "Either the organizer ships each box, which is slow and eats our margin, or students pick up at the next event, which is free but takes weeks.",
    "The plan is simple: first we launch here at Junction, then we sign five organizers, and by spring we open the marketplace to every campus.",
    "So, what do you think, would you join?",
  ]

  init() {
    let saved = UserDefaults.standard
    glasses = GlassesLink()
    lens = LensHost()
    ears = Ears(rawValue: saved.string(forKey: "ears") ?? "") ?? .glassesStream
    brainPlace = BrainPlace(rawValue: saved.string(forKey: "brainPlace") ?? "") ?? .phone
    showOnGlasses = saved.object(forKey: "showOnGlasses") as? Bool ?? true
    plainOnGlasses = saved.bool(forKey: "plainOnGlasses")
    mobileDataBackup = saved.object(forKey: "mobileDataBackup") as? Bool ?? true
    cameraForLook = saved.bool(forKey: "cameraForLook")
    whisper = saved.bool(forKey: "whisper")
    useCalendar = saved.bool(forKey: "useCalendar")
    language = saved.string(forKey: "language") ?? "en-US"
    practiceGlasses = saved.bool(forKey: "practiceGlasses")
    apiKey = Keychain.read("modelKey")
    macAddress = saved.string(forKey: "macAddress") ?? ""
    macCode = Keychain.read("macCode")

    wire()
    if practiceGlasses { glasses.useMockGlasses() }
    loadLens()
  }

  // MARK: - Wiring

  private func wire() {
    // Anything the glasses link publishes redraws the views that read it through this model.
    glasses.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &bag)

    transcriber.onSegment = { [weak self] text in self?.heard(text) }
    transcriber.onPartial = { [weak self] text in self?.hearing = text }
    transcriber.onProblem = { [weak self] text in self?.problem = text }

    phoneAudio.onLost = { [weak self] in
      guard let self, self.isListening else { return }
      self.stop()
      self.problem = "The glasses’ microphone went away. Start again when they are back on."
    }

    glasses.onTranscript = { [weak self] text, isFinal in self?.glassesSaid(text, isFinal: isFinal) }
    glasses.onPhoto = { [weak self] data in self?.sawPhoto(data) }
    glasses.onTap = { [weak self] in self?.openGlassesMenu() }
    glasses.onChoice = { [weak self] id in self?.chose(id) }
    // Glasses that come into reach get the lens on standby, so the first pinch can come from the band.
    glasses.$hasDevice
      .removeDuplicates()
      .sink { [weak self] inReach in
        if inReach { self?.standOnGlasses(after: 0.8) }
      }
      .store(in: &bag)
    glasses.onDisplayReady = { [weak self] in self?.lens.call("redraw") }
    glasses.onFrameTiming = { [weak self] took in self?.frameTook(took) }
    glasses.onSessionEnded = { [weak self] in self?.glassesLeft() }

    lens.onReady = { [weak self] place in self?.lensCameUp(place) }
    lens.onState = { [weak self] body in self?.lensChanged(body) }
    lens.onLook = { [weak self] in _ = self?.glasses.capturePhoto() }
    lens.onPlan = { [weak self] list in self?.planArrived(list) }
    lens.onMemory = { [weak self] list in self?.memoryArrived(list) }
    lens.onTrouble = { [weak self] text in self?.problem = text }
    lens.onRoute = { [weak self] route in
      if route == 2 { self?.mobileDataAt = Date() }
    }
    lens.allowMobileData = mobileDataBackup

    whisperer.onSpeakingChanged = { [weak self] speaking in self?.speakingChanged(speaking) }

    let meter = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.readMeter() }
    }
    RunLoop.main.add(meter, forMode: .common)
    self.meter = meter

    let dayTimer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshDay() }
    }
    RunLoop.main.add(dayTimer, forMode: .common)
    self.dayTimer = dayTimer
  }

  // MARK: - The lens and its brain

  private var macURL: URL? {
    if !macAddress.isEmpty, let url = URL(string: macAddress), url.scheme == "https" || url.scheme == "http" {
      return url
    }
    #if targetEnvironment(simulator)
    // In the Simulator the Mac's own brain is right next door, and lends its key with no setup.
    return URL(string: "http://localhost:8787")
    #else
    return nil
    #endif
  }

  private func loadLens() {
    lensReady = false
    lens.apiKey = apiKey
    lens.macURL = macURL
    lens.macCode = macCode
    if brainPlace == .mac, let url = macURL {
      brainNote = "Thinking on your Mac"
      lens.loadRemote(url, code: macCode)
    } else {
      if brainPlace == .mac {
        problem = "No Mac is linked yet. Scan code B on the Mac’s setup page, or choose “On this iPhone”."
      }
      brainNote = !apiKey.isEmpty ? "Thinking on this iPhone" : (macURL != nil ? "Thinking on this iPhone, with your Mac’s key" : "No model key yet")
      lens.loadLocal()
    }
  }

  private func lensCameUp(_ place: String) {
    lensReady = true
    lens.call("setHost", [["ears": isListening ? ears.lensName : "none"]])
    refreshDay()
  }

  private func lensChanged(_ body: [String: Any]) {
    phase = body["phase"] as? String ?? phase
    lensListening = body["listening"] as? Bool ?? lensListening
    view = body["view"] as? String ?? view
    if let text = body["plain"] as? [String: Any] {
      plain = PlainLens(
        title: text["title"] as? String ?? "",
        sub: text["sub"] as? String ?? "",
        body: text["body"] as? String ?? "",
        say: text["say"] as? String ?? ""
      )
    }
    spokenLens = [plain.title, plain.sub, plain.body].filter { !$0.isEmpty }.joined(separator: ". ")

    let fast = body["fastMs"] as? Double ?? 0
    let deep = body["deepMs"] as? Double ?? 0
    var parts: [String] = []
    if fast > 0 { parts.append(String(format: "headline %.1f s", fast / 1000)) }
    if deep > 0 { parts.append(String(format: "picture %.1f s", deep / 1000)) }
    if Date().timeIntervalSince(mobileDataAt) < 30 { parts.append("via mobile data") }
    modelNote = parts.joined(separator: " · ")
    modelError = body["error"] as? String ?? ""

    pushToGlasses()
    whisperIfUseful()
  }

  /// Sends the current frame to the glasses' display, as a picture of the lens or as plain text.
  private func pushToGlasses() {
    guard showOnGlasses, glasses.hasSession, !menuOnGlasses else { return }
    let words = plain
    // Behind another app or with the screen locked the lens is not drawn, so there is no picture to take.
    let lensIsDrawn = UIApplication.shared.applicationState != .background
    pushCount += 1
    let mine = pushCount
    // Words only because the link was slow: after a minute the smallest picture gets another try.
    if wordsBecauseSlow, Date().timeIntervalSince(wordsSince) > 60 {
      wordsBecauseSlow = false
      frameSide = 300
      slowFrames = 0
      quickFrames = 0
    }
    if plainOnGlasses || wordsBecauseSlow || !lensIsDrawn {
      glasses.show(title: words.title, sub: words.sub, body: words.body)
      return
    }
    let side = frameSide
    Task { @MainActor [weak self] in
      // The page gets a moment to finish painting: a picture taken in the middle of a change
      // can catch half of it. Changes that follow each other at once become one frame.
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard let self, mine == self.pushCount else { return }
      self.lens.snapshot(side: side) { [weak self] image in
        // A newer frame is already on its way: this one is out of date.
        guard let self, mine == self.pushCount else { return }
        if let image {
          self.glasses.show(frame: image)
        } else {
          self.glasses.show(title: words.title, sub: words.sub, body: words.body)
        }
      }
    }
  }

  /// The link to the glasses carries only so much. Two slow pictures in a row and the next
  /// ones are smaller; if the smallest is still slow, the glasses get words instead.
  /// It works the other way too: once pictures go through quickly again, the next ones are
  /// sharper, one step at a time.
  private func frameTook(_ milliseconds: Int) {
    if milliseconds > 1500 { slowFrames += 1 } else { slowFrames = 0 }
    if milliseconds < 600 { quickFrames += 1 } else { quickFrames = 0 }
    if slowFrames >= 2 {
      slowFrames = 0
      quickFrames = 0
      // That size was too much for the link: wait longer before trying it again.
      quickNeeded = min(40, quickNeeded * 2)
      if frameSide > 420 {
        frameSide = 420
      } else if frameSide > 300 {
        frameSide = 300
      } else {
        wordsBecauseSlow = true
        wordsSince = Date()
      }
      return
    }
    if quickFrames >= quickNeeded, frameSide < 600 {
      quickFrames = 0
      frameSide = frameSide < 420 ? 420 : 600
    }
  }

  /// Asks the model one tiny question over mobile data only, so the fallback can be checked ahead of time.
  func checkMobileData() {
    mobileDataCheck = "Asking over mobile data…"
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.lens.apiKey = self.apiKey
      self.mobileDataCheck = await self.lens.tryMobileData()
    }
  }

  /// Back to the full picture, for a fresh try.
  private func sharpAgain() {
    frameSide = 600
    wordsBecauseSlow = false
    slowFrames = 0
    quickFrames = 0
    quickNeeded = 5
  }

  // MARK: - On the glasses, by hand

  /// A pinch of the band (or a tap on the touchpad) while the lens is up opens a short menu
  /// on the glasses themselves, so the phone can stay where it is.
  private func openGlassesMenu() {
    guard glasses.hasSession, !menuOnGlasses else { return }
    menuOnGlasses = true
    menuTurn += 1
    let mine = menuTurn
    var choices: [GlassesLink.Choice] = []
    if isListening {
      choices.append(GlassesLink.Choice(id: "look", label: "Look", icon: .eye, main: true))
      choices.append(GlassesLink.Choice(id: "end", label: "End talk", icon: .checkmark))
      if lensListening {
        choices.append(GlassesLink.Choice(id: "pause", label: "Pause", icon: .speechBubbleOff))
      } else {
        choices.append(GlassesLink.Choice(id: "resume", label: "Resume", icon: .speechBubble))
      }
    } else {
      choices.append(GlassesLink.Choice(id: "listen", label: "Listen", icon: .speechBubble, main: true))
      choices.append(GlassesLink.Choice(id: "brief", label: "Brief me", icon: .calendar))
    }
    choices.append(GlassesLink.Choice(id: "back", label: "Back", icon: .arrowULeft))
    glasses.showMenu(title: "Aside", note: statusLine, choices: choices)
    // A menu nobody answers goes away by itself, and the lens comes back.
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard let self, self.menuOnGlasses, mine == self.menuTurn else { return }
      self.closeGlassesMenu()
    }
  }

  private func closeGlassesMenu() {
    menuOnGlasses = false
    lens.call("redraw")
  }

  private func chose(_ id: String) {
    closeGlassesMenu()
    switch id {
    case "look": look()
    case "end": endConversation()
    case "pause": lens.call("setListening", [false])
    case "resume": lens.call("setListening", [true])
    case "listen": start()
    case "brief": briefNow()
    default: break
    }
  }

  /// With glasses in reach and nothing running, the lens still stands by on their display.
  private func standOnGlasses(after seconds: Double) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard let self, self.showOnGlasses, self.glasses.hasDevice, !self.glasses.hasSession,
        !self.isListening, !self.isSampling
      else { return }
      self.glasses.start(camera: false, audio: false, speech: false, display: true)
    }
  }

  // MARK: - The stage

  /// Turns the screen sideways for the stage and upright again afterwards.
  private func turnScreen() {
    let sideways = showStage
    AppDelegate.orientations = sideways ? .landscape : .portrait
    UIApplication.shared.isIdleTimerDisabled = sideways || isListening || isSampling
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: sideways ? .landscapeRight : .portrait))
    scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
  }

  // MARK: - Listening

  func toggle() {
    if isSampling {
      stopSample()
    } else if isListening {
      stop()
    } else {
      start()
    }
  }

  func start() {
    guard !isListening, !isStarting else { return }
    if isSampling { stopSample() }
    problem = ""
    isStarting = true
    Task { @MainActor in
      defer { self.isStarting = false }
      guard await Permissions.speech() else {
        self.problem = "Aside needs Speech Recognition to follow what is said. Allow it in the iPhone’s Settings, under Aside."
        return
      }
      guard await Permissions.microphone() else {
        self.problem = "Aside needs the microphone permission. Allow it in the iPhone’s Settings, under Aside."
        return
      }
      self.begin()
    }
  }

  private func begin() {
    if ears.needsGlassesSession, !glasses.hasDevice {
      problem = glasses.isRegistered
        ? "No glasses in reach. Unfold them, put them on and try again."
        : "Connect your glasses first. To try Aside without them, pick “This iPhone” under Settings."
      return
    }

    let sink = transcriber
    switch ears {
    case .glassesStream:
      if glasses.usingMock {
        // Practice glasses have no microphones, so the phone's stands in for them.
        guard transcriber.start(language: language) else { return }
        do {
          microphoneName = try phoneAudio.start(.phone) { buffer in sink.append(buffer) }
        } catch {
          transcriber.stop()
          problem = error.localizedDescription
          return
        }
        glasses.start(camera: true, audio: false, speech: false, display: showOnGlasses)
      } else {
        guard transcriber.start(language: language) else { return }
        glasses.audioSink.setHandler { buffer in sink.append(buffer) }
        microphoneName = "Glasses microphones"
        glasses.start(camera: true, audio: true, speech: false, display: showOnGlasses)
      }

    case .glassesSpeech:
      microphoneName = "Glasses speech"
      glasses.start(camera: cameraForLook, audio: false, speech: true, display: showOnGlasses)

    case .glassesBluetooth, .phone:
      guard transcriber.start(language: language) else { return }
      do {
        let source: PhoneAudio.Source = ears == .phone ? .phone : .glassesBluetooth
        microphoneName = try phoneAudio.start(source) { buffer in sink.append(buffer) }
      } catch {
        transcriber.stop()
        problem = error.localizedDescription
        return
      }
      // The glasses are optional here: used for the display and the camera when they are around.
      if (showOnGlasses || cameraForLook) && glasses.hasDevice {
        glasses.start(camera: cameraForLook, audio: false, speech: false, display: showOnGlasses)
      }
    }

    isListening = true
    lastBufferCount = 0
    quietTicks = 0
    audioFlowing = false
    if ears == .glassesSpeech {
      speechNote = ""
    } else {
      // iOS turns speech into text on the phone itself when it can for this language, and says when it cannot.
      speechNote = transcriber.onDevice ? "turned into text on this iPhone" : "turned into text by Apple’s dictation service"
    }
    lens.call("setListening", [true])
    lens.call("setHost", [["ears": ears.lensName]])
    UIApplication.shared.isIdleTimerDisabled = true
  }

  func stop() {
    guard isListening else { return }
    transcriber.stop()          // hands over the last words while we are still listening
    isListening = false
    phoneAudio.stop()
    glasses.audioSink.setHandler(nil)
    glasses.stop()
    whisperer.hush()
    hearing = ""
    level = 0
    audioFlowing = false
    lens.call("end")
    lens.call("setHost", [["ears": "none"]])
    UIApplication.shared.isIdleTimerDisabled = showStage
    standOnGlasses(after: 1.5)
    standOnGlasses(after: 4)
  }

  // MARK: - The sample explanation

  /// Plays a short pitch into Gist as if someone were saying it, at speaking pace. For showing
  /// Gist when the room is too loud to listen, and for trying it with nothing connected.
  func playSample() {
    if isListening { stop() }
    sampleRun += 1
    let run = sampleRun
    isSampling = true
    problem = ""
    hearing = ""
    lens.call("setListening", [true])
    lens.call("setHost", [["ears": "replay"]])
    if showOnGlasses, glasses.hasDevice, !glasses.hasSession {
      glasses.start(camera: false, audio: false, speech: false, display: true)
    }
    UIApplication.shared.isIdleTimerDisabled = true

    let sentences = AppModel.sampleSentences
    Task { @MainActor in
      for sentence in sentences {
        let words = Double(sentence.split(separator: " ").count)
        try? await Task.sleep(nanoseconds: UInt64(words / 165.0 * 60.0 * 1_000_000_000.0))
        guard self.isSampling, self.sampleRun == run else { return }
        self.lastHeard = sentence
        self.lens.call("heard", [sentence])
      }
      // Leave the last frame up for a moment, then wrap up the way a real conversation would.
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard self.isSampling, self.sampleRun == run else { return }
      self.lens.call("end")
      try? await Task.sleep(nanoseconds: 15_000_000_000)
      guard self.isSampling, self.sampleRun == run else { return }
      self.finishSample()
    }
  }

  func stopSample() {
    guard isSampling else { return }
    lens.call("end")
    finishSample()
  }

  private func finishSample() {
    isSampling = false
    sampleRun += 1
    glasses.stop()
    lens.call("setHost", [["ears": "none"]])
    UIApplication.shared.isIdleTimerDisabled = showStage
    standOnGlasses(after: 1.5)
    standOnGlasses(after: 4)
  }

  private func restartIfListening() {
    guard isListening else { return }
    stop()
    start()
  }

  private func glassesLeft() {
    guard isListening, ears.needsGlassesSession else { return }
    let reason = glasses.lastError
    stop()
    problem = reason.isEmpty
      ? "The glasses ended the session. That happens when they are folded or another app takes over. Start again when ready."
      : reason
  }

  private func heard(_ text: String) {
    guard isListening, Date() >= deafUntil else { return }
    lastHeard = text
    hearing = ""
    lens.call("heard", [text])
  }

  private func glassesSaid(_ text: String, isFinal: Bool) {
    guard isListening, ears == .glassesSpeech else { return }
    if isFinal {
      heard(text)
    } else {
      hearing = text
    }
  }

  private func readMeter() {
    let (peak, count) = transcriber.takeLevel()
    if abs(level - peak) > 0.004 { level = peak }
    guard isListening, ears != .glassesSpeech else { return }
    if count != lastBufferCount {
      lastBufferCount = count
      quietTicks = 0
      if !audioFlowing { audioFlowing = true }
    } else {
      quietTicks += 1
      if quietTicks > 12, audioFlowing { audioFlowing = false }
    }
  }

  // MARK: - Looking

  /// Asks the glasses for a photo of what the wearer is looking at, and reads it.
  func look() {
    guard isListening else {
      problem = "Start listening first, then look."
      return
    }
    if !glasses.capturePhoto() {
      problem = "Looking needs the glasses’ camera. Use “Glasses microphones” as the ears, or turn on “Keep the camera ready” in Settings."
    }
  }

  private func sawPhoto(_ data: Data) {
    guard let image = UIImage(data: data) else { return }
    let longest = max(image.size.width, image.size.height)
    var small = image
    if longest > 1024 {
      let scale = 1024 / longest
      let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
    }
    guard let jpeg = small.jpegData(compressionQuality: 0.6) else { return }
    lens.call("look", [jpeg.base64EncodedString()])
  }

  // MARK: - Speaking (for glasses with no display)

  private func whisperIfUseful() {
    guard whisper, isListening, !plain.say.isEmpty, plain.say != lastSaid else { return }
    let urgent = view == "turn"
    guard urgent || Date().timeIntervalSince(lastSaidAt) > 12 else { return }
    lastSaid = plain.say
    lastSaidAt = Date()
    whisperer.say(plain.say, language: language)
  }

  private func speakingChanged(_ speaking: Bool) {
    // Gist must not hear itself: nothing is taken in while it speaks, or for a moment after.
    if speaking {
      transcriber.setMuted(true)
      deafUntil = Date.distantFuture
    } else {
      deafUntil = Date().addingTimeInterval(0.7)
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 700_000_000)
        self.transcriber.setMuted(false)
      }
    }
  }

  // MARK: - Conversation controls

  func endConversation() {
    lens.call("end")
  }

  func briefNow() {
    if events.isEmpty {
      problem = useCalendar
        ? "Nothing else is on your calendar today."
        : "Turn on “Use my calendar” in Settings, or add a practice event there."
      return
    }
    lens.call("briefNow")
  }

  func forgetEverything() {
    lens.call("forget")
    talks = []
    dayReader.cancelReminders()
    refreshDay()
  }

  // MARK: - The day

  /// The app is in front again: the day may have moved on, and the glasses get the drawn lens back.
  func cameToFront() {
    refreshDay()
    lens.call("redraw")
  }

  func refreshDay() {
    guard lensReady else { return }
    guard useCalendar else {
      sendDay(practiceEvents)
      return
    }
    Task { @MainActor in
      guard await self.dayReader.requestAccess() else {
        self.problem = "Aside cannot read your calendar. Allow it in the iPhone’s Settings, or turn “Use my calendar” off."
        self.sendDay(self.practiceEvents)
        return
      }
      self.sendDay(self.dayReader.upcoming() + self.practiceEvents)
    }
  }

  private func sendDay(_ entries: [CalendarEntry]) {
    let now = Date()
    let list: [[String: Any]] = entries.filter { $0.end > now }.map { entry -> [String: Any] in
      return [
        "id": entry.id,
        "title": entry.title,
        "start": (entry.start.timeIntervalSince1970 * 1000).rounded(),
        "end": (entry.end.timeIntervalSince1970 * 1000).rounded(),
        "location": entry.place,
        "notes": entry.notes,
      ]
    }
    lens.call("setDay", [list])
    if list.isEmpty {
      events = []
    } else {
      lens.call("planDay")
    }
  }

  /// A made-up event twelve minutes from now, so the brief can be shown without touching a real calendar.
  func addPracticeEvent() {
    let start = Date().addingTimeInterval(12 * 60)
    practiceEvents = [
      CalendarEntry(
        id: "practice-\(Int(start.timeIntervalSince1970))",
        title: "Pitch feedback with the Meta mentors",
        start: start,
        end: start.addingTimeInterval(30 * 60),
        place: "Meta booth",
        notes: "Show the glasses demo. Ask about display sleep and how far the microphones hear."
      )
    ]
    refreshDay()
  }

  private func planArrived(_ list: [[String: Any]]) {
    events = list.compactMap { item -> DayEvent? in
      guard let id = item["id"] as? String, let title = item["title"] as? String, let start = item["start"] as? Double else { return nil }
      return DayEvent(
        id: id,
        title: title,
        start: Date(timeIntervalSince1970: start / 1000),
        place: item["where"] as? String ?? "",
        prep: item["prep"] as? [String] ?? []
      )
    }
    let reminders = events.map { Reminder(id: $0.id, title: $0.title, start: $0.start, prep: $0.prep) }
    let reader = dayReader
    Task { await reader.schedule(reminders) }
  }

  private func memoryArrived(_ list: [[String: Any]]) {
    talks = list.enumerated().map { index, item -> PastTalk in
      let at = item["at"] as? Double ?? 0
      return PastTalk(
        id: "\(Int(at))-\(index)",
        title: item["title"] as? String ?? "Conversation",
        points: item["points"] as? [String] ?? [],
        actions: item["actions"] as? [String] ?? [],
        open: item["open"] as? String ?? "",
        at: Date(timeIntervalSince1970: at / 1000)
      )
    }
    // What was just agreed belongs in the next brief.
    if !events.isEmpty { lens.call("planDay") }
  }

  // MARK: - Practice glasses

  private func applyPracticeGlasses() {
    if isListening { stop() }
    if practiceGlasses {
      glasses.useMockGlasses()
    } else {
      glasses.dropMockGlasses()
    }
  }

  // MARK: - Links that open the app

  /// Two kinds of link open Gist: Meta AI coming back after an approval, and the Mac's code B.
  func open(_ url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let items = components.queryItems ?? []
    if items.contains(where: { $0.name == "metaWearablesAction" }) {
      glasses.handle(url: url)
      return
    }
    guard components.host == "connect" else { return }
    let address = items.first(where: { $0.name == "brain" })?.value ?? ""
    let code = items.first(where: { $0.name == "k" })?.value ?? ""
    guard let target = URL(string: address), target.scheme == "https", let host = target.host else {
      problem = "That code is not an Aside link."
      return
    }
    pendingLinkAddress = address
    pendingLinkCode = code
    linkPromptText = "Aside will use the Mac at \(host). When the Mac does the thinking, the words Aside hears are sent there as text. Only link a Mac you run yourself."
    showLinkPrompt = true
  }

  func acceptLink() {
    macAddress = pendingLinkAddress
    macCode = pendingLinkCode
    pendingLinkAddress = ""
    pendingLinkCode = ""
    problem = ""
    loadLens()
  }

  func declineLink() {
    pendingLinkAddress = ""
    pendingLinkCode = ""
  }

  func forgetLink() {
    macAddress = ""
    macCode = ""
    if brainPlace == .mac {
      brainPlace = .phone     // reloads the lens
    } else {
      loadLens()
    }
  }

  // MARK: - Lines for the views

  var statusLine: String {
    if isStarting { return "Starting" }
    if !isListening, !isSampling { return lensReady ? "Not listening" : "Loading the lens" }
    switch view {
    case "turn": return "Your turn"
    case "recap": return "Conversation ended"
    case "brief": return "Briefing you"
    case "live": return "Following"
    default: return "Listening for a conversation"
    }
  }

  var sourceLine: String {
    if isSampling { return "Playing a sample explanation" }
    guard isListening else { return "" }
    if ears == .glassesStream, glasses.usingMock { return "Practice glasses: the iPhone’s microphone stands in" }
    if ears == .glassesSpeech { return "Glasses speech: \(glasses.speechText)" }
    let flow = audioFlowing ? "sound arriving" : "no sound yet"
    return speechNote.isEmpty ? "\(microphoneName): \(flow)" : "\(microphoneName): \(flow), \(speechNote)"
  }

  var mainButtonTitle: String {
    if isSampling { return "Stop the sample" }
    return isListening ? "Stop listening" : "Start listening"
  }

  var heardLine: String {
    if !hearing.isEmpty { return hearing }
    return lastHeard
  }

  var glassesLine: String {
    if glasses.usingMock { return "Practice glasses (simulated Meta Ray-Ban Display)" }
    if !glasses.isRegistered { return "Not connected" }
    if !glasses.hasDevice { return "Connected to Meta AI. No glasses in reach." }
    return glasses.deviceHasDisplay ? "\(glasses.deviceName), with display" : "\(glasses.deviceName), no display"
  }

  var glassesDetail: String {
    guard glasses.hasSession else { return "" }
    var parts = ["session \(glasses.sessionText)"]
    if glasses.streamText != "off" { parts.append("camera stream \(glasses.streamText)") }
    if glasses.speechText != "off" { parts.append("speech \(glasses.speechText)") }
    if glasses.displayText != "off" {
      var line = "display \(glasses.displayText), \(glasses.framesSent) frames"
      if glasses.lastSendMs > 0 { line += ", last took \(glasses.lastSendMs) ms" }
      if wordsBecauseSlow {
        line += " (words only: pictures were arriving too slowly)"
      } else if frameSide < 600 {
        line += " (lighter picture, \(frameSide) px)"
      }
      parts.append(line)
    }
    if menuOnGlasses { parts.append("menu open on the glasses") }
    return parts.joined(separator: " · ")
  }

  var needsGlassesConnect: Bool {
    !glasses.usingMock && !glasses.isRegistered
  }

  var linkLine: String {
    guard let url = macURL, let host = url.host else { return "No Mac linked. Scan code B on the Mac’s setup page with the Camera app." }
    return "Linked to \(host)"
  }
}
