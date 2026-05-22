//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M2: Login form OR player view, toggled by auth state.
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
        VStack(spacing: 12) {
            Text("PocketRadio")
                .font(.headline)
                .padding(.top, 12)

            Text(vm.userEmail)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("KCRW Eclectic 24")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: {
                vm.togglePlayback()
            }) {
                HStack(spacing: 8) {
                    Image(
                        systemName: vm.isPlaying
                            ? "stop.fill" : "play.fill"
                    )
                    Text(vm.isPlaying ? "Stop" : "Play")
                }
                .frame(width: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

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
