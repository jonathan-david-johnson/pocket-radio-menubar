//
//  PlayerViewModel.swift
//  PocketRadio Menubar
//
//  M6.1: Pill-based source selection + duration-aware controls + skip logic.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Pill Type

enum PillType: Equatable {
    case podcast
    case stream(Int)  // 0, 1, 2 → Stream 1, Stream 2, Stream 3
}

// MARK: - Playing Source

enum PlayingSource: Equatable {
    case podcast(UpNextEpisode)
    case radio(RadioStation)

    var isRadio: Bool {
        if case .radio = self { return true }
        return false
    }
}

@MainActor
class PlayerViewModel: ObservableObject {

    // MARK: - Auth State
    @Published var isLoggedIn: Bool = false
    @Published var userEmail: String = ""
    @Published var loginErrorMessage: String? = nil
    @Published var loginEmail: String = ""
    @Published var loginPassword: String = ""

    private var token: String?
    private var userId: String?

    // MARK: - Pill & Browse State
    @Published var selectedPill: PillType = .podcast
    @Published var showBrowseTabs: Bool = false

    // MARK: - Up Next
    @Published var topEpisode: UpNextEpisode?
    @Published var upNextEpisodes: [UpNextEpisode] = []
    @Published var isLoadingUpNext: Bool = false

    // MARK: - Radio Favorites
    @Published var favoriteStations: [RadioStation] = []
    @Published var isLoadingFavorites: Bool = false

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    @Published var currentSource: PlayingSource?
    @Published var showSkipControls: Bool = true  // ⏪ ⏯️ ⏩ vs ⏯️-only
    var audioPlayer: AVPlayer = AVPlayer()
    private var durationObserver: AnyCancellable?

    // MARK: - Now Playing Info
    @Published var nowPlayingTitle: String = ""

    // MARK: - Skip Amounts (hardcoded defaults)
    let skipBackSeconds: Double = 10
    let skipForwardSeconds: Double = 45

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
        upNextEpisodes = []
        favoriteStations = []
        currentSource = nil
        selectedPill = .podcast
        showBrowseTabs = false
        isLoggedIn = false
        isPlaying = false
        nowPlayingTitle = ""
        showSkipControls = true
    }

    // MARK: - Up Next

    func fetchUpNext() async {
        guard let token = token else { return }

        isLoadingUpNext = true
        defer { isLoadingUpNext = false }

        do {
            let episodes = try await PocketCastsAPI.fetchUpNext(token: token)
            self.upNextEpisodes = episodes
            self.topEpisode = episodes.first

            if let ep = episodes.first, currentSource == nil {
                currentSource = .podcast(ep)
                nowPlayingTitle = ep.title
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

    // MARK: - Pill Actions

    func selectPodcast() {
        guard selectedPill != .podcast else { return }
        showBrowseTabs = false
        selectedPill = .podcast

        if let ep = topEpisode {
            currentSource = .podcast(ep)
            nowPlayingTitle = ep.title
            if isPlaying { stopPlayback() }
            startPlayback()
        }
    }

    func selectStream(_ index: Int) {
        guard index < favoriteStations.count else { return }
        let pill = PillType.stream(index)
        guard selectedPill != pill else {
            // Already selected — toggle play/stop
            togglePlayback()
            return
        }

        showBrowseTabs = false
        selectedPill = pill
        let station = favoriteStations[index]
        currentSource = .radio(station)
        nowPlayingTitle = station.name
        if isPlaying { stopPlayback() }
        startPlayback()
    }

    func toggleBrowse() {
        showBrowseTabs.toggle()
    }

    // MARK: - Playback Controls

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            // If nothing playing yet, pick default
            if currentSource == nil {
                if let ep = topEpisode {
                    currentSource = .podcast(ep)
                    nowPlayingTitle = ep.title
                }
            }
            startPlayback()
        }
    }

    func skipBack() {
        guard !shouldUseMuteControls else { return }
        let newTime = CMTimeSubtract(
            audioPlayer.currentTime(),
            CMTime(seconds: skipBackSeconds, preferredTimescale: 1)
        )
        audioPlayer.seek(to: newTime)
    }

    func skipForward() {
        guard !shouldUseMuteControls else { return }
        let newTime = CMTimeAdd(
            audioPlayer.currentTime(),
            CMTime(seconds: skipForwardSeconds, preferredTimescale: 1)
        )
        audioPlayer.seek(to: newTime)
    }

    // MARK: - Duration-based Control Detection

    /// Same logic as iOS PlaybackManager.shouldUseMuteControls
    var shouldUseMuteControls: Bool {
        guard currentSource?.isRadio == true else { return false }
        guard let duration = audioPlayer.currentItem?.duration,
              duration.isValid,
              !duration.isIndefinite else {
            // Indefinite or invalid duration → live stream → mute controls
            return true
        }
        // Finite duration → seekable → skip controls
        return false
    }

    private func observeDuration() {
        // Reset to skip controls when starting new playback
        showSkipControls = true

        // Observe when the current item's duration becomes known
        durationObserver?.cancel()
        durationObserver = audioPlayer.publisher(for: \.currentItem?.duration)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateControlState()
            }
    }

    private func updateControlState() {
        showSkipControls = !shouldUseMuteControls
    }

    // MARK: - Playback Engine

    private func startPlayback() {
        let streamURL: URL? = {
            switch currentSource {
            case .podcast(let ep):
                if let url = URL(string: ep.url) { return upgradeToHTTPS(url) }
                return Constants.streamURL
            case .radio(let station):
                if let url = URL(string: station.streamURL) {
                    return upgradeToHTTPS(url)
                }
                return Constants.streamURL
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
        observeDuration()
        notifyNowPlayingChanged()
    }

    private func stopPlayback() {
        print("🎵 PocketRadio: Stopping playback")
        durationObserver?.cancel()
        audioPlayer.replaceCurrentItem(with: nil)
        isPlaying = false
        showSkipControls = true
        notifyNowPlayingChanged()
    }

    // MARK: - Notifications

    private func notifyNowPlayingChanged() {
        NotificationCenter.default.post(name: .pocketRadioNowPlayingChanged, object: nil)
    }

    // MARK: - Helpers

    /// Upgrade http:// → https:// for App Transport Security compatibility.
    private func upgradeToHTTPS(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http" else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }
}
