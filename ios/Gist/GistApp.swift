//
// GistApp.swift
//
// Entry point. Configures Meta's Wearables Device Access Toolkit once, then hands
// everything to AppModel.
//

import MWDATCore
import SwiftUI
import UIKit

/// Decides which way up the app may be: upright everywhere, sideways on the stage.
final class AppDelegate: NSObject, UIApplicationDelegate {
  static var orientations: UIInterfaceOrientationMask = .portrait

  func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    AppDelegate.orientations
  }
}

@main
struct GistApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      print("[Gist] Failed to configure the Wearables SDK: \(error)")
    }
    _model = StateObject(wrappedValue: AppModel())
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .preferredColorScheme(.dark)
        // Two kinds of link open the app: Meta AI coming back after registration or a
        // permission prompt, and the "connect to this Mac" QR code.
        .onOpenURL { url in
          model.open(url)
        }
    }
  }
}
