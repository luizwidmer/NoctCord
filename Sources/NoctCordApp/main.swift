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
            NoctCordRootView()
                .frame(minWidth: 980, minHeight: 680)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_330, height: 820)
        #endif
    }
}
