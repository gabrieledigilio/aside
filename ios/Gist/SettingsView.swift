//
// SettingsView.swift
//
// Every choice Gist offers, in plain words: what it listens with, what goes to the glasses,
// where the thinking happens, and what it is allowed to know about your day.
//

import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        earsSection
        glassesSection
        brainSection
        daySection
        practiceSection
        memorySection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var earsSection: some View {
    Section {
      Picker("Listen with", selection: $model.ears) {
        ForEach(Ears.allCases) { choice in
          Text(choice.title).tag(choice)
        }
      }
      Picker("Language spoken", selection: $model.language) {
        Text("English").tag("en-US")
        Text("Italiano").tag("it-IT")
      }
      Toggle("Use the Bluetooth mic if the camera stream won’t start", isOn: $model.bluetoothWhenStreamFails)
      Toggle("Lift quiet voices", isOn: $model.liftQuietVoices)
      TextField("Names to listen for, with commas", text: $model.listenFor, axis: .vertical)
        .autocorrectionDisabled()
    } header: {
      Text("Ears")
    } footer: {
      Text(model.ears.detail + " The sound is thrown away as soon as it is text. iOS does that on this iPhone when it can for the language; Aside shows which while it listens. The glasses’ microphones sit next to your mouth, so you arrive much louder than the person across the table: “Lift quiet voices” evens that out before the words are recognised. In a loud room nothing replaces being close: within arm’s reach, or the iPhone’s microphone next to the speaker. Names the iPhone has never met (your company, a product, a person) come out as the nearest ordinary word unless you list them here; the list stays on this phone.")
    }
  }

  private var glassesSection: some View {
    Section {
      Toggle("Show the lens on the glasses", isOn: $model.showOnGlasses)
      Toggle("Send plain text instead of the drawn lens", isOn: $model.plainOnGlasses)
      Toggle("Buttons on the glasses, for the band", isOn: $model.buttonsOnGlasses)
      Toggle("During a conversation, show them only after a pinch", isOn: $model.barOnPinch)
        .disabled(!model.buttonsOnGlasses)
      Toggle("Look by itself during a conversation", isOn: $model.lookByItself)
      Toggle("Come back after another glasses app closes Aside", isOn: $model.returnToGlasses)
      Toggle("Stay connected to the glasses between conversations", isOn: $model.keepGlassesSession)
      Toggle("Say the question in my ear", isOn: $model.whisper)
      Toggle("Keep the camera ready", isOn: $model.cameraForLook)
    } header: {
      Text("On the glasses")
    } footer: {
      Text("Plain text is the fallback if drawn frames arrive slowly. Saying the question is for glasses with no display; it is only ever spoken through the glasses or headphones, never the iPhone’s speaker. With “Look by itself” on, the glasses take a photo about every ten seconds while a conversation is going; it is sent to the model to be read and then dropped, never stored. On today’s glasses each photo stops their microphones for a few seconds, so it is off to begin with, and Aside switches it off again if a photo costs sound. With it off, the camera is only used when you press Look or when someone says “as you can see”.")
    }
  }

  private var brainSection: some View {
    Section {
      Picker("Thinking happens", selection: $model.brainPlace) {
        Text("On this iPhone").tag(BrainPlace.phone)
        Text("On my Mac").tag(BrainPlace.mac)
      }
      SecureField("Meta Model API key", text: $model.apiKey)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Toggle("Fall back to mobile data when Wi-Fi stalls", isOn: $model.mobileDataBackup)
      Button("Test the mobile data fallback") {
        model.checkMobileData()
      }
      if !model.mobileDataCheck.isEmpty {
        Text(model.mobileDataCheck)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Text(model.linkLine)
        .font(.footnote)
        .foregroundStyle(.secondary)
      if !model.macAddress.isEmpty {
        Button("Forget this Mac", role: .destructive) {
          model.forgetLink()
        }
      }
    } header: {
      Text("Brain")
    } footer: {
      Text("With a key here, the iPhone talks to Meta’s models directly and needs no Mac. Without one, it borrows the linked Mac’s key. The key is kept in the iPhone’s keychain. On a crowded Wi-Fi network a request that gets no answer within a second and a half is also sent over mobile data, and the first answer is used.")
    }
  }

  private var daySection: some View {
    Section {
      Toggle("Use my calendar", isOn: $model.useCalendar)
      Button("Add a practice event in 12 minutes") {
        model.addPracticeEvent()
      }
    } header: {
      Text("Your day")
    } footer: {
      Text("Aside reads today’s events to brief you ten minutes before each one. It only reads. The event’s title, place and notes are sent to the model to work out what to have ready.")
    }
  }

  private var practiceSection: some View {
    Section {
      Toggle("Practice glasses", isOn: $model.practiceGlasses)
      Button("Play a sample explanation") {
        model.playSample()
        dismiss()
      }
    } header: {
      Text("Practice")
    } footer: {
      Text("Practice glasses are simulated Meta Ray-Ban Display glasses inside this iPhone, so the whole glasses path can be tried with no pair at hand. Turn them off before using real glasses. The sample plays a one-minute pitch into Aside as if someone were saying it.")
    }
  }

  private var memorySection: some View {
    Section {
      Button("Forget everything", role: .destructive) {
        model.forgetEverything()
      }
    } footer: {
      Text("Aside never stores audio or the words of a conversation. It keeps a short recap of each one on this iPhone, and this erases them.")
    }
  }
}
