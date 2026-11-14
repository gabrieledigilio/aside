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
  /// The glasses have paused the session or its camera stream (a tap on their touchpad does it,
  /// and so does putting them on after listening began): nothing is heard until it resumes.
  @Published var isPaused: Bool = false
  /// How long the last frame took to reach the display, in milliseconds.
  @Published var lastSendMs: Int = 0

  // MARK: - What the rest of the app hooks into

  /// Glasses microphone audio (through the camera stream). Called off the main thread.
  let audioSink = AudioSink()
  /// Text from the glasses' own recogniser: (text, isFinal).
  var onTranscript: ((String, Bool) -> Void)?
  /// A JPEG from the glasses camera, after `capturePhoto()`.
  var onPhoto: ((Data) -> Void)?
  /// The glasses said they could not take the photo that was asked for.
  var onPhotoFailed: (() -> Void)?
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
  /// Frames keep failing though the display says it is on, and starting it again did not help.
  var onDisplayLost: (() -> Void)?
  /// The glasses paused the session (a tap on their touchpad does it), or let it carry on.
  var onPaused: ((Bool) -> Void)?
  /// The glasses reported that they are too warm. True when they say they are about to shut down.
  var onTooWarm: ((Bool) -> Void)?

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
  /// A start was asked for while the previous session was still closing.
  private var startWhenStopped = false
  /// Which of the two is paused. With only the stream paused the display still takes frames.
  private var sessionIsPaused = false
  private var streamIsPaused = false

  // A capability is born "stopped", so only one that has run and then stopped is worth restarting.
  private var streamHasRun = false
  private var speechHasRun = false
  private var displayHasRun = false
  private var streamRestarts = 0
  private var speechRestarts = 0
  // One that tried to start and fell back to "stopped" without ever running counts too: glasses
  // that are too warm, or a channel that closed under it, do exactly that.
  private var streamBegan = false
  private var streamRestartDue = false
  /// Whether the attached camera's stream carries the microphones.
  private var cameraHasAudio = false
  /// A trial: ask the glasses for two microphones' worth of sound instead of one. Nobody says
  /// whether the two-channel feed is less centred on the wearer; this is how to find out.
  var stereoSound = false
  private var cameraIsStereo = false
  /// The glasses turned the two-channel feed down; the stream was started in mono.
  var onStereoRefused: (() -> Void)?
  /// Tries to attach a camera that the glasses turned down.
  private var cameraTries = 0
  private var displayBegan = false
  private var displayRetries = 0
  /// Frames that failed in a row, and whether the display was stopped on purpose to start it afresh.
  private var sendFailures = 0
  private var displayBounce = false
  /// Counts sessions, so a late watchdog never touches a newer one.
  private var sessionNumber = 0

  private var isSending = false
  private var pendingFrame: UIImage?
  private var pendingText: [String]?
  private var pendingMenu: (title: String, note: String, choices: [Choice])?

  /// The buttons shown under every frame, so the wearer can run Aside from the glasses with the
  /// band. Empty means no buttons: the lens then fills the display and a pinch opens the menu.
  var bar: [Choice] = []

  init() {
    let shared = Wearables.shared
    wearables = shared
    deviceSelector = AutoDeviceSelector(wearables: shared)
    registrationText = shared.registrationState.description
    isRegistered = shared.registrationState == .registered
    observe()
  }

  var hasSession: Bool { deviceSession != nil }

  /// How many times a running camera stream has stopped running, for whatever reason.
  private(set) var streamDrops = 0
  /// The camera now starting was attached to a session kept from before, not to a new one.
  private(set) var sessionReused = false

  /// The camera stream stopped and three new cameras did not bring it back.
  var streamGaveUp: Bool {
    streamRestarts >= 3 && !streamRestartDue && streamText != "streaming" && streamText != "starting"
      && streamText != "starting again" && streamText != "asking"
  }

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
  func useMockGlasses(camera: Bool = true) {
    guard mockGlasses == nil else { return }
    lastError = ""
    MockDeviceKit.shared.enable()
    do {
      let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
      glasses.powerOn()
      glasses.unfold()
      glasses.don()
      if camera, !mockLacksCamera {
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

  // Poking the practice glasses, for tests that run with nobody at the phone.

  /// Lets the practice glasses borrow the iPhone's back camera (iOS asks for the camera once).
  func practiceCamera() {
    guard !mockLacksCamera else { return }
    mockGlasses?.services.camera.setCameraFeed(cameraFacing: .back)
  }

  /// A tap on the practice glasses' touchpad.
  func practiceTap() { mockGlasses?.services.captouch.tap() }

  /// A press on something the practice display is showing, by its identifier.
  func practiceClick(_ identifier: String) -> Bool {
    mockGlasses?.services.display.sendClick(identifier: identifier) ?? false
  }

  /// Switches the practice glasses off, or back on.
  func practicePower(_ on: Bool) {
    if on { mockGlasses?.powerOn() } else { mockGlasses?.powerOff() }
  }

  /// The picture the practice glasses hand over the next time a photo is asked for.
  func practicePhoto(_ file: URL) {
    mockGlasses?.services.camera.setCapturedImage(fileURL: file)
    mockGlasses?.services.cameraCapture.setCapturedPhoto(fileURL: file)
  }

  /// How warm the practice glasses say they are.
  func practiceThermal(_ level: ThermalLevel) { mockGlasses?.setThermalLevel(level) }

  /// Puts the practice glasses on, or takes them off.
  func practiceWorn(_ worn: Bool) {
    if worn { mockGlasses?.don() } else { mockGlasses?.doff() }
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

    if let session = deviceSession {
      if tearingDown || session.state == .stopping || session.state == .stopped {
        // The old session is still closing (Stop, then Listen straight away). A session cannot
        // be started again, so a new one opens the moment this one has gone.
        startWhenStopped = true
        sessionText = "starting again"
      } else if session.state == .started {
        // Already connected: attach whatever is newly wanted.
        if wantCamera, camera == nil { sessionReused = true }
        attachCapabilities(to: session)
      }
      return
    }
    openSession()
  }

  /// Opens a session for whatever is wanted right now. False when the glasses would not have it.
  @discardableResult
  private func openSession() -> Bool {
    guard deviceSession == nil else { return true }
    tearingDown = false
    startWhenStopped = false
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      sessionNumber += 1
      let number = sessionNumber
      // Subscribe before start() so no early transition is missed.
      session.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.sessionChanged(state, of: number) }
      }.store(in: sessionTokenBag)
      session.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        let warm = error == .thermalCritical
        let shuttingDown = error == .thermalEmergency || error == .peakPowerShutdown
        Task { @MainActor in
          self?.lastError = message
          if warm || shuttingDown { self?.onTooWarm?(shuttingDown) }
        }
      }.store(in: sessionTokenBag)
      sessionText = "starting"
      try session.start()
      return true
    } catch {
      lastError = error.localizedDescription
      cleanupSession()
      return false
    }
  }

  /// Ends the session. The SDK takes every capability down with it.
  func stop() {
    guard let session = deviceSession else { return }
    tearingDown = true
    startWhenStopped = false
    sessionText = "stopping"
    // Meta's guide: stop the display before its session. The session takes the rest down.
    display?.stop()
    session.stop()
    // A session that never reports "stopped" would block every later start. After twelve
    // seconds it is written off, exactly as if it had ended.
    let number = sessionNumber
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 12_000_000_000)
      guard let self, self.deviceSession != nil, self.sessionNumber == number, self.tearingDown else { return }
      self.sessionEnded()
    }
  }

  /// Listening has ended. The camera stream, and with it the microphones, goes quiet, and the
  /// session stays: the lens keeps standing by on the display and the next Listen needs no new
  /// session. With no display to keep, the whole session ends instead.
  func standBy() {
    guard let session = deviceSession, session.state == .started, !tearingDown,
      wantDisplay, display != nil, speech == nil
    else {
      stop()
      return
    }
    wantSpeech = false
    // The camera is detached rather than paused: a stream that has been stopped does not start
    // again, and the next Listen attaches a new camera to this same session.
    releaseCamera()
  }

  /// Ends this session and opens a fresh one for the same wants: a new camera, a new display.
  func startAfresh() {
    guard deviceSession != nil else {
      openSession()
      return
    }
    stop()
    startWhenStopped = true
    sessionText = "starting again"
  }

  /// The sound feed asked of the glasses changed while the camera is up: swap the camera for
  /// one with the new feed. The session and the display stay as they are.
  func soundFeedChanged() {
    guard let session = deviceSession, session.state == .started, !tearingDown, wantCamera, wantAudio,
      camera != nil
    else { return }
    cameraTries = 0
    attachCamera(to: session)
  }

  /// A camera whose stream stopped for good is replaced by a new one. A Look asks for this, so
  /// one press is enough after the glasses were off the face for a while.
  func reviveCamera() {
    guard let session = deviceSession, session.state == .started, !tearingDown, wantCamera else { return }
    if let camera, camera.stream.state != .stopped { return }   // running, or on its way
    streamRestarts = 0
    cameraTries = 0
    detachCamera()
    attachCamera(to: session)
  }

  /// Lets go of the camera, and with it the microphones, and keeps the session and its display.
  func releaseCamera() {
    wantCamera = false
    wantAudio = false
    detachCamera()
    streamRestarts = 0
    cameraTries = 0
  }

  /// Takes the camera off the session. Stopping it takes its stream down with it and frees the
  /// place for a new one.
  private func detachCamera() {
    guard let old = camera else { return }
    streamTokenBag.clear()
    camera = nil
    streamHasRun = false
    streamBegan = false
    streamText = "off"
    streamIsPaused = false
    pausedChanged()
    old.stop()
  }

  private func sessionChanged(_ state: DeviceSessionState, of number: Int) {
    // News about a session that has already been written off must not touch the one after it.
    guard number == sessionNumber, deviceSession != nil else { return }
    sessionText = state.description
    if state == .started {
      let resumed = sessionIsPaused
      sessionIsPaused = false
      pausedChanged()
      if let session = deviceSession { attachCapabilities(to: session) }
      if resumed {
        // The display went dark while paused: it gets a fresh frame, or is asked back if it stopped.
        if let display, display.state == .stopped, wantDisplay { display.start() }
        if pendingFrame == nil, pendingText == nil, pendingMenu == nil { onDisplayReady?() }
        flushPending()
      }
    } else if state == .paused {
      sessionIsPaused = true
      pausedChanged()
    } else if state == .stopped {
      sessionEnded()
    }
  }

  /// Tells the app when "paused" starts or ends, whichever of the two paused.
  private func pausedChanged() {
    let paused = sessionIsPaused || streamIsPaused
    guard paused != isPaused else { return }
    isPaused = paused
    onPaused?(paused)
  }

  /// The session has gone. If something asked for the glasses while it was closing, a new one
  /// opens for that; otherwise the app is told.
  private func sessionEnded() {
    let again = startWhenStopped
    cleanupSession()
    guard again else {
      onSessionEnded?()
      return
    }
    sessionText = "starting again"
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 600_000_000)
      guard let self else { return }
      // If the glasses refuse the new session, the app hears that the old one ended after all.
      if !self.openSession() { self.onSessionEnded?() }
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
    startWhenStopped = false
    sessionIsPaused = false
    streamIsPaused = false
    isPaused = false
    streamHasRun = false
    speechHasRun = false
    displayHasRun = false
    streamRestarts = 0
    speechRestarts = 0
    streamBegan = false
    streamRestartDue = false
    sessionReused = false
    cameraHasAudio = false
    cameraIsStereo = false
    cameraTries = 0
    displayBegan = false
    displayRetries = 0
    sendFailures = 0
    displayBounce = false
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
    if !wantDisplay, let old = display {
      // The lens is no longer wanted on the glasses, and the session lives on for the camera.
      displayTokenBag.clear()
      display = nil
      displayText = "off"
      displayHasRun = false
      displayBegan = false
      pendingFrame = nil
      pendingText = nil
      pendingMenu = nil
      old.stop()
    }
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
    if camera != nil {
      // Running, or on its way. If it is wanted with different sound this time, it is replaced.
      guard cameraHasAudio != wantAudio || (wantAudio && cameraIsStereo != stereoSound) else { return }
      detachCamera()
    }
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
    guard camera == nil, wantCamera, session.state == .started, !tearingDown else { return }
    // Compressed video at the lowest settings: nobody watches these frames. They keep the
    // camera awake so the stream can carry the microphones, and HEVC keeps flowing when the
    // phone is locked (a raw stream pauses in the background). Two frames a second is the
    // least the glasses offer: the same Bluetooth link carries the sound and the pictures for
    // the display, and at seven frames a second the display's pictures were arriving late.
    let configuration: StreamConfiguration
    let stereo = withAudio && stereoSound
    if withAudio {
      configuration = StreamConfiguration(
        videoCodec: .hvc1,
        audioCodec: .pcm(sampleRate: .rate16000, numberOfChannels: stereo ? 2 : 1),
        resolution: .low,
        frameRate: 2
      )
    } else {
      configuration = StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 2)
    }
    do {
      guard let newCamera = try session.addCamera(config: configuration) else {
        streamText = "camera unavailable"
        return
      }
      camera = newCamera
      cameraHasAudio = withAudio
      cameraIsStereo = stereo
      let stream = newCamera.stream
      let sink = audioSink

      stream.statePublisher.listen { [weak self] state in
        Task { @MainActor in self?.streamChanged(state) }
      }.store(in: streamTokenBag)

      stream.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        let photoFailed = error == .photoCaptureFailed
        let warm = error == .thermalHot
        Task { @MainActor in
          // A photo that failed says nothing about the stream, so it is not kept as its error.
          if photoFailed { self?.onPhotoFailed?() } else { self?.lastError = "Camera stream: \(message)" }
          if warm { self?.onTooWarm?(false) }
        }
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
      if stereo {
        // The glasses would not give two channels: carry on with one, straight away.
        stereoSound = false
        onStereoRefused?()
        beginStream(on: session, withAudio: withAudio)
        return
      }
      // A camera that was let go a moment ago can still be on its way out: try again shortly.
      guard cameraTries < 3 else { return }
      cameraTries += 1
      streamText = "starting"
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard self.camera == nil, self.wantCamera, let session = self.deviceSession else { return }
        self.beginStream(on: session, withAudio: withAudio)
      }
    }
  }

  private func streamChanged(_ state: StreamState) {
    guard deviceSession != nil, camera != nil else { return }
    if streamText == "streaming", state != .streaming { streamDrops += 1 }
    streamIsPaused = state == .paused
    pausedChanged()
    switch state {
    case .streaming:
      streamHasRun = true
      streamRestarts = 0
      cameraTries = 0
      streamText = "streaming"
    case .starting:
      streamBegan = true
      streamText = "starting"
    case .waitingForDevice:
      streamBegan = true
      streamText = "waiting for the glasses"
    case .paused:
      streamText = "paused (tap the glasses to resume)"
    case .stopping:
      streamText = "stopping"
    case .stopped:
      // Born stopped: only a stream that ran, or at least tried to start, has really stopped.
      guard streamHasRun || streamBegan else { return }
      streamText = "stopped"
      restartStream()
    }
  }

  /// A stream the glasses put down on their own (a photo can do it) is replaced a moment later.
  /// A stopped stream does not start again, so its camera is detached and a new one attached.
  private func restartStream() {
    guard !tearingDown, wantCamera, !isPaused, streamRestarts < 3 else { return }
    streamRestarts += 1
    streamRestartDue = true
    let withAudio = cameraHasAudio
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 900_000_000)
      self.streamRestartDue = false
      guard !self.tearingDown, self.wantCamera else { return }
      guard let camera = self.camera, let session = self.deviceSession else { return }
      guard session.state == .started, camera.stream.state == .stopped else { return }
      self.detachCamera()
      self.streamText = "starting again"
      self.beginStream(on: session, withAudio: withAudio)
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
    guard deviceSession != nil, speech != nil else { return }
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
    guard deviceSession != nil, display != nil else { return }
    switch state {
    case .starting:
      displayBegan = true
      displayText = "starting"
    case .started:
      displayBegan = true
      displayText = "on"
      displayHasRun = true
      // A display that has just come up, or come back, has nothing on it: ask for a fresh frame.
      if pendingFrame == nil, pendingText == nil, pendingMenu == nil {
        onDisplayReady?()
      }
      flushPending()
    case .stopping:
      displayText = "stopping"
    case .stopped:
      guard displayBegan else { return }
      displayText = "off"
      reviveDisplay()
    }
  }

  /// A display that never came up, or that was stopped on purpose because its frames kept
  /// failing, is started again a moment later. One that ran and went down by itself comes back
  /// with the next frame (see `flushPending`).
  private func reviveDisplay() {
    let bounced = displayBounce
    displayBounce = false
    guard !tearingDown, wantDisplay, !sessionIsPaused else { return }
    guard bounced || (!displayHasRun && displayRetries < 3) else { return }
    if !bounced { displayRetries += 1 }
    let wait: UInt64 = bounced ? 500_000_000 : UInt64(displayRetries) * 1_000_000_000
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: wait)
      guard !self.tearingDown, let display = self.display, let session = self.deviceSession else { return }
      guard session.state == .started, display.state == .stopped else { return }
      self.displayText = "starting again"
      display.start()
    }
  }

  /// Frames that keep failing mean the display's channel has gone, though it still says "on".
  /// First the display alone is started afresh. If frames still fail after that, the app is
  /// told, and decides whether the whole session should start again.
  private func displayTrouble() {
    guard !tearingDown, let display else { return }
    if sendFailures == 2, display.state == .started {
      displayBounce = true
      display.stop()
    } else if sendFailures == 3 {
      onDisplayLost?()
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
    // A paused session takes no frames; the newest one waits for it to carry on.
    guard let display, !isSending, !tearingDown, !sessionIsPaused else { return }
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
      let controls = bar
      if controls.isEmpty {
        view = FlexBox(direction: .column) {
          MWDATDisplay.Image(image: frame)
        }
      } else {
        // The picture gives up a strip at the bottom to real buttons, which the band can press.
        view = FlexBox(direction: .column, spacing: 6, crossAlignment: .center) {
          MWDATDisplay.Image(image: frame).flexGrow(1).flexShrink(1)
          MWDATDisplay.ButtonGroup {
            for choice in controls {
              button(for: choice)
            }
          }
        }
      }
    } else if let lines = pendingText {
      pendingText = nil
      var parts: [any ViewComponent] = []
      if !lines[0].isEmpty { parts.append(MWDATDisplay.Text(lines[0], style: .heading)) }
      if !lines[1].isEmpty { parts.append(MWDATDisplay.Text(lines[1], style: .meta, color: .secondary)) }
      if !lines[2].isEmpty { parts.append(MWDATDisplay.Text(lines[2], style: .body)) }
      if parts.isEmpty { parts.append(MWDATDisplay.Text("Aside", style: .meta, color: .secondary)) }
      let controls = bar
      if !controls.isEmpty {
        parts.append(MWDATDisplay.ButtonGroup {
          for choice in controls {
            button(for: choice)
          }
        })
      }
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
    // With no buttons on it, the lens answers a tap as a whole; buttons take their own taps.
    let tappable = (isMenu || !bar.isEmpty) ? view : view.onTap { [weak self] in
      Task { @MainActor in self?.onTap?() }
    }
    isSending = true
    let began = Date()
    Task { @MainActor in
      do {
        try await display.send(tappable)
        self.framesSent += 1
        self.sendFailures = 0
        self.displayRetries = 0
        let took = Int(Date().timeIntervalSince(began) * 1000)
        self.lastSendMs = took
        if isPicture { self.onFrameTiming?(took) }
      } catch {
        // A frame that was on its way when the glasses paused is not a fault of the display.
        if !self.sessionIsPaused {
          self.lastError = "Display: \(error.localizedDescription)"
          self.sendFailures += 1
          self.displayTrouble()
        }
      }
      self.isSending = false
      self.flushPending()
    }
  }
}
