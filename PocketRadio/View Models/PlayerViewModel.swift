//
//  PlayerViewModel.swift
//  PocketRadio Menubar
//
//  M2: AVPlayer wrapper + Pocket Casts auth state management.
//

import Foundation
import AVFoundation

@MainActor
class PlayerViewModel: ObservableObject {

    // MARK: - Auth State
    @Published var isLoggedIn: Bool = false
    @Published var userEmail: String = ""
    @Published var loginErrorMessage: String? = nil

    // MARK: - Login Fields
    @Published var loginEmail: String = ""
    @Published var loginPassword: String = ""

    private var token: String?
    private var userId: String?

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    var audioPlayer: AVPlayer = AVPlayer()

    // MARK: - Init

    init() {
        // Check for existing session on launch
        if let savedToken = KeychainManager.load(.token),
           let savedUserId = KeychainManager.load(.userId),
           let savedEmail = KeychainManager.load(.email) {
            self.token = savedToken
            self.userId = savedUserId
            self.userEmail = savedEmail
            self.isLoggedIn = true
        }
    }

    // MARK: - Login / Logout

    func login() async {
        loginErrorMessage = nil

        guard !loginEmail.isEmpty, !loginPassword.isEmpty else {
            loginErrorMessage = "Email and password are required."
            return
        }

        do {
            let result = try await PocketCastsAPI.login(
                email: loginEmail,
                password: loginPassword
            )

            // Store in Keychain (persists across launches)
            KeychainManager.save(result.token, for: .token)
            KeychainManager.save(result.userId, for: .userId)
            KeychainManager.save(result.email, for: .email)

            // Update state
            self.token = result.token
            self.userId = result.userId
            self.userEmail = result.email
            self.isLoggedIn = true
            self.loginEmail = ""
            self.loginPassword = ""

        } catch let error as LoginError {
            loginErrorMessage = error.errorDescription
        } catch {
            loginErrorMessage = "Login failed: \(error.localizedDescription)"
        }
    }

    func logout() {
        stopPlayback()
        KeychainManager.clearAll()
        token = nil
        userId = nil
        userEmail = ""
        isLoggedIn = false
        isPlaying = false
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let url = Constants.streamURL else {
            print("🎵 PocketRadio: Invalid stream URL")
            return
        }

        print("🎵 PocketRadio: Starting playback — \(url)")
        let playerItem = AVPlayerItem(url: url)
        audioPlayer.replaceCurrentItem(with: playerItem)
        audioPlayer.play()
        isPlaying = true
    }

    private func stopPlayback() {
        print("🎵 PocketRadio: Stopping playback")
        audioPlayer.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}
