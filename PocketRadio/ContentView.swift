//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M6.2.5: Pocket Casts dark theme styling + time-remaining visibility.
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
                .foregroundColor(PocketCastsTheme.primaryText01)
                .padding(.top, 12)

            Text("Sign in with Pocket Casts")
                .font(.subheadline)
                .foregroundColor(PocketCastsTheme.primaryText02)

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
                    .foregroundColor(PocketCastsTheme.accent)
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
        .background(PocketCastsTheme.primaryUi01)
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
                        .foregroundColor(vm.showBrowseTabs ? PocketCastsTheme.accent : PocketCastsTheme.primaryIcon02)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)

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
                        .foregroundColor(PocketCastsTheme.primaryIcon02)
                    }
                    .buttonStyle(.plain)
                }

                // Play / Pause
                Button(action: { vm.togglePlayback() }) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(PocketCastsTheme.primaryText01)
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
                        .foregroundColor(PocketCastsTheme.primaryIcon02)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)

            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)

            // ── Bottom Section ──
            if vm.showBrowseTabs {
                browsePlaceholder
                Spacer()
            } else if vm.selectedPill == .podcast {
                upNextListView
            } else {
                nowPlayingInfo
                Spacer()
            }

            // ── Footer ──
            HStack(spacing: 16) {
                Button(action: { vm.logout() }) {
                    Text("Log Out").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(PocketCastsTheme.primaryText02)

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Text("Quit").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundColor(PocketCastsTheme.primaryText02)
                .keyboardShortcut("q")
            }
            .padding(.bottom, 6)
        }
        .frame(width: 300, height: 380)
        .background(PocketCastsTheme.primaryUi01)
    }

    // MARK: - Pill Views

    func pillButton(_ label: String, isSelected: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? PocketCastsTheme.accent : PocketCastsTheme.primaryUi04)
            .foregroundColor(.white)
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
                    .background(isSelected ? PocketCastsTheme.accent : PocketCastsTheme.primaryUi04)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .onTapGesture { vm.selectStream(index) }
            )
        } else {
            return AnyView(
                Image(systemName: "radio")
                    .font(.system(size: 10))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(PocketCastsTheme.primaryUi04)
                    .foregroundColor(PocketCastsTheme.primaryIcon02)
                    .cornerRadius(12)
            )
        }
    }

    // MARK: - Bottom Section Content

    var upNextListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.upNextEpisodes.isEmpty {
                HStack {
                    Spacer()
                    if vm.isLoadingUpNext {
                        ProgressView().scaleEffect(0.7)
                            .foregroundColor(PocketCastsTheme.primaryText02)
                        Text("Loading...")
                            .font(.system(size: 13))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                    } else {
                        Text("No episodes in Up Next")
                            .font(.system(size: 13))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.upNextEpisodes, id: \.uuid) { episode in
                            episodeRow(episode)
                        }
                    }
                }
            }
        }
    }

    func episodeRow(_ episode: UpNextEpisode) -> some View {
        let isCurrent: Bool = {
            if case .podcast(let current) = vm.currentSource, current.uuid == episode.uuid {
                return true
            }
            return false
        }()

        let artworkURL = URL(string: "https://static.pocketcasts.com/discover/images/130/\(episode.podcastUUID).jpg")

        return VStack(spacing: 0) {
            Button(action: { vm.selectEpisode(episode) }) {
                HStack(spacing: 12) {
                    AsyncImage(url: artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().interpolation(.medium)
                        case .empty, .failure:
                            RoundedRectangle(cornerRadius: 4)
                                .fill(PocketCastsTheme.primaryUi04)
                        @unknown default:
                            RoundedRectangle(cornerRadius: 4)
                                .fill(PocketCastsTheme.primaryUi04)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(PocketCastsTheme.primaryText01)
                            .lineLimit(1)

                        let timeText = vm.timeRemainingText(for: episode)
                        Text(timeText.isEmpty ? episode.podcastUUID : timeText)
                            .font(.system(size: 13))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Playing indicator
                    if isCurrent && vm.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundColor(PocketCastsTheme.accent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isCurrent ? PocketCastsTheme.primaryUi04.opacity(0.5) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Inset divider
            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)
                .padding(.leading, 72)
        }
    }

    var nowPlayingInfo: some View {
        VStack(spacing: 0) {
            if let source = vm.currentSource {
                VStack(spacing: 4) {
                    Text(vm.nowPlayingTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(PocketCastsTheme.primaryText01)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(source.isRadio ? "Live Stream" : "Up Next")
                        .font(.system(size: 13))
                        .foregroundColor(PocketCastsTheme.primaryText02)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(PocketCastsTheme.primaryUi04)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if vm.isLoadingUpNext {
                ProgressView().scaleEffect(0.7)
                    .foregroundColor(PocketCastsTheme.primaryText02)
                Text("Loading...")
                    .font(.system(size: 13))
                    .foregroundColor(PocketCastsTheme.primaryText02)
            } else {
                Text("Select a source")
                    .font(.system(size: 13))
                    .foregroundColor(PocketCastsTheme.primaryText02)
            }
        }
        .frame(maxWidth: .infinity)
    }

    var browsePlaceholder: some View {
        VStack(spacing: 12) {
            Text("Favorites / Browse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PocketCastsTheme.primaryText01)
                .padding(.top, 8)

            Text("Coming in M6.4")
                .font(.system(size: 13))
                .foregroundColor(PocketCastsTheme.primaryText02)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
