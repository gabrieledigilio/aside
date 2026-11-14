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
    case .phone: return "This iPhone’s microphone"
    }
  }

  var detail: String {
    switch self {
    case .glassesStream:
      return "The glasses’ own microphones, carried by their camera stream. They sit next to your mouth, so the person talking to you arrives much quieter than you do; Aside lifts quiet voices to make up for it. The capture light on the glasses stays on, which also tells the other person."
    case .glassesSpeech:
      return "The glasses turn speech into text themselves and send only the text. Lightest on battery. Tuned for the wearer’s voice, so it may miss the other person."
    case .glassesBluetooth:
      return "The glasses’ microphone the way a headset sends it. Works on every pair, lower quality, closest to the wearer."
    case .phone:
      return "The iPhone’s microphone. For a loud room, or a speaker who is far from you: put the phone near them. The glasses still show the lens. Also the way to try Aside with no glasses at hand."
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
  @Published var showOnGlasses: Bool { didSet { store.set(showOnGlasses, forKey: "showOnGlasses"); showOnGlassesChanged() } }
  @Published var plainOnGlasses: Bool { didSet { store.set(plainOnGlasses, forKey: "plainOnGlasses"); sharpAgain(); lens.call("redraw") } }
  @Published var mobileDataBackup: Bool { didSet { store.set(mobileDataBackup, forKey: "mobileDataBackup"); lens.allowMobileData = mobileDataBackup } }
  @Published var cameraForLook: Bool { didSet { store.set(cameraForLook, forKey: "cameraForLook"); restartIfListening() } }
  @Published var lookByItself: Bool { didSet { store.set(lookByItself, forKey: "lookByItself"); looksBreakTheStream = false } }
  @Published var returnToGlasses: Bool { didSet { store.set(returnToGlasses, forKey: "returnToGlasses") } }
  /// When listening stops, only the camera stream stops: the session and the display stay up.
  @Published var keepGlassesSession: Bool { didSet { store.set(keepGlassesSession, forKey: "keepGlassesSession") } }
  @Published var bluetoothWhenStreamFails: Bool { didSet { store.set(bluetoothWhenStreamFails, forKey: "bluetoothWhenStreamFails") } }
  /// Quiet voices are lifted and the wearer's own voice held down before the words are recognised.
  @Published var liftQuietVoices: Bool { didSet { store.set(liftQuietVoices, forKey: "liftQuietVoices"); transcriber.setLifting(liftQuietVoices) } }
  /// Names and unusual words to listen for, separated by commas. Kept on this phone only.
  @Published var listenFor: String { didSet { store.set(listenFor, forKey: "listenFor"); transcriber.setWordsToExpect(wordsToListenFor) } }
  /// A trial: ask the glasses for their two-channel sound.
  @Published var stereoMicrophones: Bool { didSet { store.set(stereoMicrophones, forKey: "stereoMicrophones"); stereoChanged() } }
  @Published var buttonsOnGlasses: Bool { didSet { store.set(buttonsOnGlasses, forKey: "buttonsOnGlasses"); buttonsChanged() } }
  /// During a conversation the buttons stay out of the way, so the lens keeps the whole display;
  /// a pinch brings them up as a short menu.
  @Published var barOnPinch: Bool { didSet { store.set(barOnPinch, forKey: "barOnPinch"); buttonsChanged() } }
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
  /// The last few seconds of sound as a row of bars, and how much it is being lifted.
  @Published var levelTrace = ""
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
  /// How many buffers the transcriber had taken in when this listening session began.
  private var buffersAtStart = 0
  private var lastSoundAt = Date.distantPast
  private var quietTicks = 0
  /// The loudest sample of each quarter second, newest last, for the row of bars on screen.
  private var levelHistory: [Float] = []
  /// For the last minute, in quarter seconds: how much time passed and how much sound arrived.
  /// The difference is sound that went missing on the way from the glasses.
  private var clockHistory: [Double] = []
  private var soundHistory: [Double] = []
  private var lastTickAt = Date.distantPast
  private var lastSecondsHeard: Double = 0
  /// Quarter seconds this listening session has waited for a first sound from the glasses,
  /// with Aside in front and nothing paused. However the stream fails, the wait has an end.
  private var waitedForSound = 0
  /// The same two sums since the last photo was asked for.
  private var clockSinceLook: Double = 0
  private var soundSinceLook: Double = 0
  /// When the two-channel sound was last asked for, and how many buffers had arrived by then.
  private var stereoAskedAt = Date.distantPast
  private var buffersAtStereo = 0
  /// When looking by itself may be tried again after the glasses sent no photos.
  private var looksRetryAt: Date?
  private var looksRetryWait: TimeInterval = 45
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
  /// How many photos from the glasses have been handed to the brain since the app started.
  @Published var photosRead = 0
  /// When a photo was last asked for and has not arrived yet.
  private var lookAskedAt: Date?
  /// When listening last started, and whether the wearer has been told that no sound is arriving.
  private var listeningSince = Date.distantPast
  private var saidNoSound = false
  /// The camera stream would not start, so this session listens through the glasses' Bluetooth microphone.
  private var onBluetoothInstead = false
  /// When the glasses last closed Aside while it was standing by, and how often in a row.
  private var lastClosedAt = Date.distantPast
  private var quickClosures = 0
  /// The session is being ended by Aside itself so that it can start afresh at once.
  private var endedOnPurpose = false
  /// The problem on screen says that the glasses left; it clears itself when they return.
  private var problemIsAboutLeaving = false
  /// How often the display has been brought back during this listening session.
  private var displayReturns = 0
  private var lastDisplayRescue = Date.distantPast
  /// When a look was last started, by hand or by itself.
  private var lastLookAsk = Date.distantPast
  /// The photo on its way was not asked for: it is read quietly.
  private var lookIsUnasked = false
  /// Unasked looks that went wrong in a row, and whether they have been stopped for this session.
  private var unaskedLookTroubles = 0
  private var unaskedLooksPaused = false
  /// An unasked look took the microphones down. It would do so again, so until the app is
  /// opened afresh (or the setting is switched off and on) Aside only looks when asked.
  private var looksBreakTheStream = false
  private var lastUnaskedLookAt = Date.distantPast
  /// The camera would not start on the session kept from before, and a fresh session was tried.
  private var triedFreshSession = false
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
  /// The ears the lens was last told about.
  private var lensEars = "none"
  /// The lens alone, full screen and sideways, for a phone that is mirrored onto a big screen.
  @Published var showStage = false { didSet { if showStage != oldValue { turnScreen() } } }

  /// For working on Aside with nobody at the phone: steps the app runs by itself after launch,
  /// on the practice glasses, with the screen kept awake. Empty in the version that ships.
  static let autopilot: [String] = []

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
    // On today's glasses every photo stops the microphones for three or four seconds, so
    // looking by itself is off unless it is switched on after that was known (14 Nov, evening).
    if !saved.bool(forKey: "lookByItselfAsked2") {
      saved.set(true, forKey: "lookByItselfAsked2")
      saved.set(false, forKey: "lookByItself")
    }
    lookByItself = saved.bool(forKey: "lookByItself")
    returnToGlasses = saved.object(forKey: "returnToGlasses") as? Bool ?? true
    keepGlassesSession = saved.object(forKey: "keepGlassesSession") as? Bool ?? true
    buttonsOnGlasses = saved.object(forKey: "buttonsOnGlasses") as? Bool ?? true
    barOnPinch = saved.bool(forKey: "barOnPinch")
    bluetoothWhenStreamFails = saved.object(forKey: "bluetoothWhenStreamFails") as? Bool ?? true
    liftQuietVoices = saved.object(forKey: "liftQuietVoices") as? Bool ?? true
    listenFor = saved.string(forKey: "listenFor") ?? ""
    // Tried on Meta Ray-Ban Display on 14 Nov: asked for two channels, the glasses send no
    // sound at all. The switch is gone from Settings; the code stays for a later SDK.
    saved.set(false, forKey: "stereoMicrophones")
    stereoMicrophones = false
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

    transcriber.onSegment = { [weak self] text, who, number in self?.heard(text, who: who, number: number) }
    transcriber.onRelabel = { [weak self] labels in
      // Keys go across as text: JSON has no numbered keys.
      var named: [String: String] = [:]
      for (number, who) in labels { named[String(number)] = who }
      self?.lens.call("relabel", [named])
    }
    transcriber.onPartial = { [weak self] text in self?.hearing = text }
    transcriber.onProblem = { [weak self] text in self?.problem = text }

    phoneAudio.onLost = { [weak self] in
      guard let self, self.isListening else { return }
      self.stop()
      self.problem = "The glasses’ microphone went away. Start again when they are back on."
    }

    glasses.onTranscript = { [weak self] text, isFinal in self?.glassesSaid(text, isFinal: isFinal) }
    glasses.onPhoto = { [weak self] data in self?.sawPhoto(data) }
    glasses.onPhotoFailed = { [weak self] in self?.photoFailed() }
    glasses.onTap = { [weak self] in self?.openGlassesMenu() }
    glasses.onChoice = { [weak self] id in self?.chose(id) }
    // Glasses that come into reach get the lens on standby, so the first pinch can come from the band.
    glasses.$hasDevice
      .removeDuplicates()
      .sink { [weak self] inReach in
        guard let self, inReach else { return }
        // They are back: the note about them leaving has done its job.
        if self.problemIsAboutLeaving, !self.isListening {
          self.problemIsAboutLeaving = false
          self.problem = ""
        }
        self.standOnGlasses(after: 0.8)
      }
      .store(in: &bag)
    glasses.onDisplayReady = { [weak self] in self?.lens.call("redraw") }
    glasses.onFrameTiming = { [weak self] took in self?.frameTook(took) }
    glasses.onSessionEnded = { [weak self] in self?.glassesLeft() }
    glasses.onDisplayLost = { [weak self] in self?.displayLost() }
    glasses.onPaused = { [weak self] paused in self?.glassesPaused(paused) }
    glasses.onTooWarm = { [weak self] shuttingDown in self?.glassesTooWarm(shuttingDown) }
    glasses.onStereoRefused = { [weak self] in self?.stereoRefused() }
    glasses.stereoSound = stereoMicrophones
    transcriber.setLifting(liftQuietVoices)
    transcriber.setWordsToExpect(wordsToListenFor)
    if !AppModel.autopilot.isEmpty { traceGlasses() }

    lens.onReady = { [weak self] place in self?.lensCameUp(place) }
    lens.onState = { [weak self] body in self?.lensChanged(body) }
    lens.onLook = { [weak self] in
      // Someone said "as you can see": the brain asks for a look of its own accord.
      guard let self else { return }
      self.lookIsUnasked = false
      self.lastLookAsk = Date()
      _ = self.glasses.capturePhoto()
    }
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
    tellLens(ears: isListening ? ears.lensName : "none")
    refreshDay()
    if !autopilotBegan {
      autopilotBegan = true
      runAutopilot()
    }
  }

  // MARK: - Autopilot (tests with nobody at the phone)

  /// The step the autopilot is on, shown on screen so it can be read from a mirror of the phone.
  @Published var autopilotNote = ""
  /// What the glasses link did during the autopilot's run, newest last.
  @Published var autopilotTrace: [String] = []
  private let launchedAt = Date()
  private var lastWarmAt = Date.distantPast
  private var autopilotBegan = false

  private func runAutopilot() {
    let steps = AppModel.autopilot
    // A test run that was cut short may have left the wearer's memory put aside: bring it back.
    guard !steps.isEmpty else {
      lens.call("unstash")
      return
    }
    // The sample conversations of a test run must not push the wearer's own recaps out.
    lens.call("stash")
    Task { @MainActor [weak self] in
      for step in steps {
        guard let self else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        self.autopilotNote = step
        if !step.hasPrefix("wait") { self.trace("> \(step)") }
        let parts = step.split(separator: ":").map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        // The camera stays out of it until a "camera" step: iOS asks for it with an alert.
        case "practice": self.glasses.useMockGlasses(camera: false)
        case "camera": self.glasses.practiceCamera()
        case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(argument) ?? 1) * 1_000_000_000))
        case "sample": self.playSample()
        case "listen": self.start()
        case "stop": if self.isSampling { self.stopSample() } else { self.stop() }
        case "feed":
          for sentence in AppModel.sampleSentences.prefix(Int(argument) ?? AppModel.sampleSentences.count) {
            let words = Double(sentence.split(separator: " ").count)
            try? await Task.sleep(nanoseconds: UInt64(words / 165.0 * 60.0 * 1_000_000_000.0))
            guard self.isListening else { break }
            self.lastHeard = sentence
            self.lens.call("heard", [sentence])
          }
        case "tap": self.glasses.practiceTap()
        case "peek": self.barOnPinch = argument == "on"
        case "click": self.autopilotNote = "click \(argument): \(self.glasses.practiceClick(argument))"
        case "off": self.glasses.practicePower(false)
        case "on": self.glasses.practicePower(true)
        case "mobile": self.checkMobileData()
        case "stage": self.showStage = true
        case "unstage": self.showStage = false
        case "slide":
          if let file = Bundle.main.url(forResource: "practice-slide", withExtension: "jpg", subdirectory: "lens") {
            self.glasses.practicePhoto(file)
          } else {
            self.autopilotNote = "slide: file missing"
          }
        case "warm": self.glasses.practiceThermal(.critical)
        case "cool": self.glasses.practiceThermal(.none)
        case "doff": self.glasses.practiceWorn(false)
        case "don": self.glasses.practiceWorn(true)
        case "look": self.look()
        case "end": self.endConversation()
        default: break
        }
      }
      self?.autopilotNote = "done"
      self?.lens.call("unstash")
    }
  }

  /// Tells the lens which ears are in use, and whether the glasses carry the app's own buttons.
  private func tellLens(ears name: String) {
    lensEars = name
    let buttons = buttonsOnGlasses && showOnGlasses
    lens.call("setHost", [["ears": name, "buttons": buttons, "pinch": buttons && barOnPinch]])
  }

  /// A setting about the buttons on the glasses changed.
  private func buttonsChanged() {
    tellLens(ears: lensEars)
    lens.call("redraw")
  }

  /// True when the buttons belong under the lens right now.
  private var barShown: Bool {
    buttonsOnGlasses && !(barOnPinch && isListening && phase == "live")
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
    glasses.bar = barShown ? glassesBar() : []
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
          // Buttons under the lens leave it a wide, shorter space on the display.
          self.glasses.show(frame: self.glasses.bar.isEmpty ? image : AppModel.fitted(image))
        } else {
          self.glasses.show(title: words.title, sub: words.sub, body: words.body)
        }
      }
    }
  }

  /// The share of the display's height left to the lens when buttons sit under it.
  static let lensShareWithBar: CGFloat = 0.76

  /// The square lens, drawn smaller in the middle of a canvas shaped like the space above the
  /// buttons. Black is see-through on the glasses, so the margins do not show, and nothing is
  /// cut off or stretched whichever way the display fits a picture into that space.
  static func fitted(_ image: UIImage) -> UIImage {
    let side = image.size.width
    let canvas = CGSize(width: side, height: (side * lensShareWithBar).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(origin: .zero, size: canvas))
      let inner = canvas.height
      image.draw(in: CGRect(x: ((canvas.width - inner) / 2).rounded(), y: 0, width: inner, height: inner))
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

  /// The buttons under the lens on the glasses. They are real display buttons, so the band moves
  /// between them and a pinch presses one: Aside can be run without touching the phone.
  /// Only the main button carries an icon: the display draws any other button that has one as
  /// the icon alone, with no label.
  private func glassesBar() -> [GlassesLink.Choice] {
    guard isListening || isSampling else {
      return [
        GlassesLink.Choice(id: "listen", label: "Listen", icon: .speechBubble, main: true),
        GlassesLink.Choice(id: "brief", label: "Brief me", icon: nil),
      ]
    }
    // Look needs the glasses' camera, which only runs with the camera stream.
    let canLook = isListening && glasses.streamText != "off"
    var bar: [GlassesLink.Choice] = []
    if canLook {
      bar.append(GlassesLink.Choice(id: "look", label: "Look", icon: .eye, main: true))
    }
    if phase == "live" {
      bar.append(GlassesLink.Choice(id: "end", label: "End talk", icon: nil, main: !canLook))
      bar.append(GlassesLink.Choice(id: "stop", label: "Stop", icon: nil))
    } else {
      bar.append(GlassesLink.Choice(id: "stop", label: "Stop", icon: nil, main: !canLook))
    }
    return bar
  }

  /// A pinch of the band (or a tap on the touchpad) while the lens is up opens a short menu
  /// on the glasses themselves, so the phone can stay where it is.
  private func openGlassesMenu() {
    guard glasses.hasSession, !menuOnGlasses else { return }
    menuOnGlasses = true
    menuTurn += 1
    let mine = menuTurn
    var choices: [GlassesLink.Choice] = []
    if isListening {
      let canLook = glasses.streamText != "off"
      if canLook {
        choices.append(GlassesLink.Choice(id: "look", label: "Look", icon: .eye, main: true))
      }
      choices.append(GlassesLink.Choice(id: "end", label: "End talk", icon: nil, main: !canLook))
      choices.append(GlassesLink.Choice(id: "stop", label: "Stop", icon: nil))
    } else {
      choices.append(GlassesLink.Choice(id: "listen", label: "Listen", icon: .speechBubble, main: true))
      choices.append(GlassesLink.Choice(id: "brief", label: "Brief me", icon: nil))
    }
    choices.append(GlassesLink.Choice(id: "back", label: "Back", icon: nil))
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
    case "stop": if isSampling { stopSample() } else { stop() }
    case "brief": briefNow()
    default: break
    }
  }

  /// With glasses in reach and nothing running, the lens still stands by on their display.
  /// If the last session is still closing, the link opens the new one as soon as it has gone.
  private func standOnGlasses(after seconds: Double) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard let self, self.showOnGlasses, self.glasses.hasDevice, !self.isListening, !self.isSampling
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
      if glasses.usingMock, !AppModel.autopilot.isEmpty {
        // A test with nobody at the phone: no microphone is opened, the autopilot feeds the words.
        microphoneName = "Autopilot, no microphone"
        glasses.start(camera: true, audio: false, speech: false, display: showOnGlasses)
      } else if glasses.usingMock {
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

    // Only the glasses' own microphones, worn on the face, can tell voices apart by loudness.
    transcriber.setWornMicrophones(ears == .glassesStream && !glasses.usingMock)
    isListening = true
    listeningSince = Date()
    saidNoSound = false
    onBluetoothInstead = false
    endedOnPurpose = false
    unaskedLookTroubles = 0
    unaskedLooksPaused = false
    triedFreshSession = false
    displayReturns = 0
    looksRetryAt = nil
    looksRetryWait = 45
    levelHistory = []
    levelTrace = ""
    clockHistory = []
    soundHistory = []
    lastTickAt = Date.distantPast
    clockSinceLook = 0
    soundSinceLook = 0
    waitedForSound = 0
    // The transcriber counts buffers from the day it was made, so this session counts from here.
    buffersAtStart = transcriber.takeLevel().1
    lastBufferCount = buffersAtStart
    stereoAskedAt = Date()
    buffersAtStereo = buffersAtStart
    quietTicks = 0
    audioFlowing = false
    if ears == .glassesSpeech {
      speechNote = ""
    } else {
      // iOS turns speech into text on the phone itself when it can for this language, and says when it cannot.
      speechNote = transcriber.onDevice ? "turned into text on this iPhone" : "turned into text by Apple’s dictation service"
    }
    lens.call("setListening", [true])
    tellLens(ears: ears.lensName)
    UIApplication.shared.isIdleTimerDisabled = true
  }

  func stop() {
    guard isListening else { return }
    transcriber.stop()          // hands over the last words while we are still listening
    isListening = false
    onBluetoothInstead = false
    phoneAudio.stop()
    glasses.audioSink.setHandler(nil)
    // The display stays up, so the recap and then the standby lens are there at once, and the
    // next Listen needs no new session. (With the setting off, the session ends as it used to.)
    if keepGlassesSession { glasses.standBy() } else { glasses.stop() }
    whisperer.hush()
    hearing = ""
    level = 0
    audioFlowing = false
    lens.call("end")
    tellLens(ears: "none")
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
    displayReturns = 0
    problem = ""
    hearing = ""
    lens.call("setListening", [true])
    tellLens(ears: "replay")
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
    if keepGlassesSession { glasses.standBy() } else { glasses.stop() }
    tellLens(ears: "none")
    UIApplication.shared.isIdleTimerDisabled = showStage
    standOnGlasses(after: 1.5)
    standOnGlasses(after: 4)
  }

  private func restartIfListening() {
    guard isListening else { return }
    stop()
    start()
  }

  /// The lens was switched on or off for the glasses.
  private func showOnGlassesChanged() {
    if isListening {
      restartIfListening()
    } else if isSampling {
      return
    } else if showOnGlasses {
      standOnGlasses(after: 0.5)
    } else {
      // Nothing is running and the lens is not wanted there: the standby session ends.
      glasses.stop()
    }
  }

  private func glassesLeft() {
    let onPurpose = endedOnPurpose
    endedOnPurpose = false
    // The ears do not ride on this session (the Bluetooth microphone, the phone, a sample):
    // only the display did, so it is brought back and listening carries on.
    if isSampling || (isListening && (onBluetoothInstead || !ears.needsGlassesSession)) {
      guard displayReturns < 6 else { return }
      displayReturns += 1
      displayAgain(after: onPurpose ? 0.8 : 4)
      return
    }
    if isListening {
      let reason = glasses.lastError
      // A session that ends right after an unasked photo: the photo is the likely cause.
      if Date().timeIntervalSince(lastUnaskedLookAt) < 8 { looksBreakTheStream = true }
      stop()
      if !glasses.hasDevice {
        problem = "The glasses went out of reach, were folded or switched off, so Aside stopped listening. Put them back on and press Listen."
      } else if reason.isEmpty || reason == "Session ended by device" {
        problem = "The glasses ended the session. That happens when they are folded or another glasses app takes over. Press Listen to start again."
      } else {
        problem = "The glasses ended the session (\(reason)). Press Listen to start again."
      }
      problemIsAboutLeaving = true
      return
    }
    // Standing by, and something else took the display or the wearer closed Aside there. With
    // Meta's toolkit only the phone can put it back, so it returns by itself after a moment.
    // Closed three times in quick succession, it stays closed until asked for again.
    guard returnToGlasses else { return }
    if onPurpose {
      standOnGlasses(after: 1)
      return
    }
    let now = Date()
    quickClosures = now.timeIntervalSince(lastClosedAt) < 40 ? quickClosures + 1 : 0
    lastClosedAt = now
    guard quickClosures < 3 else { return }
    standOnGlasses(after: 8)
  }

  /// A tap on the glasses' touchpad pauses everything Aside does there: the display goes dark
  /// and the microphones stop. Another tap carries on. The phone says which it is.
  private func glassesPaused(_ paused: Bool) {
    if paused {
      problem = isListening
        ? "Paused from the glasses: Aside hears nothing until you tap the side of the glasses. (They also pause by themselves if you put them on after pressing Listen.)"
        : "Paused from the glasses. Tap the side of the glasses to bring the lens back."
      // If only the stream paused, the display still shows this.
      lens.call("tell", ["Paused: tap the glasses", 120000])
    } else {
      problem = ""
      listeningSince = Date()
      lens.call("tell", [isListening ? "Listening again" : "Back", 3000])
    }
  }

  /// The glasses say they are too warm. Their camera is what heats them, so Aside lets it go
  /// before the glasses cut the session themselves, and carries on listening through their
  /// Bluetooth microphone, with the lens still on the display.
  private func glassesTooWarm(_ shuttingDown: Bool) {
    guard Date().timeIntervalSince(lastWarmAt) > 20 else { return }
    lastWarmAt = Date()
    looksBreakTheStream = true      // no more photos by itself while the glasses are this warm
    guard isListening, ears == .glassesStream, !onBluetoothInstead else {
      lens.call("tell", ["Glasses are too warm", 6000])
      problem = "The glasses say they are too warm. Give them a minute folded, or keep sessions short."
      return
    }
    saidNoSound = true
    if bluetoothWhenStreamFails, !glasses.usingMock {
      listenOverBluetoothInstead()
      lens.call("tell", ["Glasses warm: camera off", 7000])
      problem = "The glasses say they are too warm, so Aside switched their camera off and is listening through their Bluetooth microphone. Looking is off until you start again."
    } else {
      lens.call("tell", ["Glasses are too warm", 6000])
      problem = "The glasses say they are too warm and may stop streaming. Fold them for a minute, or pick “Glasses Bluetooth mic” in Settings, which does not use the camera."
    }
  }

  /// For the autopilot: every change on the glasses link goes into a short running log on screen.
  private func traceGlasses() {
    glasses.$sessionText.removeDuplicates().sink { [weak self] text in self?.trace("session \(text)") }.store(in: &bag)
    glasses.$streamText.removeDuplicates().sink { [weak self] text in self?.trace("stream \(text)") }.store(in: &bag)
    glasses.$displayText.removeDuplicates().sink { [weak self] text in self?.trace("display \(text)") }.store(in: &bag)
    glasses.$lastError.removeDuplicates().sink { [weak self] text in if !text.isEmpty { self?.trace("error \(text)") } }.store(in: &bag)
    glasses.$hasDevice.removeDuplicates().sink { [weak self] there in self?.trace(there ? "glasses in reach" : "glasses gone") }.store(in: &bag)
    $problem.removeDuplicates().sink { [weak self] text in if !text.isEmpty { self?.trace("problem \(text.prefix(60))") } }.store(in: &bag)
  }

  private func trace(_ text: String) {
    let seconds = Int(Date().timeIntervalSince(launchedAt))
    autopilotTrace.append(String(format: "%3d %@", seconds, text))
    if autopilotTrace.count > 16 { autopilotTrace.removeFirst(autopilotTrace.count - 16) }
  }

  /// Frames keep failing though the display says it is on, and starting the display again did
  /// not help: its channel to the glasses has gone.
  private func displayLost() {
    guard Date().timeIntervalSince(lastDisplayRescue) > 30 else { return }
    lastDisplayRescue = Date()
    if isListening, ears.needsGlassesSession, !onBluetoothInstead {
      // The same session carries the microphones, and hearing comes first: it is left alone.
      problem = "The glasses’ display stopped answering. Aside is still listening. Press Stop, then Listen, to bring the display back."
      return
    }
    // Nothing else rides on this session, so it starts afresh; glassesLeft() puts the lens back.
    endedOnPurpose = true
    glasses.stop()
  }

  /// `who` is "me" when the words were the wearer's own, "them" when someone else's, and
  /// empty when the sound could not tell (see Transcriber.takeWho).
  private func heard(_ text: String, who: String = "", number: Int = 0) {
    guard isListening, Date() >= deafUntil else { return }
    lastHeard = who == "me" ? "You: \(text)" : who == "them" ? "Them: \(text)" : text
    hearing = ""
    lens.call("heard", [text, who, number])
  }

  private func glassesSaid(_ text: String, isFinal: Bool) {
    guard isListening, ears == .glassesSpeech else { return }
    if isFinal {
      heard(text)
    } else {
      hearing = text
    }
  }

  /// Sound from the glasses should arrive as fast as the clock runs. It comes in bursts, so
  /// one quiet quarter second means nothing; but over a minute, the seconds of sound that
  /// arrived should match the seconds that passed. What is missing was lost on the way (the
  /// link was busy, or the glasses stopped their microphones for a photo), and words said then
  /// never reached the phone. Kept for the last minute, so the screen can say so, and since
  /// the last photo, so a photo that costs sound is noticed.
  private func countHoles() {
    let heard = transcriber.secondsHeard()
    let now = Date()
    let passed = now.timeIntervalSince(lastTickAt)
    let arrived = heard - lastSecondsHeard
    lastTickAt = now
    lastSecondsHeard = heard
    let expected = ears == .glassesStream && !glasses.usingMock && !onBluetoothInstead
      && glasses.streamText == "streaming" && !glasses.isPaused && lastBufferCount != buffersAtStart
    // The first tick after a break has no sensible "time passed".
    guard expected, passed > 0, passed < 1.5 else { return }
    clockHistory.append(passed)
    soundHistory.append(arrived)
    if clockHistory.count > 240 {
      clockHistory.removeFirst(clockHistory.count - 240)
      soundHistory.removeFirst(soundHistory.count - 240)
    }
    clockSinceLook += passed
    soundSinceLook += arrived
  }

  /// Seconds of sound that went missing during the last minute (or since listening began).
  private var holeSeconds: Double {
    max(0, clockHistory.reduce(0, +) - soundHistory.reduce(0, +))
  }

  /// A row of bars for the last eight seconds of sound, as it arrived (before any lifting), so
  /// the wearer can see whether the other person's voice reaches the glasses at all. Each bar
  /// is a quarter of a second; a step up is twice as loud.
  private func drawLevelTrace(_ peak: Float) {
    levelHistory.append(peak)
    if levelHistory.count > 32 { levelHistory.removeFirst(levelHistory.count - 32) }
    let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    var row = ""
    for value in levelHistory {
      // -54 dB and below is the lowest bar, -12 dB and above the highest: 6 dB a step.
      let decibels = 20 * log10(max(value, 0.000_01))
      let step = Int(((decibels + 54) / 6).rounded(.down))
      row.append(bars[min(7, max(0, step))])
    }
    let now = Int((20 * log10(max(peak, 0.000_01))).rounded())
    let lift = transcriber.liftNow()
    var text = "\(row)  \(max(now, -99)) dB"
    if liftQuietVoices, abs(lift - 1) > 0.15 {
      text += lift >= 1 ? String(format: "  lifted ×%.0f", lift) : "  held down"
    }
    // Under a second is the bursts the sound arrives in, not a loss.
    let holes = holeSeconds
    if holes >= 1, clockHistory.count >= 40 { text += String(format: "  lost %.0f s/min", holes) }
    if text != levelTrace { levelTrace = text }
  }

  /// The names and words typed in Settings, as a list.
  private var wordsToListenFor: [String] {
    listenFor
      .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// The two-channel sound was switched on or off.
  private func stereoChanged() {
    glasses.stereoSound = stereoMicrophones
    stereoAskedAt = Date()
    buffersAtStereo = lastBufferCount
    guard isListening, ears == .glassesStream, !glasses.usingMock, !onBluetoothInstead else { return }
    glasses.soundFeedChanged()
  }

  /// The glasses said no to two channels outright; the stream has already started in mono.
  private func stereoRefused() {
    guard stereoMicrophones else { return }
    stereoMicrophones = false
    lens.call("tell", ["Stereo sound not available", 5000])
    problem = "These glasses would not give a two-channel sound feed, so Aside is using the usual one."
  }

  private func readMeter() {
    if !AppModel.autopilot.isEmpty { UIApplication.shared.isIdleTimerDisabled = true }
    lookIfDue()
    let (peak, count) = transcriber.takeLevel()
    if abs(level - peak) > 0.004 { level = peak }
    guard isListening, ears != .glassesSpeech else {
      if !levelTrace.isEmpty { levelTrace = "" }
      return
    }
    countHoles()
    drawLevelTrace(peak)
    // The two-channel sound was asked for and nothing has arrived since: the glasses do not
    // offer it this way, so go back to the one-channel sound that is known to work.
    if stereoMicrophones, ears == .glassesStream, !glasses.usingMock, !onBluetoothInstead,
      count == buffersAtStereo, glasses.streamText != "asking", !glasses.isPaused,
      glasses.streamText != "waiting for the glasses",
      Date().timeIntervalSince(stereoAskedAt) > 7
    {
      stereoMicrophones = false
      listeningSince = Date()
      lens.call("tell", ["Stereo sound not available", 5000])
      problem = "The glasses sent no sound on their two-channel feed, so Aside went back to the usual one."
    }
    // Listening through the glasses' camera stream, and either nothing has arrived twelve seconds
    // in, or the stream went down mid-conversation and three tries did not bring it back. While
    // Meta AI is asking for a permission the wait is the wearer's, so that does not count.
    // Waiting on the wearer (a permission in Meta AI, or a pause from the touchpad) is not a fault.
    if glasses.streamText == "asking" || glasses.isPaused { listeningSince = Date() }
    // Each new try at the stream starts the twelve seconds again, so there is also a limit on
    // the whole wait for a first sound: twenty-five seconds with Aside in front. (When Meta AI
    // really asks for a permission it takes Aside out of the front; that wait is the wearer's.)
    if ears == .glassesStream, !glasses.usingMock, !onBluetoothInstead, lastBufferCount == buffersAtStart,
      !glasses.isPaused, UIApplication.shared.applicationState == .active
    {
      waitedForSound += 1
    }
    let waitedTooLong = waitedForSound > 100
    if ears == .glassesStream, !glasses.usingMock, !audioFlowing, !saidNoSound, !onBluetoothInstead,
      glasses.streamText != "asking" || waitedTooLong, !glasses.isPaused
    {
      // A camera that will not start on a session kept from before gets, once, a fresh session
      // to start on, and the wait begins again.
      // (Not while the stream is only waiting for the glasses to be put on: a new session
      // would wait just the same.)
      if keepGlassesSession, glasses.sessionReused, !triedFreshSession, lastBufferCount == buffersAtStart,
        glasses.streamText != "waiting for the glasses",
        Date().timeIntervalSince(listeningSince) > 7
      {
        triedFreshSession = true
        listeningSince = Date()
        glasses.startAfresh()
      }
      let neverCame = lastBufferCount == buffersAtStart
        && (Date().timeIntervalSince(listeningSince) > 12 || waitedTooLong)
      let wentAway = lastBufferCount != buffersAtStart && glasses.streamGaveUp
        && Date().timeIntervalSince(lastSoundAt) > 6
      if neverCame || wentAway {
        saidNoSound = true
        if bluetoothWhenStreamFails {
          listenOverBluetoothInstead()
        } else {
          problem = "The glasses’ microphones are not running (camera stream: \(glasses.streamText)). Put them on if they are off your face. After a long session they can be too warm to stream: fold them for a minute, or pick “Glasses Bluetooth mic” in Settings, which does not use the camera."
        }
      }
    }
    if count != lastBufferCount {
      lastBufferCount = count
      lastSoundAt = Date()
      quietTicks = 0
      if !audioFlowing { audioFlowing = true }
      if saidNoSound, !onBluetoothInstead { saidNoSound = false; problem = "" }
    } else {
      quietTicks += 1
      if quietTicks > 12, audioFlowing { audioFlowing = false }
    }
  }

  /// The glasses would not start their camera stream, which is what carries their microphones.
  /// Their Bluetooth microphone needs no camera, so listening carries on through that. It is
  /// still the glasses that listen, never the phone.
  private func listenOverBluetoothInstead() {
    let stuck = glasses.lastError.isEmpty ? glasses.streamText : "\(glasses.streamText): \(glasses.lastError)"
    let sink = transcriber
    do {
      let name = try phoneAudio.start(.glassesBluetooth) { buffer in sink.append(buffer) }
      onBluetoothInstead = true
      transcriber.setWornMicrophones(false)   // the headset feed evens voices out by itself
      glasses.audioSink.setHandler(nil)
      microphoneName = name
      tellLens(ears: "hfp")
      lens.call("tell", ["Bluetooth microphone now", 7000])
      // The camera that is not streaming is let go, and the session stays, so the lens never
      // leaves the display. (With "Stay connected" off, the session ends and the display comes
      // back once it has gone: one started while the old one is still closing loses its channel.)
      // The timed tries below do nothing while a session is up.
      if keepGlassesSession {
        glasses.releaseCamera()
      } else if glasses.hasSession {
        endedOnPurpose = true
        glasses.stop()
      }
      displayAgain(after: 1.5)
      displayAgain(after: 4)
      displayAgain(after: 8)
      problem = "The glasses’ camera stream is not running (\(stuck)), so Aside is listening through their Bluetooth microphone instead. Looking is off until you start again. If it happens every time, switch the glasses off and on."
    } catch {
      problem = "The glasses have not started their microphones (camera stream: \(stuck)), and their Bluetooth microphone is not there either. Put them on, or fold them for a minute if they have been streaming for a long time, then start again."
    }
  }

  /// Puts the lens back on the glasses while listening carries on without their session.
  private func displayAgain(after seconds: Double) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard let self, self.showOnGlasses, self.glasses.hasDevice else { return }
      guard self.isSampling || (self.isListening && (self.onBluetoothInstead || !self.ears.needsGlassesSession))
      else { return }
      // With the Bluetooth microphone or the phone as the chosen ears, the camera may be kept for Look.
      let camera = self.isListening && !self.onBluetoothInstead && self.cameraForLook
      self.glasses.start(camera: camera, audio: false, speech: false, display: true)
    }
  }

  // MARK: - Looking

  /// Asks the glasses for a photo of what the wearer is looking at, and reads it.
  func look() {
    guard isListening else {
      problem = "Start listening first, then look."
      return
    }
    lookIsUnasked = false
    lastLookAsk = Date()
    if glasses.capturePhoto() {
      photoIsComing(tellIfLost: true)
      return
    }
    // No camera stream. Either none was asked for, or it has not come up yet.
    let state = glasses.streamText
    if state == "off" {
      problem = "Looking needs the glasses’ camera. Use “Glasses microphones” as the ears, or turn on “Keep the camera ready” in Settings."
      return
    }
    lens.call("lookSoon")
    // A stream that stopped for good (the glasses were off the face) gets a new camera now.
    glasses.reviveCamera()
    Task { @MainActor [weak self] in
      // The camera only runs while the glasses are worn, and takes a few seconds to start.
      for _ in 0..<16 {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let self, self.isListening else { return }
        if self.glasses.capturePhoto() {
          self.photoIsComing(tellIfLost: true)
          return
        }
      }
      guard let self else { return }
      self.problem = self.ears == .glassesStream && !self.onBluetoothInstead
        ? "The glasses’ camera is not running (\(self.glasses.streamText)). Put the glasses on and wait for “sound arriving”, then look again."
        : "The glasses’ camera is not running (\(self.glasses.streamText)). Put the glasses on, then look again."
    }
  }

  /// While a conversation is going, takes a look every few seconds without being asked.
  /// The brain reads it quietly and only speaks up when there is something new to read.
  private func lookIfDue() {
    // Photos that stopped coming (the glasses were taken off, or handed over) are tried again
    // after a while, waiting longer each time.
    if unaskedLooksPaused, !looksBreakTheStream, let again = looksRetryAt, Date() > again {
      looksRetryAt = nil
      unaskedLooksPaused = false
      unaskedLookTroubles = 1
      if problem.hasPrefix("Looking by itself is paused") { problem = "" }
    }
    guard lookByItself, !unaskedLooksPaused, !looksBreakTheStream, isListening, phase == "live" else { return }
    guard lookAskedAt == nil, Date().timeIntervalSince(lastLookAsk) > 10 else { return }
    lastLookAsk = Date()
    guard glasses.capturePhoto() else { return }
    lookIsUnasked = true
    lastUnaskedLookAt = Date()
    clockSinceLook = 0
    soundSinceLook = 0
    photoIsComing(tellIfLost: false)
    // Hearing matters more than seeing. The same stream carries the microphones, so if taking a
    // photo makes it stop even for a moment, or if no photo comes back twice in a row, the
    // unasked looks stop for the rest of this session.
    let photosBefore = photosRead
    let dropsBefore = glasses.streamDrops
    Task { @MainActor [weak self] in
      // A photo is given six seconds to arrive (see photoIsComing) before it counts as lost.
      try? await Task.sleep(nanoseconds: 6_500_000_000)
      guard let self, self.isListening, !self.onBluetoothInstead else { return }
      // A photo that stops the microphones for a second or more is not worth it: on some
      // glasses software every photo does. One is enough to know.
      let costSound = self.ears == .glassesStream && self.clockSinceLook - self.soundSinceLook >= 1.5
      let streamFell = self.glasses.streamDrops != dropsBefore || self.glasses.streamText != "streaming"
        || costSound
      let nothingCame = self.photosRead == photosBefore
      if streamFell || nothingCame {
        self.unaskedLookTroubles += 1
        if streamFell || self.unaskedLookTroubles >= 2 {
          self.unaskedLooksPaused = true
          if streamFell {
            self.looksBreakTheStream = true
          } else {
            self.looksRetryAt = Date().addingTimeInterval(self.looksRetryWait)
            self.looksRetryWait = min(self.looksRetryWait * 2, 240)
          }
          // Said once on the lens; a later retry that fails again stays quiet there.
          if streamFell || self.looksRetryWait <= 90 { self.lens.call("tell", ["Looking by itself paused", 6000]) }
          self.problem = streamFell
            ? "Looking by itself is paused: each photo was interrupting the glasses’ microphones. Look still works when you press it."
            : "Looking by itself is paused: the glasses are not sending photos (they do that off the face). Aside tries again in a little while; Look still works when you press it."
        }
      } else {
        self.unaskedLookTroubles = 0
        self.looksRetryWait = 45
      }
    }
  }

  /// A photo has been asked for. If none arrives, a look by hand says so; one taken unasked is just dropped.
  private func photoIsComing(tellIfLost: Bool) {
    if tellIfLost { lens.call("lookSoon") }
    let asked = Date()
    lookAskedAt = asked
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 6_000_000_000)
      guard let self, self.lookAskedAt == asked else { return }
      self.lookAskedAt = nil
      if tellIfLost {
        self.problem = "The glasses did not send a photo. Try Look once more."
        self.lens.call("tell", ["No photo came back", 4000])
      }
    }
  }

  /// The glasses said straight away that the photo could not be taken.
  private func photoFailed() {
    guard lookAskedAt != nil else { return }
    lookAskedAt = nil
    if !lookIsUnasked {
      problem = "The glasses could not take that photo. Try Look once more."
      lens.call("tell", ["No photo came back", 4000])
    }
    lookIsUnasked = false
  }

  private func sawPhoto(_ data: Data) {
    lookAskedAt = nil
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
    lens.call("look", [jpeg.base64EncodedString(), lookIsUnasked])
    lookIsUnasked = false
    photosRead += 1
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
    if glasses.isPaused, isListening || isSampling { return "Paused on the glasses" }
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
    let flow = audioFlowing ? "sound arriving" : (lastBufferCount != buffersAtStart ? "no sound right now" : "no sound yet")
    let looks = photosRead == 0 ? "" : photosRead == 1 ? ". Looked once" : ". Looked \(photosRead) times"
    return (speechNote.isEmpty ? "\(microphoneName): \(flow)" : "\(microphoneName): \(flow), \(speechNote)") + looks
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
    if glasses.streamText != "off" {
      parts.append(photosRead > 0 ? "camera stream \(glasses.streamText), \(photosRead) photos read" : "camera stream \(glasses.streamText)")
    }
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
