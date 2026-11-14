//
// GlassesLink.swift
//
// Everything that touches Meta's Device Access Toolkit lives here: registration with the
// Meta AI app, one device session, and the capabilities Gist attaches to it:
//
//   camera stream   carries the glasses' microphones as 16 kHz audio, and takes a still on request
//   speech          the glasses' own on-device recogniser (text only)
//   display         shows the lens on Meta Ray-Ban Display
//
// The API usage follows Meta's CameraAccess, DisplayAccess and BirdSpotter samples (SDK 1.0.1).
// This file deliberately does not import SwiftUI: the display DSL has its own Text and Image.
//

import AVFoundation
import Combine
import Foundation
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATMockDevice
import MWDATSpeech
import UIKit

/// Audio buffers arrive on the SDK's own thread. This hands them on without touching the main actor.
final class AudioSink: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

  func setHandler(_ newHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
    lock.lock()
    handler = newHandler
    lock.unlock()
  }

  func push(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let current = handler
    lock.unlock()
    current?(buffer)
  }
}

@MainActor
final class GlassesLink: ObservableObject {
  // MARK: - What the screen shows

  @Published var registrationText: String = "unknown"
  @Published var isRegistered: Bool = false
  @Published var hasDevice: Bool = false
  @Published var deviceName: String = ""
  @Published var deviceHasDisplay: Bool = false
  @Published var sessionText: String = "idle"
  @Published var streamText: String = "off"
  @Published var displayText: String = "off"
  @Published var speechText: String = "off"
  @Published var lastError: String = ""
  @Published var usingMock: Bool = false
  @Published var framesSent: Int = 0
  /// How long the last frame took to reach the display, in milliseconds.
  @Published var lastSendMs: Int = 0

  // MARK: - What the rest of the app hooks into

  /// Glasses microphone audio (through the camera stream). Called off the main thread.
  let audioSink = AudioSink()
  /// Text from the glasses' own recogniser: (text, isFinal).
  var onTranscript: ((String, Bool) -> Void)?
  /// A JPEG from the glasses camera, after `capturePhoto()`.
  var onPhoto: ((Data) -> Void)?
  /// The wearer tapped the lens.
  var onTap: (() -> Void)?
  /// The display has just come up and has nothing on it yet.
  var onDisplayReady: (() -> Void)?
  /// Told how long each picture took to arrive, so the sender can send a lighter one.
  var onFrameTiming: ((Int) -> Void)?
  /// Told which choice the wearer picked on the glasses.
  var onChoice: ((String) -> Void)?

  /// One thing the wearer can pick on the glasses themselves, with the band or the touchpad.
  struct Choice: Sendable {
    let id: String
    let label: String
    let icon: MWDATDisplay.IconName?
    var main = false
  }
  /// The session ended, whoever ended it.
  var onSessionEnded: (() -> Void)?

  // MARK: - Private

  private let wearables: any WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceSession: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private var display: MWDATDisplay.Display?
  private var speech: MWDATSpeech.Speech?
  private var mockGlasses: (any MockGlasses)?

  private let sessionTokenBag = ListenerTokenBag()
  private let streamTokenBag = ListenerTokenBag()
  private let displayTokenBag = ListenerTokenBag()
  private let speechTokenBag = ListenerTokenBag()

  private var registrationTask: Task<Void, Never>?
  private var deviceTask: Task<Void, Never>?

  private var wantCamera = false
  private var wantAudio = false
  private var wantSpeech = false
  private var wantDisplay = false
  private var tearingDown = false

  // A capability is born "stopped", so only one that has run and then stopped is worth restarting.
  private var streamHasRun = false
  private var speechHasRun = false
  private var displayHasRun = false
  private var streamRestarts = 0
  private var speechRestarts = 0

  private var isSending = false
  private var pendingFrame: UIImage?
  private var pendingText: [String]?
  private var pendingMenu: (title: String, note: String, choices: [Choice])?

  init() {
    let shared = Wearables.shared
    wearables = shared
    deviceSelector = AutoDeviceSelector(wearables: shared)
    registrationText = shared.registrationState.description
    isRegistered = shared.registrationState == .registered
    observe()
  }

  var hasSession: Bool { deviceSession != nil }

  /// True on the iOS Simulator, where simulated glasses have no camera to borrow.
  private var mockLacksCamera: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
  }

  // MARK: - Registration and device availability

  private func observe() {
    registrationTask = Task { [weak self] in
      guard let stream = self?.wearables.registrationStateStream() else { return }
      for await state in stream {
        guard let self else { return }
        self.registrationText = state.description
        self.isRegistered = state == .registered
      }
    }
    deviceTask = Task { [weak self] in
      guard let stream = self?.deviceSelector.activeDeviceStream() else { return }
      for await identifier in stream {
        guard let self else { return }
        self.deviceChanged(identifier)
      }
    }
  }

  private func deviceChanged(_ identifier: DeviceIdentifier?) {
    hasDevice = identifier != nil
    if let identifier, let device = wearables.deviceForIdentifier(identifier) {
      deviceName = device.nameOrId()
      deviceHasDisplay = device.supportsDisplay()
    } else {
      deviceName = ""
      deviceHasDisplay = false
    }
  }

  /// Opens the Meta AI app so the wearer can approve Gist. Meta AI then calls back through `handle(url:)`.
  func connect() {
    lastError = ""
    Task { @MainActor in
      do {
        try await self.wearables.startRegistration()
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }

  func disconnect() {
    stop()
    Task { @MainActor in
      do {
        try await self.wearables.startUnregistration()
      } catch {
        self.lastError = error.localizedDescription
      }
    }
  }

  func handle(url: URL) {
    Task { @MainActor in
      do {
        _ = try await self.wearables.handleUrl(url)
      } catch {
        self.lastError = "Meta AI could not finish: \(error.localizedDescription)"
      }
    }
  }

  // MARK: - Practice glasses (no hardware needed)

  /// Pairs simulated display glasses. On a real iPhone its back camera stands in for the glasses
  /// camera, and `mockPreviewView()` shows what the display would show.
  func useMockGlasses() {
    guard mockGlasses == nil else { return }
    lastError = ""
    MockDeviceKit.shared.enable()
    do {
      let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      if !mockLacksCamera {
        glasses.services.camera.setCameraFeed(cameraFacing: .back)
      }
      // The simulated recogniser listens through this phone's own microphone.
      glasses.services.speech.setTranscriptionSource(.liveDeviceAsr)
      mockGlasses = glasses
      usingMock = true
    } catch {
      lastError = "Practice glasses could not be paired: \(error.localizedDescription)"
    }
  }

  func dropMockGlasses() {
    guard mockGlasses != nil else { return }
    stop()
    mockGlasses = nil
    usingMock = false
    MockDeviceKit.shared.disable()
  }

  func mockPreviewView() -> UIView? {
    mockGlasses?.services.display.createPreviewView()
  }

  // MARK: - Session

  /// Starts one device session and attaches the requested capabilities once it is up.
  func start(camera: Bool, audio: Bool, speech: Bool, display: Bool) {
    let cameraAllowed = !(usingMock && mockLacksCamera)
    // Simulated glasses have no microphones behind their camera, so audio is never asked of them.
    wantAudio = audio && !usingMock
    wantCamera = (camera || wantAudio) && cameraAllowed
    wantSpeech = speech
    wantDisplay = display
    lastError = ""
    tearingDown = false

    if let session = deviceSession {
      // Already connected: attach whatever is newly wanted.
      if session.state == .started { attachCapabilities(to: session) }
      return
    }
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no early transition is missed.
      session.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionChanged(state) }
      }.store(in: sessionTokenBag)
      session.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        Task { @MainActor in self?.lastError = message }
      }.store(in: sessionTokenBag)
      sessionText = "starting"
      try session.start()
    } catch {
      lastError = error.localizedDescription
      cleanupSession()
    }
  }

  /// Ends the session. The SDK takes every capability down with it.
  func stop() {
    guard let session = deviceSession else { return }
    tearingDown = true
    sessionText = "stopping"
    session.stop()
  }

  private func sessionChanged(_ state: DeviceSessionState) {
    sessionText = state.description
    if state == .started {
      if let session = deviceSession { attachCapabilities(to: session) }
    } else if state == .stopped {
      cleanupSession()
      onSessionEnded?()
    }
  }

  private func cleanupSession() {
    sessionTokenBag.clear()
    streamTokenBag.clear()
    displayTokenBag.clear()
    speechTokenBag.clear()
    deviceSession = nil
    camera = nil
    display = nil
    speech = nil
    tearingDown = false
    streamHasRun = false
    speechHasRun = false
    displayHasRun = false
    streamRestarts = 0
    speechRestarts = 0
    isSending = false
    pendingFrame = nil
    pendingText = nil
    pendingMenu = nil
    lastSendMs = 0
    sessionText = "idle"
    streamText = "off"
    displayText = "off"
    speechText = "off"
  }

  private func attachCapabilities(to session: DeviceSession) {
    if wantDisplay { attachDisplay(to: session) }
    if wantSpeech { attachSpeech(to: session) }
    if wantCamera { attachCamera(to: session) }
  }

  /// Asks for a permission only when it is not already granted, because asking opens the Meta AI app.
  private func allowed(_ permission: MWDATCore.Permission) async -> Bool {
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      return status == .granted
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  // MARK: - Camera stream (the glasses' ears, and their eyes on request)

  private func attachCamera(to session: DeviceSession) {
    guard camera == nil else { return }
    let needsMicrophone = wantAudio
    streamText = "asking"
    Task { @MainActor in
      guard await self.allowed(.camera) else {
        self.streamText = "camera not allowed in Meta AI"
        return
      }
      if needsMicrophone {
        guard await self.allowed(.microphone) else {
          self.streamText = "microphone not allowed in Meta AI"
          return
        }
      }
      self.beginStream(on: session, withAudio: needsMicrophone)
    }
  }

  private func beginStream(on session: DeviceSession, withAudio: Bool) {
    guard camera == nil, session.state == .started, !tearingDown else { return }
    // Compressed video at the lowest settings: nobody watches these frames. They keep the
    // camera awake so the stream can carry the microphones, and HEVC keeps flowing when the
    // phone is locked (a raw stream pauses in the background).
    let configuration: StreamConfiguration
    if withAudio {
      configuration = StreamConfiguration(
        videoCodec: .hvc1,
        audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: 1),
        resolution: .low,
        frameRate: 7
      )
    } else {
      configuration = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 7)
    }
    do {
      guard let newCamera = try session.addCamera(config: configuration) else {
        streamText = "camera unavailable"
        return
      }
      camera = newCamera
      let stream = newCamera.stream
      let sink = audioSink

      stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.streamChanged(state) }
      }.store(in: streamTokenBag)

      stream.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        Task { @MainActor in self?.lastError = "Camera stream: \(message)" }
      }.store(in: streamTokenBag)

      stream.photoDataPublisher.listen { [weak self] photo in
        let data = photo.data
        Task { @MainActor in self?.onPhoto?(data) }
      }.store(in: streamTokenBag)

      if withAudio {
        stream.audioFramePublisher.listen { frame in
          sink.push(frame.pcmBuffer)
        }.store(in: streamTokenBag)
      }

      streamText = "starting"
      stream.start()
    } catch {
      camera = nil
      streamText = "off"
      lastError = "Camera: \(error.localizedDescription)"
    }
  }

  private func streamChanged(_ state: StreamState) {
    switch state {
    case .streaming:
      streamHasRun = true
      streamRestarts = 0
      streamText = "streaming"
    case .starting:
      streamText = "starting"
    case .waitingForDevice:
      streamText = "waiting for the glasses"
    case .paused:
      streamText = "paused (tap the glasses to resume)"
    case .stopping:
      streamText = "stopping"
    case .stopped:
      guard streamHasRun else { return }
      streamText = "stopped"
      restartStream()
    }
  }

  /// A stream the glasses put down on their own (a photo can do it) is started again a moment later.
  private func restartStream() {
    guard !tearingDown, wantCamera, streamRestarts < 3 else { return }
    streamRestarts += 1
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard !self.tearingDown, let camera = self.camera, let session = self.deviceSession else { return }
      guard session.state == .started, camera.stream.state == .stopped else { return }
      self.streamText = "starting again"
      camera.stream.start()
    }
  }

  /// Asks the glasses for a still of what the wearer is looking at. The JPEG arrives on `onPhoto`.
  @discardableResult
  func capturePhoto() -> Bool {
    guard let camera, streamText == "streaming" else { return false }
    return camera.stream.capturePhoto(format: .jpeg)
  }

  // MARK: - Speech (the glasses' own recogniser)

  private func attachSpeech(to session: DeviceSession) {
    guard speech == nil else { return }
    speechText = "asking"
    Task { @MainActor in
      guard await self.allowed(.microphone) else {
        self.speechText = "microphone not allowed in Meta AI"
        return
      }
      self.beginSpeech(on: session)
    }
  }

  private func beginSpeech(on session: DeviceSession) {
    guard speech == nil, session.state == .started, !tearingDown else { return }
    do {
      guard let newSpeech = try session.addSpeech() else {
        speechText = "these glasses have no on-device speech"
        return
      }
      speech = newSpeech

      newSpeech.transcriptionPublisher.listen { [weak self] result in
        let text = result.text
        let isFinal = result.isFinal
        Task { @MainActor in self?.onTranscript?(text, isFinal) }
      }.store(in: speechTokenBag)

      newSpeech.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.speechChanged(state) }
      }.store(in: speechTokenBag)

      newSpeech.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        Task { @MainActor in self?.lastError = "Glasses speech: \(message)" }
      }.store(in: speechTokenBag)

      speechText = "starting"
      newSpeech.start()
    } catch {
      speechText = "unavailable"
      lastError = "Glasses speech: \(error.localizedDescription)"
    }
  }

  private func speechChanged(_ state: SpeechState) {
    speechText = state.description
    if state == .started {
      speechHasRun = true
      speechRestarts = 0
    } else if state == .stopped, speechHasRun {
      restartSpeech()
    }
  }

  private func restartSpeech() {
    guard !tearingDown, wantSpeech, speechRestarts < 3 else { return }
    speechRestarts += 1
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard !self.tearingDown, let speech = self.speech, let session = self.deviceSession else { return }
      guard session.state == .started, speech.state == .stopped else { return }
      speech.start()
    }
  }

  // MARK: - Display

  private func attachDisplay(to session: DeviceSession) {
    guard display == nil else { return }
    do {
      let newDisplay = try session.addDisplay()
      display = newDisplay
      newDisplay.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.displayChanged(state) }
      }.store(in: displayTokenBag)
      displayText = "starting"
      newDisplay.start()
    } catch {
      // Glasses without a display land here. Everything else still works.
      displayText = "no display on these glasses"
    }
  }

  private func displayChanged(_ state: DisplayState) {
    switch state {
    case .starting:
      displayText = "starting"
    case .started:
      displayText = "on"
      let first = !displayHasRun
      displayHasRun = true
      if pendingFrame == nil, pendingText == nil, first {
        onDisplayReady?()
      }
      flushPending()
    case .stopping:
      displayText = "stopping"
    case .stopped:
      displayText = "off"
    }
  }

  /// Shows one finished 600x600 frame of the lens. Frames that arrive while one is still
  /// crossing the Bluetooth link replace each other, so the display never falls behind.
  func show(frame: UIImage) {
    pendingText = nil
    pendingMenu = nil
    pendingFrame = frame
    flushPending()
  }

  /// A short menu on the glasses, made of the display's own buttons so the band can pick one.
  func showMenu(title: String, note: String, choices: [Choice]) {
    pendingFrame = nil
    pendingText = nil
    pendingMenu = (title, note, choices)
    flushPending()
  }

  private func button(for choice: Choice) -> MWDATDisplay.Button {
    let id = choice.id
    let made = MWDATDisplay.Button(
      label: choice.label,
      style: choice.main ? .primary : .secondary,
      iconName: choice.icon,
      onClick: { [weak self] in
        Task { @MainActor in self?.onChoice?(id) }
      }
    )
    return choice.main ? made.actionRole(.primary) : made
  }

  /// The same moment as plain text components, for when picture frames are too slow.
  func show(title: String, sub: String, body: String) {
    pendingFrame = nil
    pendingMenu = nil
    pendingText = [title, sub, body]
    flushPending()
  }

  private func flushPending() {
    guard let display, !isSending, !tearingDown else { return }
    guard pendingFrame != nil || pendingText != nil || pendingMenu != nil else { return }
    if display.state != .started {
      // A display that went down on its own is asked back; the frame waits for it.
      if displayHasRun, display.state == .stopped { display.start() }
      return
    }
    let view: FlexBox
    let isPicture = pendingFrame != nil && pendingMenu == nil
    let isMenu = pendingMenu != nil
    if let menu = pendingMenu {
      pendingMenu = nil
      let title = menu.title
      let note = menu.note
      let choices = menu.choices
      view = FlexBox(direction: .column, spacing: 12) {
        FlexBox(direction: .column) {
          MWDATDisplay.Text(title, style: .heading)
          if !note.isEmpty {
            MWDATDisplay.Text(note, style: .meta, color: .secondary)
          }
        }
        .padding(24)
        .background(.card)
        FlexBox(direction: .row, spacing: 8, alignment: .center, crossAlignment: .center, wrap: true) {
          MWDATDisplay.ButtonGroup {
            for choice in choices {
              button(for: choice)
            }
          }
        }
      }
    } else if let frame = pendingFrame {
      pendingFrame = nil
      view = FlexBox(direction: .column) {
        MWDATDisplay.Image(image: frame)
      }
    } else if let lines = pendingText {
      pendingText = nil
      var parts: [any ViewComponent] = []
      if !lines[0].isEmpty { parts.append(MWDATDisplay.Text(lines[0], style: .heading)) }
      if !lines[1].isEmpty { parts.append(MWDATDisplay.Text(lines[1], style: .meta, color: .secondary)) }
      if !lines[2].isEmpty { parts.append(MWDATDisplay.Text(lines[2], style: .body)) }
      if parts.isEmpty { parts.append(MWDATDisplay.Text("Aside", style: .meta, color: .secondary)) }
      let children = parts
      view = FlexBox(direction: .column, spacing: 12) {
        for part in children {
          part
        }
      }
      .padding(20)
    } else {
      return
    }
    // The lens answers a tap as a whole; a menu leaves the tapping to its buttons.
    let tappable = isMenu ? view : view.onTap { [weak self] in
      Task { @MainActor in self?.onTap?() }
    }
    isSending = true
    let began = Date()
    Task { @MainActor in
      do {
        try await display.send(tappable)
        self.framesSent += 1
        let took = Int(Date().timeIntervalSince(began) * 1000)
        self.lastSendMs = took
        if isPicture { self.onFrameTiming?(took) }
      } catch {
        self.lastError = "Display: \(error.localizedDescription)"
      }
      self.isSending = false
      self.flushPending()
    }
  }
}
