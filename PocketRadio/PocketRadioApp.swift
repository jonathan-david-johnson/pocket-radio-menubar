//
//  PocketRadioApp.swift
//  PocketRadio Menubar
//
//  M1: Skeleton menubar app — plays one hardcoded stream.
//  M6.x: NSPanel container (replaces NSPopover) so popup position is independent
//        of the status item width changes.
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
    private var panel: NSPanel!
    private var playerVM: PlayerViewModel!
    private var scrollTask: Task<Void, Never>?
    private let maxTitleLength = 22

    private let playingStatusLength: CGFloat = 160
    // Matches ContentView.swift's frame(width: 300, height: 380) so the panel
    // edges line up exactly with the dark content (no grey strips above/below).
    private let panelSize = NSSize(width: 300, height: 380)
    private var outsideClickMonitor: Any?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎵 PocketRadio: Launching menubar app")

        self.playerVM = PlayerViewModel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let statusButton = statusItem.button {
            statusButton.action = #selector(togglePanel)
            statusButton.target = self
        }
        applyIdleIcon()

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: ContentView(vm: self.playerVM))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 8
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        // Observe playback changes to update menubar title
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuBarTitle),
            name: .pocketRadioNowPlayingChanged,
            object: nil
        )
    }

    // MARK: - Panel show / hide

    @MainActor @objc func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    @MainActor private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        // Position panel so its right edge aligns with the status item button's
        // right edge in screen coords, and its top edge sits just below the
        // menubar.
        let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let originX = buttonFrameInScreen.maxX - panelSize.width
        let originY = buttonFrameInScreen.minY - panelSize.height - 4 // small gap

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()

        // Refresh Up Next on every open so the menubar reflects whatever has
        // happened on the phone / other devices since the last view.
        Task { @MainActor in
            await self.playerVM.fetchUpNext()
        }

        installOutsideClickMonitor()
    }

    @MainActor private func hidePanel() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // Global monitor fires for clicks anywhere outside this app's windows;
        // perfect for "click outside the panel to dismiss".
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Menubar Title

    @MainActor @objc func updateMenuBarTitle() {
        scrollTask?.cancel()

        guard let button = statusItem.button else { return }

        if playerVM.isPlaying {
            let title = "▶ " + playerVM.nowPlayingTitle
            button.image = nil
            statusItem.length = playingStatusLength

            if title.count <= maxTitleLength {
                button.attributedTitle = menuBarAttributedString(title)
            } else {
                scrollTask = Task { await scrollTitle(title) }
            }
        } else {
            applyIdleIcon()
            statusItem.length = NSStatusItem.variableLength
        }
        // With NSPanel, status item width changes don't move the popup —
        // the panel has its own absolute screen position.
    }

    /// Show the Pocket Casts icon, no title.
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
            // Template mode lets macOS tint the (red-stripped, white-curves)
            // icon to match menubar appearance (dark/light).
            resized.isTemplate = true
            button.image = resized
        }
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

