// Updates: checks for new versions of Tend with Sparkle.
//
// Sparkle reads its settings from Info.plist: SUFeedURL is the appcast that
// lists releases, and SUPublicEDKey is the public half of the key that
// app/appcast.sh signs each release with. Until SUPublicEDKey holds a real
// key, Tend doesn't start Sparkle, and the Updates settings are unavailable.

import Combine
import Sparkle
import SwiftUI

@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?

    /// False while a check or an update is already under way.
    @Published private(set) var canCheck = false

    /// Whether this build can update itself: Info.plist has a real
    /// SUPublicEDKey, a base64 Ed25519 public key of 32 bytes.
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    private override init() {
        super.init()
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() {
        Self.bringToFront()
        controller?.checkForUpdates(nil)
    }

    /// Tend is a menu bar app (LSUIElement), so it usually isn't the active
    /// app, and Sparkle's windows would open behind other apps' windows.
    private static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: SPUStandardUserDriverDelegate

    // Sparkle asks background apps to declare gentle reminders. Tend's
    // reminder is to bring the update window to the front when Sparkle shows
    // it, including after a scheduled check.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated { Self.bringToFront() }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { Self.bringToFront() }
    }
}

/// The Updates section of the General settings pane.
struct UpdatesSection: View {
    @ObservedObject private var updates = Updates.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.automaticallyChecks },
                set: { updates.automaticallyChecks = $0 }))
                .disabled(!updates.isAvailable)
                .help(updates.isAvailable
                      ? "Check for a new version of Tend once a day, and offer to install it."
                      : Self.unavailable)
            LabeledContent("Tend \(version)") {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
                    .help(updates.isAvailable
                          ? "Check now for a new version of Tend."
                          : Self.unavailable)
            }
        }
    }

    private static let unavailable =
        "This build of Tend can't update itself, because its Info.plist has no SUPublicEDKey. Release builds have one."
}
