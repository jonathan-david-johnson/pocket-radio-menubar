//
//  PocketRadioApp.swift
//  PocketRadio Menubar
//
//  M1: Skeleton menubar app — plays one hardcoded stream.
//

import SwiftUI
import AVFoundation

@main
struct PocketRadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var playerVM: PlayerViewModel!

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎵 PocketRadio: Launching menubar app")

        self.playerVM = PlayerViewModel()

        statusItem = NSStatusBar.system.statusItem(withLength: 140)

        if let statusButton = statusItem.button {
            // Use wide text label — unmistakable in screenshots
            statusButton.title = "📻 Radio"
            statusButton.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 250)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView(vm: self.playerVM)
        )
    }

    @MainActor @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Anchor to right edge to prevent jumping
            let rect = NSRect(
                x: button.bounds.maxX - 300,
                y: button.bounds.minY,
                width: 300,
                height: button.bounds.height
            )
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        }
    }
}
