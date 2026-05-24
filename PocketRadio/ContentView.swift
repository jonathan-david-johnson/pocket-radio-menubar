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
            // ── Top Row: Artwork Pills ──
            HStack(spacing: 0) {
                podcastArtworkPill
                Spacer()
                streamArtworkPill(0)
                Spacer()
                streamArtworkPill(1)
                Spacer()
                streamArtworkPill(2)
                Spacer()

                // ⋮ browse button
                Button(action: { vm.toggleBrowse() }) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(vm.showBrowseTabs ? PocketCastsTheme.accent : PocketCastsTheme.primaryIcon02)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
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
            } else if vm.selectedPill == .podcast {
                podcastTabsSection
            } else if !vm.tracklist.isEmpty {
                tracklistView
            } else if vm.isLoadingTracklist {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.7)
                    Text("Loading tracklist...")
                        .font(.system(size: 13))
                        .foregroundColor(PocketCastsTheme.primaryText02)
                    Spacer()
                }
                .padding(.vertical, 20)
                Spacer()
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

    // MARK: - Artwork Pills

    private let pillSize: CGFloat = 36
    private let pillCorner: CGFloat = 6

    var podcastArtworkPill: some View {
        let isSelected = vm.selectedPill == .podcast
        let artworkURL = vm.topEpisode.flatMap { ep -> URL? in
            URL(string: "https://static.pocketcasts.com/discover/images/130/\(ep.podcastUUID).jpg")
        }
        return artworkPill(
            url: artworkURL,
            isSelected: isSelected,
            placeholder: AnyView(iconPlaceholder("headphones")),
            action: { vm.selectPodcast() }
        )
    }

    private func iconPlaceholder(_ systemName: String) -> some View {
        ZStack {
            Rectangle().fill(PocketCastsTheme.primaryUi04)
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(PocketCastsTheme.primaryIcon02)
        }
    }

    func streamArtworkPill(_ index: Int) -> some View {
        let isSelected = vm.selectedPill == .stream(index)
        let station: RadioStation? = index < vm.favoriteStations.count ? vm.favoriteStations[index] : nil
        let localAsset = station.flatMap { bundledLogoAsset(for: $0) }
        let logoURL = station.flatMap { stationLogoURL(for: $0) }
        let label = station.flatMap { stationLogoFallbackText(for: $0) }
        let action: () -> Void = {
            guard station != nil else { return }
            vm.selectStream(index)
        }

        if let asset = localAsset {
            return AnyView(artworkPillLocal(imageName: asset, isSelected: isSelected, action: action))
        }
        return AnyView(artworkPill(
            url: logoURL,
            isSelected: isSelected,
            placeholder: AnyView(textPlaceholder(label ?? "?")),
            action: action
        ))
    }

    /// Bundled imageset name for stations whose remote favicons are broken (rate-limited,
    /// http-only, etc). Returns nil to fall back to remote/text logo.
    private func bundledLogoAsset(for station: RadioStation) -> String? {
        let name = station.name.lowercased()
        if name.contains("kcrw") { return "KCRW_logo_white" }
        if name.contains("kexp") { return "KEXP_logo" }
        return nil
    }

    private func stationLogoURL(for station: RadioStation) -> URL? {
        if let logo = station.logoURL, !logo.isEmpty {
            // Many radio-browser favicons are served over plain http://; ATS would block them.
            let upgraded = logo.hasPrefix("http://") ? "https://" + logo.dropFirst("http://".count) : logo
            return URL(string: upgraded)
        }
        return nil
    }

    /// Short text label used when no logo image is available.
    private func stationLogoFallbackText(for station: RadioStation) -> String {
        let trimmed = station.name.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 4 { return trimmed }
        return String(trimmed.prefix(4))
    }

    private func textPlaceholder(_ text: String) -> some View {
        ZStack {
            Rectangle().fill(PocketCastsTheme.primaryUi04)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PocketCastsTheme.primaryText01)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
        }
    }

    private func artworkPillLocal(
        imageName: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(PocketCastsTheme.primaryUi04)
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
            .frame(width: pillSize, height: pillSize)
            .clipShape(RoundedRectangle(cornerRadius: pillCorner))
            .overlay(
                RoundedRectangle(cornerRadius: pillCorner)
                    .stroke(PocketCastsTheme.accent, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    private func artworkPill(
        url: URL?,
        isSelected: Bool,
        placeholder: AnyView,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if let url = url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().interpolation(.medium)
                        case .empty, .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: pillSize, height: pillSize)
            .clipShape(RoundedRectangle(cornerRadius: pillCorner))
            .overlay(
                RoundedRectangle(cornerRadius: pillCorner)
                    .stroke(PocketCastsTheme.accent, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Section Content

    var tracklistView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.tracklist) { entry in
                    tracklistRow(entry)
                }
            }
        }
    }

    func tracklistRow(_ entry: TracklistEntry) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.albumArtURL) { phase in
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
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(PocketCastsTheme.primaryText01)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.system(size: 12))
                    .foregroundColor(PocketCastsTheme.primaryText02)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Podcast tabs (Up Next / New Releases)

    var podcastTabsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                podcastTabButton("Up Next", tab: .upNext)
                podcastTabButton("New Releases", tab: .newReleases)
            }
            .padding(.top, 6)
            .padding(.horizontal, 12)

            if vm.podcastTab == .upNext {
                upNextListView
            } else {
                newReleasesView
            }
        }
    }

    private func podcastTabButton(_ label: String, tab: PlayerViewModel.PodcastTab) -> some View {
        let isSelected = vm.podcastTab == tab
        return Button(action: { vm.selectPodcastTab(tab) }) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? PocketCastsTheme.primaryText01 : PocketCastsTheme.primaryText02)
                Rectangle()
                    .fill(isSelected ? PocketCastsTheme.accent : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    var newReleasesView: some View {
        Group {
            if vm.isLoadingNewReleases && vm.newReleases.isEmpty {
                emptyMessage("Loading new releases…")
            } else if vm.newReleases.isEmpty {
                emptyMessage("No new episodes in the last 14 days.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.newReleases) { release in
                            newReleaseRow(release)
                        }
                    }
                }
            }
        }
    }

    func newReleaseRow(_ release: NewReleaseEpisode) -> some View {
        let artworkURL = URL(string: "https://static.pocketcasts.com/discover/images/130/\(release.podcastUUID).jpg")
        return Button(action: { vm.playNewReleaseEpisode(release) }) {
            HStack(spacing: 12) {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().interpolation(.medium)
                    case .empty, .failure:
                        RoundedRectangle(cornerRadius: 4).fill(PocketCastsTheme.primaryUi04)
                    @unknown default:
                        RoundedRectangle(cornerRadius: 4).fill(PocketCastsTheme.primaryUi04)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(release.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(PocketCastsTheme.primaryText01)
                        .lineLimit(1)
                    Text(release.podcastTitle)
                        .font(.system(size: 12))
                        .foregroundColor(PocketCastsTheme.primaryText02)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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

    // MARK: - Browse / Favorites Panel

    var browsePlaceholder: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                browseTabButton("Favorites", tab: .favorites)
                browseTabButton("Browse", tab: .browse)
            }
            .padding(.top, 6)
            .padding(.horizontal, 12)

            if vm.browseTab == .browse {
                searchField
            }

            stationListView

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func browseTabButton(_ label: String, tab: PlayerViewModel.BrowseTab) -> some View {
        let isSelected = vm.browseTab == tab
        return Button(action: { vm.selectBrowseTab(tab) }) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? PocketCastsTheme.primaryText01 : PocketCastsTheme.primaryText02)
                Rectangle()
                    .fill(isSelected ? PocketCastsTheme.accent : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        TextField("Search stations…", text: Binding(
            get: { vm.browseQuery },
            set: { vm.updateBrowseQuery($0) }
        ))
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var stationListView: some View {
        Group {
            if vm.browseTab == .favorites {
                if vm.favoriteStations.isEmpty {
                    emptyMessage(vm.isLoadingFavorites ? "Loading favorites…" : "No favorite stations yet.")
                } else {
                    favoritesReorderableList
                }
            } else {
                if vm.isBrowseLoading && vm.browseResults.isEmpty {
                    emptyMessage("Loading…")
                } else if vm.browseResults.isEmpty {
                    emptyMessage("No stations.")
                } else {
                    stationScroll(vm.browseResults, showFavoriteToggle: true)
                }
            }
        }
    }

    private var favoritesReorderableList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.favoriteStations) { station in
                    stationRow(station, showFavoriteToggle: true)
                        .draggable(station.id) {
                            // Drag preview
                            stationRow(station, showFavoriteToggle: false)
                                .frame(width: 260)
                                .background(PocketCastsTheme.primaryUi04)
                                .cornerRadius(6)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let droppedId = items.first,
                                  let fromIdx = vm.favoriteStations.firstIndex(where: { $0.id == droppedId }),
                                  let toIdx = vm.favoriteStations.firstIndex(where: { $0.id == station.id }),
                                  fromIdx != toIdx else { return false }
                            // SwiftUI move() inserts before index; if dropping below current pos, +1.
                            let target = fromIdx < toIdx ? toIdx + 1 : toIdx
                            vm.reorderFavorites(from: IndexSet(integer: fromIdx), to: target)
                            return true
                        }
                }
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(PocketCastsTheme.primaryText02)
            Spacer()
        }
        .padding(.vertical, 20)
    }

    private func stationScroll(_ stations: [RadioStation], showFavoriteToggle: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(stations) { station in
                    stationRow(station, showFavoriteToggle: showFavoriteToggle)
                }
            }
        }
    }

    private func stationRow(_ station: RadioStation, showFavoriteToggle: Bool) -> some View {
        let logoURL = stationLogoURL(for: station)
        let label = stationLogoFallbackText(for: station)
        return Button(action: { vm.playStation(station) }) {
            HStack(spacing: 10) {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().interpolation(.medium)
                    case .empty, .failure:
                        textPlaceholder(label)
                    @unknown default:
                        textPlaceholder(label)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(station.name)
                    .font(.system(size: 13))
                    .foregroundColor(PocketCastsTheme.primaryText01)
                    .lineLimit(1)

                Spacer()

                if showFavoriteToggle {
                    let isFav = vm.isFavorite(stationId: station.id)
                    Button(action: { vm.toggleFavorite(station) }) {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .font(.system(size: 14))
                            .foregroundColor(isFav ? PocketCastsTheme.accent : PocketCastsTheme.primaryIcon02)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
