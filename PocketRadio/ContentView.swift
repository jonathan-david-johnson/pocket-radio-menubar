//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M6.1: Pill-based source selection + context-sensitive transport controls.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm: PlayerViewModel
    @State private var isLoggingIn = false

    init(vm: PlayerViewModel) {
        self._vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        if vm.isLoggedIn {
            mainView
        } else {
            loginView
        }
    }

    // MARK: - Login View

    var loginView: some View {
        VStack(spacing: 12) {
            Text("PocketRadio")
                .font(.headline)
                .padding(.top, 12)

            Text("Sign in with Pocket Casts")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextField("Email", text: $vm.loginEmail)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(isLoggingIn)

            SecureField("Password", text: $vm.loginPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(isLoggingIn)
                .onSubmit { Task { await performLogin() } }

            if let error = vm.loginErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(width: 240)
                    .multilineTextAlignment(.center)
            }

            Button(action: { Task { await performLogin() } }) {
                HStack(spacing: 8) {
                    if isLoggingIn {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    }
                    Text(isLoggingIn ? "Logging in..." : "Log In")
                }
                .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoggingIn)
            .padding(.bottom, 12)
        }
        .frame(width: 300)
    }

    private func performLogin() async {
        isLoggingIn = true
        await vm.login()
        isLoggingIn = false
    }

    // MARK: - Main View

    var mainView: some View {
        VStack(spacing: 0) {
            // ── Top Row: Pills ──
            HStack(spacing: 4) {
                pillButton("Podcast", isSelected: vm.selectedPill == .podcast)
                    .onTapGesture { vm.selectPodcast() }

                ForEach(0..<3, id: \.self) { index in
                    streamPill(index)
                }

                // ⋮ browse button
                Button(action: { vm.toggleBrowse() }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(vm.showBrowseTabs ? .accentColor : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // ── Controls Row ──
            HStack(spacing: 24) {
                // Skip Back
                if vm.showSkipControls {
                    Button(action: { vm.skipBack() }) {
                        VStack(spacing: 0) {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 18))
                            Text("\(Int(vm.skipBackSeconds))s")
                                .font(.system(size: 8))
                        }
                    }
                    .buttonStyle(.plain)
                }

                // Play / Pause
                Button(action: { vm.togglePlayback() }) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)

                // Skip Forward
                if vm.showSkipControls {
                    Button(action: { vm.skipForward() }) {
                        VStack(spacing: 0) {
                            Image(systemName: "goforward.45")
                                .font(.system(size: 18))
                            Text("\(Int(vm.skipForwardSeconds))s")
                                .font(.system(size: 8))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)

            Divider()

            // ── Bottom Section (placeholder for M6.2/M6.3/M6.4) ──
            if vm.showBrowseTabs {
                browsePlaceholder
            } else {
                nowPlayingInfo
            }

            Spacer()

            // ── Footer ──
            HStack(spacing: 16) {
                Button(action: { vm.logout() }) {
                    Text("Log Out").font(.caption)
                }
                .buttonStyle(.plain)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Text("Quit").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
            .padding(.bottom, 6)
        }
        .frame(width: 300, height: 380)
    }

    // MARK: - Pill Views

    func pillButton(_ label: String, isSelected: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(12)
    }

    func streamPill(_ index: Int) -> some View {
        let isSelected = vm.selectedPill == .stream(index)

        if index < vm.favoriteStations.count {
            let station = vm.favoriteStations[index]
            return AnyView(
                Text(station.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundColor(isSelected ? .white : .primary)
                    .cornerRadius(12)
                    .onTapGesture { vm.selectStream(index) }
            )
        } else {
            return AnyView(
                Image(systemName: "radio")
                    .font(.system(size: 10))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.15))
                    .foregroundColor(.secondary)
                    .cornerRadius(12)
            )
        }
    }

    // MARK: - Bottom Section Content

    var nowPlayingInfo: some View {
        VStack(spacing: 6) {
            if let source = vm.currentSource {
                Text(vm.nowPlayingTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                Text(source.isRadio ? "Live Stream" : "Up Next")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if vm.isLoadingUpNext {
                ProgressView().scaleEffect(0.7)
                Text("Loading...").font(.caption).foregroundColor(.secondary)
            } else {
                Text("Select a source")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    var browsePlaceholder: some View {
        VStack(spacing: 12) {
            Text("Favorites / Browse")
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.top, 8)

            Text("Coming in M6.4")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
