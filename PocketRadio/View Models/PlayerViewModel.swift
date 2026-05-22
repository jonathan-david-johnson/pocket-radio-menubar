//
//  PlayerViewModel.swift
//  PocketRadio Menubar
//
//  M4: AVPlayer + Pocket Casts auth + up-next + radio favorites.
//

import Foundation
import AVFoundation

enum PlayingSource: Equatable {
    case podcast(UpNextEpisode)
    case radio(RadioStation)

    var title: String {
        switch self {
        case .podcast(let ep): return ep.title
        case .radio(let station): return station.name
        }
    }

    var subtitle: String {
        switch self {
        case .podcast: return "Up Next"
        case .radio: return "Live Stream"
        }
    }
}

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

    // MARK: - Radio Favorites
    @Published var favoriteStations: [RadioStation] = []
    @Published var isLoadingFavorites: Bool = false

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    @Published var currentSource: PlayingSource?
    @Published var nowPlayingTitle: String = "KCRW Eclectic 24"
    @Published var nowPlayingSubtitle: String = ""
    var audioPlayer: AVPlayer = AVPlayer()

    // MARK: - Init

    init() {
        if let savedToken = KeychainManager.load(.token),
           let savedUserId = KeychainManager.load(.userId),
           let savedEmail = KeychainManager.load(.email) {
            self.token = savedToken
            self.userId = savedUserId
            self.userEmail = savedEmail
            self.isLoggedIn = true

            Task {
                await fetchUpNext()
                await fetchFavorites()
            }
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

            KeychainManager.save(result.token, for: .token)
            KeychainManager.save(result.userId, for: .userId)
            KeychainManager.save(result.email, for: .email)

            self.token = result.token
            self.userId = result.userId
            self.userEmail = result.email
            self.isLoggedIn = true
            self.loginEmail = ""
            self.loginPassword = ""

            await fetchUpNext()
            await fetchFavorites()

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
        favoriteStations = []
        currentSource = nil
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

            if let ep = episodes.first, currentSource == nil {
                currentSource = .podcast(ep)
                nowPlayingTitle = ep.title
                nowPlayingSubtitle = "Up Next"
            }
        } catch {
            print("🎵 PocketRadio: Failed to fetch up-next: \(error.localizedDescription)")
        }
    }

    // MARK: - Radio Favorites

    func fetchFavorites() async {
        guard let userId = userId else { return }

        isLoadingFavorites = true
        defer { isLoadingFavorites = false }

        do {
            let stations = try await PocketCastsAPI.fetchFavoriteStations(userId: userId)
            self.favoriteStations = stations
        } catch {
            print("🎵 PocketRadio: Failed to fetch favorites: \(error.localizedDescription)")
        }
    }

    func playStation(_ station: RadioStation) {
        currentSource = .radio(station)
        nowPlayingTitle = station.name
        nowPlayingSubtitle = "Live Stream"
        if isPlaying { stopPlayback() }
        startPlayback()
        notifyNowPlayingChanged()
    }

    func playPodcast() {
        guard let ep = topEpisode else { return }
        currentSource = .podcast(ep)
        nowPlayingTitle = ep.title
        nowPlayingSubtitle = "Up Next"
        if isPlaying { stopPlayback() }
        startPlayback()
        notifyNowPlayingChanged()
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            // If nothing selected, pick podcast first, then fall back
            if currentSource == nil {
                if let ep = topEpisode {
                    currentSource = .podcast(ep)
                    nowPlayingTitle = ep.title
                    nowPlayingSubtitle = "Up Next"
                } else {
                    nowPlayingTitle = "KCRW Eclectic 24"
                    nowPlayingSubtitle = "Fallback Stream"
                }
            }
            startPlayback()
        }
    }

    private func startPlayback() {
        let streamURL: URL? = {
            switch currentSource {
            case .podcast(let ep):
                if let url = URL(string: ep.url) { return url }
                nowPlayingTitle = "KCRW Eclectic 24"
                nowPlayingSubtitle = "Fallback Stream"
                return Constants.streamURL
            case .radio(let station):
                return URL(string: station.streamURL) ?? Constants.streamURL
            case nil:
                return Constants.streamURL
            }
        }()

        guard let url = streamURL else {
            print("🎵 PocketRadio: No playable URL")
            return
        }

        print("🎵 PocketRadio: Starting playback — \(url)")
        let playerItem = AVPlayerItem(url: url)
        audioPlayer.replaceCurrentItem(with: playerItem)
        audioPlayer.play()
        isPlaying = true
        notifyNowPlayingChanged()
    }

    private func stopPlayback() {
        print("🎵 PocketRadio: Stopping playback")
        audioPlayer.replaceCurrentItem(with: nil)
        isPlaying = false
        notifyNowPlayingChanged()
    }

    private func notifyNowPlayingChanged() {
        NotificationCenter.default.post(name: .pocketRadioNowPlayingChanged, object: nil)
    }
}
