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
    @Published var episodeDurations: [String: Int] = [:] // uuid -> seconds from AVAsset

    // MARK: - Radio Favorites
    @Published var favoriteStations: [RadioStation] = []
    @Published var isLoadingFavorites: Bool = false

    // MARK: - Tracklist (radio streams w/ supported tracklist API)
    @Published var tracklist: [TracklistEntry] = []
    @Published var isLoadingTracklist: Bool = false
    private var tracklistStationId: String?
    private var tracklistRefreshTask: Task<Void, Never>?

    // MARK: - Browse / Favorites panel
    enum BrowseTab { case favorites, browse }
    @Published var browseTab: BrowseTab = .favorites
    @Published var browseQuery: String = ""
    @Published var browseResults: [RadioStation] = []
    @Published var isBrowseLoading: Bool = false
    private var browseSearchTask: Task<Void, Never>?

    // MARK: - Podcast section tabs
    enum PodcastTab { case upNext, newReleases }
    @Published var podcastTab: PodcastTab = .upNext
    @Published var newReleases: [NewReleaseEpisode] = []
    @Published var isLoadingNewReleases: Bool = false

    // MARK: - Playback
    @Published var isPlaying: Bool = false
    @Published var currentSource: PlayingSource?
    @Published var showSkipControls: Bool = true  // ⏪ ⏯️ ⏩ vs ⏯️-only
    var audioPlayer: AVPlayer = AVPlayer()
    private var durationObserver: AnyCancellable?
    private var timeObserverToken: Any?

    // Throttle for sync/update_episode writes
    private var lastPositionSaveTime: Date?
    private let minPositionSaveInterval: TimeInterval = 30
    private var lastSavedPosition: Int = -1

    // MARK: - Now Playing Info
    @Published var nowPlayingTitle: String = ""

    // MARK: - Skip Amounts (hardcoded defaults)
    let skipBackSeconds: Double = 10
    let skipForwardSeconds: Double = 45

    // MARK: - Init

    init() {
        // Dev convenience: auto-login with hardcoded test credentials.
        // Keychain reads trigger macOS permission popups; skip them.
        self.loginEmail = Constants.testEmail
        self.loginPassword = Constants.testPassword

        Task {
            await login()
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

            // up_next/sync rarely returns episodeSync entries. Fetch per-podcast playback
            // data via user/podcast/episodes for any episode still missing playedUpTo+duration.
            await fetchPodcastPlaybackData()

            // Probe audio file headers for any durations still missing.
            fetchEpisodeDurations()
        } catch {
            print("🎵 PocketRadio: Failed to fetch up-next: \(error.localizedDescription)")
        }
    }

    private func fetchPodcastPlaybackData() async {
        guard let token = token else { return }
        let podcastUUIDs = Set(upNextEpisodes.map { $0.podcastUUID }).filter { !$0.isEmpty }
        guard !podcastUUIDs.isEmpty else { return }

        var infoByUUID: [String: EpisodePlaybackInfo] = [:]
        await withTaskGroup(of: [EpisodePlaybackInfo].self) { group in
            for uuid in podcastUUIDs {
                group.addTask {
                    do {
                        return try await PocketCastsAPI.fetchPodcastEpisodes(token: token, podcastUUID: uuid)
                    } catch {
                        print("🎵 PocketRadio: fetchPodcastEpisodes failed for \(uuid): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await infos in group {
                for info in infos {
                    infoByUUID[info.uuid] = info
                }
            }
        }

        print("🎵 PocketRadio: user/podcast/episodes returned playback data for \(infoByUUID.count) episodes across \(podcastUUIDs.count) podcasts")

        upNextEpisodes = upNextEpisodes.map { ep in
            guard let info = infoByUUID[ep.uuid] else { return ep }
            let merged = UpNextEpisode(
                uuid: ep.uuid,
                title: ep.title,
                url: ep.url,
                podcastUUID: ep.podcastUUID,
                playedUpTo: info.playedUpTo > 0 ? info.playedUpTo : ep.playedUpTo,
                duration: info.duration > 0 ? info.duration : ep.duration
            )
            print("🎵 PocketRadio:   merged ep=\(ep.title.prefix(30)) playedUpTo=\(merged.playedUpTo)s duration=\(merged.duration)s")
            return merged
        }
        topEpisode = upNextEpisodes.first
        // If the currently playing source is a podcast, refresh its episode reference so seek-on-start
        // uses fresh playedUpTo on the next play.
        if case .podcast(let cur) = currentSource,
           let refreshed = upNextEpisodes.first(where: { $0.uuid == cur.uuid }) {
            currentSource = .podcast(refreshed)
        }
    }

    // MARK: - Radio Favorites

    private static let favoritesOrderKeyPrefix = "radio_favorites_order_"

    private func favoritesOrderKey(_ userId: String) -> String {
        Self.favoritesOrderKeyPrefix + userId
    }

    private func savedFavoritesOrder(userId: String) -> [String]? {
        UserDefaults.standard.array(forKey: favoritesOrderKey(userId)) as? [String]
    }

    private func persistFavoritesOrder(_ ids: [String], userId: String) {
        UserDefaults.standard.set(ids, forKey: favoritesOrderKey(userId))
    }

    func fetchFavorites() async {
        guard let userId = userId else { return }

        isLoadingFavorites = true
        defer { isLoadingFavorites = false }

        do {
            let stations = try await PocketCastsAPI.fetchFavoriteStations(userId: userId)
            self.favoriteStations = applySavedOrder(to: stations, userId: userId)
        } catch {
            print("🎵 PocketRadio: Failed to fetch favorites: \(error.localizedDescription)")
        }
    }

    private func applySavedOrder(to stations: [RadioStation], userId: String) -> [RadioStation] {
        guard let order = savedFavoritesOrder(userId: userId), !order.isEmpty else {
            return stations
        }
        let byId = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        var sorted: [RadioStation] = order.compactMap { byId[$0] }
        let known = Set(order)
        for s in stations where !known.contains(s.id) {
            sorted.append(s)
        }
        persistFavoritesOrder(sorted.map(\.id), userId: userId)
        return sorted
    }

    func reorderFavorites(from source: IndexSet, to destination: Int) {
        favoriteStations.move(fromOffsets: source, toOffset: destination)
        if let userId = userId {
            persistFavoritesOrder(favoriteStations.map(\.id), userId: userId)
        }
    }

    // MARK: - Pill Actions

    func selectPodcast() {
        guard selectedPill != .podcast else { return }
        showBrowseTabs = false
        selectedPill = .podcast
        stopTracklist()

        if let ep = topEpisode {
            if isPlaying { stopPlayback() }
            currentSource = .podcast(ep)
            nowPlayingTitle = ep.title
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
        if isPlaying { stopPlayback() }
        currentSource = .radio(station)
        nowPlayingTitle = station.name
        startPlayback()
        startTracklist(for: station)
    }

    // MARK: - Tracklist

    private func startTracklist(for station: RadioStation) {
        tracklistRefreshTask?.cancel()
        tracklistRefreshTask = nil

        guard PocketCastsAPI.tracklistURL(for: station) != nil else {
            tracklist = []
            tracklistStationId = nil
            return
        }

        tracklistStationId = station.id
        tracklist = []
        isLoadingTracklist = true

        tracklistRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let entries = await PocketCastsAPI.fetchTracklist(for: station)
                if Task.isCancelled { return }
                await MainActor.run {
                    self.tracklist = entries
                    self.isLoadingTracklist = false
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    private func stopTracklist() {
        tracklistRefreshTask?.cancel()
        tracklistRefreshTask = nil
        tracklist = []
        tracklistStationId = nil
        isLoadingTracklist = false
    }

    func selectEpisode(_ episode: UpNextEpisode) {
        // Already selected? Toggle play/pause.
        if case .podcast(let current) = currentSource, current.uuid == episode.uuid {
            togglePlayback()
            return
        }

        if isPlaying { stopPlayback() }
        stopTracklist()

        // Bubble tapped episode to top of local Up Next (matches iOS behavior).
        if let idx = upNextEpisodes.firstIndex(where: { $0.uuid == episode.uuid }), idx > 0 {
            var list = upNextEpisodes
            let tapped = list.remove(at: idx)
            list.insert(tapped, at: 0)
            upNextEpisodes = list
            topEpisode = list.first
        }

        currentSource = .podcast(episode)
        nowPlayingTitle = episode.title
        startPlayback()

        // Sync the reorder to the server so the phone sees the same Up Next.
        if let token = token {
            Task {
                do {
                    try await PocketCastsAPI.playNowAction(token: token, episode: episode)
                    print("🎵 PocketRadio: playNow synced for \(episode.title.prefix(30))")
                } catch {
                    print("🎵 PocketRadio: playNow failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Episode Durations (AVAsset probing)

    func fetchEpisodeDurations() {
        for episode in upNextEpisodes {
            guard episode.duration == 0, episodeDurations[episode.uuid] == nil else { continue }
            Task {
                if let (uuid, duration) = await loadDuration(for: episode) {
                    episodeDurations[uuid] = duration
                }
            }
        }
    }

    private func loadDuration(for episode: UpNextEpisode) async -> (String, Int)? {
        guard var url = URL(string: episode.url) else { return nil }
        url = upgradeToHTTPS(url)

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        do {
            let duration = try await asset.load(.duration)
            let seconds = Int(CMTimeGetSeconds(duration))
            guard seconds > 0 else { return nil }
            print("🎵 PocketRadio: Duration loaded \(seconds)s for \(episode.uuid)")
            return (episode.uuid, seconds)
        } catch {
            print("🎵 PocketRadio: Failed to load duration for \(episode.uuid) at \(url): \(error)")
            return nil
        }
    }

    // MARK: - Time Formatting

    var totalTimeRemainingText: String {
        let total = upNextEpisodes.reduce(0) { sum, ep in
            let duration = ep.duration > 0 ? ep.duration : episodeDurations[ep.uuid] ?? 0
            return sum + max(0, duration - ep.playedUpTo)
        }
        guard total > 0 else { return "" }
        return "\(formatDuration(total)) total time remaining"
    }

    func timeRemainingText(for episode: UpNextEpisode) -> String {
        // For the currently playing episode, use real-time position
        var playedUpTo = episode.playedUpTo
        if case .podcast(let currentEp) = currentSource,
           currentEp.uuid == episode.uuid,
           isPlaying {
            playedUpTo = Int(audioPlayer.currentTime().seconds)
        }

        // If sync gave us a duration, server-side data is authoritative; "X left" is accurate.
        if episode.duration > 0 {
            let remaining = max(0, episode.duration - playedUpTo)
            if remaining == 0 { return "Finished" }
            return "\(formatDuration(remaining)) left"
        }

        // No sync duration. Use AVAsset-probed duration if available.
        if let probed = episodeDurations[episode.uuid], probed > 0 {
            if playedUpTo > 0 {
                let remaining = max(0, probed - playedUpTo)
                if remaining == 0 { return "Finished" }
                return "\(formatDuration(remaining)) left"
            }
            // No playedUpTo info — show plain total, do NOT imply progress.
            return formatDuration(probed)
        }

        if playedUpTo > 0 {
            return "\(formatDuration(playedUpTo)) in"
        }
        return ""
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.objectWillChange.send()
            self.maybeSavePosition()
        }
    }

    // MARK: - Position Save (sync/update_episode)

    private func maybeSavePosition() {
        guard isPlaying,
              case .podcast(let ep) = currentSource,
              !ep.podcastUUID.isEmpty else { return }

        let now = Date()
        if let last = lastPositionSaveTime, now.timeIntervalSince(last) < minPositionSaveInterval {
            return
        }

        let position = Int(audioPlayer.currentTime().seconds)
        guard position > 0, position != lastSavedPosition else { return }

        lastPositionSaveTime = now
        lastSavedPosition = position
        savePosition(for: ep, position: position, status: .inProgress)
    }

    private func savePositionNow(for episode: UpNextEpisode, position: Int, status: EpisodePlayingStatus) {
        lastPositionSaveTime = Date()
        lastSavedPosition = position
        savePosition(for: episode, position: position, status: status)
    }

    private func savePosition(for episode: UpNextEpisode, position: Int, status: EpisodePlayingStatus) {
        guard let token = token, !episode.podcastUUID.isEmpty else { return }
        let duration = episode.duration > 0 ? episode.duration : (episodeDurations[episode.uuid] ?? 0)

        // Update local upNextEpisodes so UI reflects new position immediately
        upNextEpisodes = upNextEpisodes.map { ep in
            guard ep.uuid == episode.uuid else { return ep }
            return UpNextEpisode(
                uuid: ep.uuid,
                title: ep.title,
                url: ep.url,
                podcastUUID: ep.podcastUUID,
                playedUpTo: position,
                duration: ep.duration > 0 ? ep.duration : duration
            )
        }
        if case .podcast(let cur) = currentSource,
           cur.uuid == episode.uuid,
           let refreshed = upNextEpisodes.first(where: { $0.uuid == episode.uuid }) {
            currentSource = .podcast(refreshed)
        }

        Task {
            do {
                try await PocketCastsAPI.updateEpisodePosition(
                    token: token,
                    episodeUUID: episode.uuid,
                    podcastUUID: episode.podcastUUID,
                    position: position,
                    duration: duration,
                    status: status
                )
                print("🎵 PocketRadio: saved position \(position)s status=\(status.rawValue) for \(episode.title.prefix(30))")
            } catch {
                print("🎵 PocketRadio: save position failed: \(error.localizedDescription)")
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            let hours = seconds / 3600
            let mins = (seconds % 3600) / 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }

    // MARK: - Podcast Tabs

    func selectPodcastTab(_ tab: PodcastTab) {
        podcastTab = tab
        if tab == .newReleases && newReleases.isEmpty {
            Task { await fetchNewReleases() }
        }
    }

    func fetchNewReleases() async {
        guard let token = token else { return }
        isLoadingNewReleases = true
        defer { isLoadingNewReleases = false }
        let episodes = await PocketCastsAPI.fetchNewReleases(token: token)
        self.newReleases = episodes
        print("🎵 PocketRadio: New Releases loaded \(episodes.count) episodes")
    }

    /// Play a New Releases episode by bubbling it to top of Up Next via playNow.
    func playNewReleaseEpisode(_ release: NewReleaseEpisode) {
        let upNext = UpNextEpisode(
            uuid: release.uuid,
            title: release.title,
            url: release.url,
            podcastUUID: release.podcastUUID,
            playedUpTo: 0,
            duration: release.duration
        )

        // Insert at top of local list (or move if already there)
        if let idx = upNextEpisodes.firstIndex(where: { $0.uuid == release.uuid }) {
            upNextEpisodes.remove(at: idx)
        }
        upNextEpisodes.insert(upNext, at: 0)
        topEpisode = upNextEpisodes.first

        if isPlaying { stopPlayback() }
        stopTracklist()
        currentSource = .podcast(upNext)
        nowPlayingTitle = upNext.title
        startPlayback()

        if let token = token {
            Task {
                do {
                    try await PocketCastsAPI.playNowAction(token: token, episode: upNext)
                    print("🎵 PocketRadio: playNow synced for new release \(upNext.title.prefix(30))")
                } catch {
                    print("🎵 PocketRadio: playNow failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleBrowse() {
        showBrowseTabs.toggle()
        if showBrowseTabs && browseTab == .browse && browseResults.isEmpty {
            Task { await loadTopStations() }
        }
    }

    // MARK: - Browse / Favorites

    func selectBrowseTab(_ tab: BrowseTab) {
        browseTab = tab
        if tab == .browse && browseResults.isEmpty {
            Task { await loadTopStations() }
        }
    }

    func loadTopStations() async {
        isBrowseLoading = true
        defer { isBrowseLoading = false }
        do {
            browseResults = try await PocketCastsAPI.topStations()
        } catch {
            print("🎵 PocketRadio: top stations failed: \(error.localizedDescription)")
            browseResults = []
        }
    }

    func updateBrowseQuery(_ query: String) {
        browseQuery = query
        browseSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            if trimmed.isEmpty {
                Task { await loadTopStations() }
            }
            return
        }
        browseSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await self?.runSearch(query: trimmed)
        }
    }

    private func runSearch(query: String) async {
        isBrowseLoading = true
        defer { isBrowseLoading = false }
        do {
            browseResults = try await PocketCastsAPI.searchStations(query: query)
        } catch {
            print("🎵 PocketRadio: station search failed: \(error.localizedDescription)")
            browseResults = []
        }
    }

    func isFavorite(stationId: String) -> Bool {
        favoriteStations.contains { $0.id == stationId }
    }

    func toggleFavorite(_ station: RadioStation) {
        guard let userId = userId else { return }
        let wasFavorite = isFavorite(stationId: station.id)

        // Optimistic local update
        if wasFavorite {
            favoriteStations.removeAll { $0.id == station.id }
        } else {
            favoriteStations.append(station)
        }
        persistFavoritesOrder(favoriteStations.map(\.id), userId: userId)

        Task {
            do {
                if wasFavorite {
                    try await PocketCastsAPI.removeFavorite(userId: userId, stationId: station.id)
                } else {
                    try await PocketCastsAPI.addFavorite(userId: userId, stationId: station.id)
                }
            } catch {
                print("🎵 PocketRadio: toggle favorite failed: \(error.localizedDescription)")
                // Roll back on failure
                await MainActor.run {
                    if wasFavorite {
                        self.favoriteStations.append(station)
                    } else {
                        self.favoriteStations.removeAll { $0.id == station.id }
                    }
                    self.persistFavoritesOrder(self.favoriteStations.map(\.id), userId: userId)
                }
            }
        }
    }

    /// Play a station from the browse list without requiring it to be in favorites.
    /// Closes the browse panel and starts playback immediately.
    func playStation(_ station: RadioStation) {
        if isPlaying { stopPlayback() }
        currentSource = .radio(station)
        nowPlayingTitle = station.name
        startPlayback()
        startTracklist(for: station)
        // If station is among top-3 favorites, sync the selected pill.
        if let idx = favoriteStations.firstIndex(where: { $0.id == station.id }), idx < 3 {
            selectedPill = .stream(idx)
        }
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
        lastPositionSaveTime = nil
        lastSavedPosition = -1
        isPlaying = true
        observeDuration()
        setupTimeObserver()

        // For podcast episodes with a saved position, seek first then play
        // (remote items may not be ready for seek until the asset loads)
        if case .podcast(let ep) = currentSource, ep.playedUpTo > 0 {
            let seekTime = CMTime(seconds: Double(ep.playedUpTo), preferredTimescale: 600)
            print("🎵 PocketRadio: Seeking to \(ep.playedUpTo)s, then playing")
            audioPlayer.seek(to: seekTime) { [weak self] _ in
                guard let self = self,
                      case .podcast(let currentEp) = self.currentSource,
                      currentEp.uuid == ep.uuid else { return }
                self.audioPlayer.play()
            }
        } else {
            audioPlayer.play()
        }

        notifyNowPlayingChanged()
    }

    private func stopPlayback() {
        print("🎵 PocketRadio: Stopping playback")

        // Save final position before tearing down
        if case .podcast(let ep) = currentSource {
            let position = Int(audioPlayer.currentTime().seconds)
            if position > 0 {
                let duration = ep.duration > 0 ? ep.duration : (episodeDurations[ep.uuid] ?? 0)
                let remaining = duration - position
                let status: EpisodePlayingStatus = (duration > 0 && remaining <= 10) ? .completed : .inProgress
                savePositionNow(for: ep, position: position, status: status)
            }
        }

        durationObserver?.cancel()
        if let token = timeObserverToken {
            audioPlayer.removeTimeObserver(token)
            timeObserverToken = nil
        }
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
