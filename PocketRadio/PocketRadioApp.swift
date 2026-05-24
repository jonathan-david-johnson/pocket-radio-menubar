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
    private var scrollTask: Task<Void, Never>?
    private let maxTitleLength = 22

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎵 PocketRadio: Launching menubar app")

        self.playerVM = PlayerViewModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let statusButton = statusItem.button {
            statusButton.action = #selector(togglePopover)
        }
        applyIdleIcon()

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView(vm: self.playerVM)
        )

        // Observe playback changes to update menubar title
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarTitle),
            name: .pocketRadioNowPlayingChanged,
            object: nil
        )
    }

    @MainActor @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Anchor a zero-width rect at the button's right edge so the popover
            // pins its right side there. Otherwise centering an anchor rect over
            // the button shifts horizontally when the button grows/shrinks
            // (icon → scrolling title).
            let rect = NSRect(
                x: button.bounds.maxX,
                y: button.bounds.minY,
                width: 0,
                height: button.bounds.height
            )
            popover.show(relativeTo: rect, of: button, preferredEdge: .minY)

            // Resync Up Next + per-podcast playback positions on every open so the menubar
            // reflects what was played on phone / other devices since last refresh.
            Task { @MainActor in
                await self.playerVM.fetchUpNext()
            }
        }
    }

    // MARK: - Menubar Title

    @MainActor @objc func updateMenuBarTitle() {
        scrollTask?.cancel()

        guard let button = statusItem.button else { return }

        if playerVM.isPlaying {
            let title = "▶ " + playerVM.nowPlayingTitle
            button.image = nil
            statusItem.length = 160

            if title.count <= maxTitleLength {
                button.attributedTitle = menuBarAttributedString(title)
            } else {
                scrollTask = Task { await scrollTitle(title) }
            }
        } else {
            scrollTask?.cancel()
            applyIdleIcon()
        }
    }

    /// Show the Pocket Casts icon, no title, and shrink to icon width.
    @MainActor private func applyIdleIcon() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        if let icon = NSImage(named: "PocketCastsIcon") {
            // Menubar height is ~22pt on standard bars. Render at 18pt for breathing room.
            let target = NSSize(width: 18, height: 18)
            let resized = NSImage(size: target)
            resized.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: target))
            resized.unlockFocus()
            // Template mode lets macOS tint the (now red-stripped, white-curves)
            // icon to match menubar appearance (dark/light).
            resized.isTemplate = true
            button.image = resized
        }
        statusItem.length = NSStatusItem.variableLength
    }

    private func menuBarAttributedString(_ text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: paragraphStyle,
            .baselineOffset: 0
        ])
    }

    @MainActor
    private func scrollTitle(_ fullTitle: String) async {
        guard let button = statusItem.button else { return }
        let maxIndex = fullTitle.count - maxTitleLength

        for i in 0...maxIndex {
            if Task.isCancelled { return }

            let startIndex = fullTitle.index(fullTitle.startIndex, offsetBy: i)
            let endIndex = fullTitle.index(startIndex, offsetBy: maxTitleLength)
            let substring = String(fullTitle[startIndex..<endIndex])

            button.attributedTitle = menuBarAttributedString(substring)

            if i == 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s pause at start
            } else {
                try? await Task.sleep(nanoseconds: 250_000_000)    // 0.25s per scroll step
            }
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000) // pause at end

        if !Task.isCancelled {
            await scrollTitle(fullTitle) // loop
        }
    }
}
