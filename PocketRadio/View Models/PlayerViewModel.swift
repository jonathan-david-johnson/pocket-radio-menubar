//
//  PlayerViewModel.swift
//  PocketRadio Menubar
//
//  M3: AVPlayer wrapper + Pocket Casts auth + up-next fetch.
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

    // MARK: - Up Next
    @Published var topEpisode: UpNextEpisode?
    @Published var isLoadingUpNext: Bool = false

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    @Published var nowPlayingTitle: String = "KCRW Eclectic 24"
    @Published var nowPlayingSubtitle: String = ""
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

            // Fetch up-next in background after launch
            Task { await fetchUpNext() }
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

            // Store in Keychain
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

            // Fetch up-next after login
            await fetchUpNext()

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
        topEpisode = nil
        isLoggedIn = false
        isPlaying = false
        nowPlayingTitle = "KCRW Eclectic 24"
        nowPlayingSubtitle = ""
    }

    // MARK: - Up Next

    func fetchUpNext() async {
        guard let token = token else { return }

        isLoadingUpNext = true
        defer { isLoadingUpNext = false }

        do {
            let episodes = try await PocketCastsAPI.fetchUpNext(token: token)
            self.topEpisode = episodes.first

            if let ep = episodes.first {
                nowPlayingTitle = ep.title
                nowPlayingSubtitle = "Up Next"
            }
        } catch {
            print("🎵 PocketRadio: Failed to fetch up-next: \(error.localizedDescription)")
        }
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
        // Prefer up-next episode URL, fall back to KCRW stream
        let streamURL: URL
        if let episodeURL = topEpisode?.url, !episodeURL.isEmpty, let url = URL(string: episodeURL) {
            streamURL = url
        } else if let kcrwURL = Constants.streamURL {
            streamURL = kcrwURL
        } else {
            print("🎵 PocketRadio: No playable URL")
            return
        }

        print("🎵 PocketRadio: Starting playback — \(streamURL)")
        let playerItem = AVPlayerItem(url: streamURL)
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
