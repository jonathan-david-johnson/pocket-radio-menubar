//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M4: Login form OR player with up-next + radio favorites.
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
            playerView
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
                .onSubmit {
                    Task { await performLogin() }
                }

            if let error = vm.loginErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(width: 240)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                Task { await performLogin() }
            }) {
                HStack(spacing: 8) {
                    if isLoggingIn {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
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

    // MARK: - Player View

    var playerView: some View {
        VStack(spacing: 8) {
            Text("PocketRadio")
                .font(.headline)
                .padding(.top, 8)

            Text(vm.userEmail)
                .font(.caption)
                .foregroundColor(.secondary)

            // Now playing info
            if vm.isLoadingUpNext && vm.currentSource == nil {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.vertical, 2)
            } else {
                Text(vm.nowPlayingTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 270)

                Text(vm.nowPlayingSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Playback controls
            HStack(spacing: 8) {
                Button(action: { vm.togglePlayback() }) {
                    HStack(spacing: 4) {
                        Image(systemName: vm.isPlaying ? "stop.fill" : "play.fill")
                        Text(vm.isPlaying ? "Stop" : "Play")
                    }
                    .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: {
                    Task {
                        await vm.fetchUpNext()
                        await vm.fetchFavorites()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isLoadingUpNext || vm.isLoadingFavorites)
            }

            Divider()
                .padding(.horizontal, 12)

            // Favorites section
            HStack {
                Text("📻 Favorites")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 16)

            if vm.isLoadingFavorites {
                ProgressView()
                    .scaleEffect(0.6)
                    .padding(.vertical, 4)
            } else if vm.favoriteStations.isEmpty {
                Text("No favorites yet — add some in the iOS app!")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(vm.favoriteStations) { station in
                            HStack {
                                if let logoURL = station.logoURL, let url = URL(string: logoURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().scaledToFit().frame(width: 16, height: 16).cornerRadius(2)
                                        default:
                                            Image(systemName: "radio").font(.caption)
                                        }
                                    }
                                } else {
                                    Image(systemName: "radio")
                                        .font(.caption)
                                }

                                Text(station.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()

                                Button(action: { vm.playStation(station) }) {
                                    Image(systemName: "play.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            Button(action: { vm.logout() }) {
                Text("Log Out")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }
}
