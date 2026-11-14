//
// ContentView.swift
//
// The phone's screen: the lens exactly as the glasses show it, one button to start and stop
// listening, and the day around it.
//

import SwiftUI
import UIKit
import WebKit

/// Colours shared with the lens, so the phone and the glasses read as one thing.
enum Theme {
  static let back = Color(red: 0.020, green: 0.035, blue: 0.043)
  static let panel = Color(red: 0.043, green: 0.078, blue: 0.094)
  static let ion = Color(red: 0.388, green: 0.902, blue: 1.0)
  static let line = Color(red: 0.388, green: 0.902, blue: 1.0).opacity(0.24)
  static let amber = Color(red: 1.0, green: 0.722, blue: 0.302)
  static let rose = Color(red: 1.0, green: 0.435, blue: 0.522)
  static let ink = Color(red: 0.953, green: 0.984, blue: 1.0)
  static let dim = Color(red: 0.953, green: 0.984, blue: 1.0).opacity(0.62)
}

// MARK: - The lens, mirrored

/// Holds the 600x600 web view and scales it down to fit, without changing what it draws.
final class LensContainer: UIView {
  private let webView: WKWebView

  init(webView: WKWebView, adopting: Bool = true) {
    self.webView = webView
    super.init(frame: .zero)
    backgroundColor = .black
    clipsToBounds = true
    if adopting { addSubview(webView) }
  }

  /// Takes the web view into this container. It lives in one place at a time: the main
  /// screen, or the stage while that is showing.
  func adopt() {
    guard webView.superview !== self else { return }
    addSubview(webView)
    setNeedsLayout()
  }

  required init?(coder: NSCoder) {
    fatalError("LensContainer is only created in code")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = min(bounds.width, bounds.height)
    guard side > 0 else { return }
    let scale = side / 600
    webView.transform = .identity
    webView.bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
  }
}

struct LensMirror: UIViewRepresentable {
  let webView: WKWebView
  /// False for a mirror that has lent the lens to another one (the stage).
  var active = true

  func makeUIView(context: Context) -> LensContainer {
    LensContainer(webView: webView, adopting: active)
  }

  func updateUIView(_ uiView: LensContainer, context: Context) {
    if active { uiView.adopt() }
  }
}

/// What simulated glasses would show, drawn by Meta's own preview.
struct PracticeDisplay: UIViewRepresentable {
  let make: () -> UIView?

  func makeUIView(context: Context) -> UIView {
    make() ?? UIView()
  }

  func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Small pieces

// MARK: - The stage

/// The lens alone, as large as the screen allows, with what was just heard beside it.
/// Made for a phone mirrored onto a bigger screen while someone wears the glasses: the
/// square in the middle is the picture their display is showing.
struct StageView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Aside")
          .font(.title2.weight(.bold))
          .foregroundStyle(Theme.ink)
        Text("On the glasses right now")
          .font(.footnote)
          .foregroundStyle(Theme.dim)
        Spacer(minLength: 8)
        if !model.heardLine.isEmpty {
          Text("Heard")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.ion)
          Text("“\(model.heardLine)”")
            .font(.callout)
            .foregroundStyle(Theme.ink)
            .lineLimit(7)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      LensMirror(webView: model.lens.webView, active: true)
        .aspectRatio(1, contentMode: .fit)
        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.spokenLens.isEmpty ? "The Aside lens" : model.spokenLens)

      VStack(alignment: .trailing, spacing: 8) {
        Button {
          model.showStage = false
        } label: {
          Image(systemName: "xmark")
            .font(.headline)
            .foregroundStyle(Theme.dim)
            .padding(8)
        }
        .accessibilityLabel("Leave the stage")
        Spacer(minLength: 8)
        Text(model.statusLine)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(Theme.ink)
        if !model.modelNote.isEmpty {
          Text(model.modelNote)
            .font(.caption)
            .foregroundStyle(Theme.dim)
        }
        Text(model.glassesLine)
          .font(.caption)
          .foregroundStyle(Theme.dim)
          .multilineTextAlignment(.trailing)
        Button(model.mainButtonTitle) {
          model.toggle()
        }
        .buttonStyle(SideButton())
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 8)
    .background(Color.black.ignoresSafeArea())
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
  }
}

// MARK: - Small pieces

struct Panel<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.ion)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Theme.panel)
  }
}

struct MainButton: ButtonStyle {
  let stopping: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .foregroundStyle(stopping ? Theme.ink : Color.black)
      .background(stopping ? Theme.rose.opacity(0.22) : Theme.ion)
      .overlay(Rectangle().stroke(stopping ? Theme.rose : Color.clear, lineWidth: 1.5))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

struct SideButton: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.medium))
      .frame(maxWidth: .infinity)
      .padding(.vertical, 11)
      .foregroundStyle(Theme.ink)
      .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
      .opacity(configuration.isPressed ? 0.6 : 1)
  }
}

struct LevelBar: View {
  let level: Float

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Rectangle().fill(Theme.line)
        Rectangle()
          .fill(Theme.ion)
          .frame(width: geometry.size.width * CGFloat(min(1, max(0, level * 3))))
      }
    }
    .frame(height: 3)
    .accessibilityHidden(true)
  }
}

// MARK: - The screen

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var showSettings = false

  var body: some View {
    VStack(spacing: 0) {
      // The lens stays put while the rest scrolls. It has to stay on screen: the frames sent
      // to the glasses are pictures of it, and a view scrolled out of sight draws nothing.
      VStack(alignment: .leading, spacing: 10) {
        header
        LensMirror(webView: model.lens.webView, active: !model.showStage)
          .aspectRatio(1, contentMode: .fit)
          .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
          .frame(maxHeight: 380)
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(model.spokenLens.isEmpty ? "The Aside lens" : model.spokenLens)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      // The lens takes the room it needs first; the list below scrolls in what is left.
      .layoutPriority(1)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ControlsView()
          if !model.problem.isEmpty {
            ProblemView(text: model.problem)
          }
          GlassesView()
          TodayView()
          EarlierView()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
      }
    }
    .background(Theme.back.ignoresSafeArea())
    .sheet(isPresented: $showSettings) {
      SettingsView()
        .environmentObject(model)
    }
    .fullScreenCover(isPresented: $model.showStage) {
      StageView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
    }
    .alert("Link Aside to this Mac?", isPresented: $model.showLinkPrompt) {
      Button("Link") { model.acceptLink() }
      Button("Cancel", role: .cancel) { model.declineLink() }
    } message: {
      Text(model.linkPromptText)
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active { model.cameToFront() }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Aside")
        .font(.title.weight(.bold))
        .foregroundStyle(Theme.ink)
      Text(model.brainNote)
        .font(.footnote)
        .foregroundStyle(Theme.dim)
      Spacer()
      Button {
        model.showStage = true
      } label: {
        Image(systemName: "tv")
          .font(.title3)
          .foregroundStyle(Theme.ink)
          .padding(8)
      }
      .accessibilityLabel("Show the lens full screen, for a big screen")
      Button {
        showSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.title3)
          .foregroundStyle(Theme.ink)
          .padding(8)
      }
      .accessibilityLabel("Settings")
    }
    .padding(.top, 8)
  }
}

struct ControlsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle()
          .fill(model.isListening || model.isSampling ? Theme.ion : Theme.dim)
          .frame(width: 9, height: 9)
        Text(model.statusLine)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.ink)
        Spacer()
        Text(model.modelNote)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(Theme.dim)
      }
      if model.isListening {
        LevelBar(level: model.level)
      }
      if model.isListening || model.isSampling {
        if !model.sourceLine.isEmpty {
          Text(model.sourceLine)
            .font(.footnote)
            .foregroundStyle(Theme.dim)
        }
        if !model.heardLine.isEmpty {
          Text("“\(model.heardLine)”")
            .font(.footnote)
            .foregroundStyle(Theme.ink.opacity(0.85))
            .lineLimit(3)
        }
      }
      if !model.modelError.isEmpty {
        Text("Model: \(model.modelError)")
          .font(.caption)
          .foregroundStyle(Theme.amber)
          .lineLimit(3)
      }
      Button(model.mainButtonTitle) {
        model.toggle()
      }
      .buttonStyle(MainButton(stopping: model.isListening || model.isSampling))
      .disabled(model.isStarting)

      HStack(spacing: 10) {
        Button("Look") { model.look() }
          .buttonStyle(SideButton())
        Button("End talk") { model.endConversation() }
          .buttonStyle(SideButton())
        Button("Brief me") { model.briefNow() }
          .buttonStyle(SideButton())
      }
      if model.isListening {
        Text("Keep Aside open on this screen while it listens. The iPhone stays awake for you.")
          .font(.caption)
          .foregroundStyle(Theme.dim)
      }
    }
  }
}

struct ProblemView: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(Theme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(Theme.amber.opacity(0.14))
      .overlay(alignment: .leading) {
        Rectangle().fill(Theme.amber).frame(width: 3)
      }
  }
}

struct GlassesView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Panel("Glasses") {
      Text(model.glassesLine)
        .font(.subheadline)
        .foregroundStyle(Theme.ink)
      if !model.glassesDetail.isEmpty {
        Text(model.glassesDetail)
          .font(.footnote)
          .foregroundStyle(Theme.dim)
      }
      if !model.glasses.lastError.isEmpty {
        Text(model.glasses.lastError)
          .font(.footnote)
          .foregroundStyle(Theme.amber)
      }
      if model.needsGlassesConnect {
        Button("Connect glasses") { model.glasses.connect() }
          .buttonStyle(SideButton())
        Text("Opens the Meta AI app to approve Aside. Developer Mode must be on there: Settings, App Info, then tap the version number five times.")
          .font(.caption)
          .foregroundStyle(Theme.dim)
      }
      if model.glasses.usingMock, model.glasses.hasSession, model.showOnGlasses {
        PracticeDisplay(make: { model.glasses.mockPreviewView() })
          .aspectRatio(1, contentMode: .fit)
          .background(Color.black)
      }
    }
  }
}

struct TodayView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Panel("Today") {
      if model.events.isEmpty {
        Text(model.useCalendar
          ? "Nothing else on your calendar today."
          : "Turn on “Use my calendar” in Settings and Aside will brief you ten minutes before each event, on the glasses and as a notification.")
          .font(.footnote)
          .foregroundStyle(Theme.dim)
      }
      ForEach(model.events) { event in
        EventRow(event: event)
      }
    }
  }
}

struct EventRow: View {
  let event: DayEvent

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(event.start, style: .time)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(Theme.ion)
        Text(event.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.ink)
      }
      if !event.place.isEmpty {
        Text(event.place)
          .font(.footnote)
          .foregroundStyle(Theme.dim)
      }
      if event.prep.isEmpty {
        Text("Working out what to have ready…")
          .font(.footnote)
          .foregroundStyle(Theme.dim)
      }
      ForEach(event.prep, id: \.self) { line in
        Text("› \(line)")
          .font(.footnote)
          .foregroundStyle(Theme.ink.opacity(0.9))
      }
    }
    .padding(.vertical, 4)
  }
}

struct EarlierView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Panel("Earlier conversations") {
      if model.talks.isEmpty {
        Text("After each conversation Aside keeps a short recap here: the point, what is left for you to do, and what went unanswered. Never the audio, never the words.")
          .font(.footnote)
          .foregroundStyle(Theme.dim)
      }
      ForEach(model.talks) { talk in
        TalkRow(talk: talk)
      }
    }
  }
}

struct TalkRow: View {
  let talk: PastTalk

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(talk.at, style: .time)
          .font(.footnote)
          .monospacedDigit()
          .foregroundStyle(Theme.dim)
        Text(talk.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Theme.ink)
      }
      ForEach(talk.points, id: \.self) { line in
        Text("› \(line)")
          .font(.footnote)
          .foregroundStyle(Theme.ink.opacity(0.85))
      }
      ForEach(talk.actions, id: \.self) { line in
        Text("To do: \(line)")
          .font(.footnote)
          .foregroundStyle(Theme.ion)
      }
      if !talk.open.isEmpty {
        Text("Unanswered: \(talk.open)")
          .font(.footnote)
          .foregroundStyle(Theme.amber)
      }
    }
    .padding(.vertical, 4)
  }
}
