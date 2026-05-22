//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M3: Login form OR player with up-next episode display.
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
        VStack(spacing: 10) {
            Text("PocketRadio")
                .font(.headline)
                .padding(.top, 12)

            Text(vm.userEmail)
                .font(.caption)
                .foregroundColor(.secondary)

            // Now playing info
            if vm.isLoadingUpNext {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.vertical, 4)
            } else {
                Text(vm.nowPlayingTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 260)

                Text(vm.nowPlayingSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Controls
            HStack(spacing: 12) {
                Button(action: {
                    vm.togglePlayback()
                }) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: vm.isPlaying
                                ? "stop.fill" : "play.fill"
                        )
                        Text(vm.isPlaying ? "Stop" : "Play")
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(action: {
                    Task { await vm.fetchUpNext() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(vm.isLoadingUpNext)
            }

            Button(action: {
                vm.logout()
            }) {
                Text("Log Out")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(width: 300)
    }
}
