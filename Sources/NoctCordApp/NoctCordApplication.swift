import Foundation
import SwiftUI
import NoctCordUI

#if os(macOS)
import AppKit

final class NoctCordAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
#endif

@main
struct NoctCordApplication: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(NoctCordAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("Noct Cord") {
            NoctCordRootView(
                seedPreviewData: previewDataEnabled && liveUITestConfiguration == nil,
                liveUITestConfiguration: liveUITestConfiguration
            )
                .frame(minWidth: 980, minHeight: 680)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_330, height: 820)
        #endif
    }

    private var previewDataEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["NOCTCORD_PREVIEW_DATA"] == "1"
        #else
        false
        #endif
    }

    private var liveUITestConfiguration: NoctCordTransportConfiguration? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option),
                  arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }
        guard let statePath = value(after: "NOCTCORD_UI_TEST_STATE"),
              (statePath as NSString).isAbsolutePath,
              let portText = value(after: "NOCTCORD_UI_TEST_RELAY_PORT"),
              let port = UInt16(portText),
              let displayName = value(after: "NOCTCORD_UI_TEST_DISPLAY_NAME")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !displayName.isEmpty else {
            return nil
        }
        return .liveUITest(
            stateURL: URL(fileURLWithPath: statePath, isDirectory: false)
                .standardizedFileURL,
            displayName: displayName,
            relayPort: port
        )
        #else
        return nil
        #endif
    }
}
