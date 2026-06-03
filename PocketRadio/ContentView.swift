//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M6.2.5: Pocket Casts dark theme styling + time-remaining visibility.
//

import OSLog
import SwiftUI

private let acrLog = Logger(subsystem: "com.jdj.pocketradio", category: "ACR")

struct ContentView: View {

    @StateObject private var vm: PlayerViewModel
    @State private var isLoggingIn = false

    /// A list item whose detail panel can be opened.
    enum DetailItem: Equatable {
        case episode(UpNextEpisode)
        case release(NewReleaseEpisode)
        case station(RadioStation)
    }
    /// Row currently under the cursor — reveals its ⓘ button.
    @State private var hoveredRowID: String? = nil
    /// Explicitly-opened detail panel (via ⓘ). Persists until closed.
    @State private var detailItem: DetailItem? = nil

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
            // ── Top Row: refresh | 4 artwork pills | menu ──
            HStack(spacing: 0) {
                Button(action: { Task { await vm.refreshActiveSection() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(PocketCastsTheme.primaryIcon02)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")

                Spacer()
                podcastArtworkPill
                Spacer()
                streamArtworkPill(0)
                Spacer()
                streamArtworkPill(1)
                Spacer()
                streamArtworkPill(2)
                Spacer()

                Button(action: { vm.toggleBrowse() }) {
                    Image(systemName: "ellipsis")
                        .rotationEffect(.degrees(90))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(vm.showBrowseTabs ? PocketCastsTheme.accent : PocketCastsTheme.primaryIcon02)
                        .frame(width: 22, height: 22)
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
                            Image(systemName: "gobackward")
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

                // Skip Forward — or Track Source Toggle for live streams
                if vm.showSkipControls {
                    Button(action: { vm.skipForward() }) {
                        VStack(spacing: 0) {
                            Image(systemName: "goforward")
                                .font(.system(size: 18))
                            Text("\(Int(vm.skipForwardSeconds))s")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(PocketCastsTheme.primaryIcon02)
                    }
                    .buttonStyle(.plain)
                } else if vm.showTrackSourceToggle {
                    trackSourceToggle
                }
            }
            .padding(.vertical, 10)

            // ── Scrub Bar (seekable content only) ──
            if vm.showSkipControls && vm.currentSource != nil {
                scrubBar
            }

            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)

            // ── Bottom Section (with hover-detail overlay) ──
            ZStack {
                VStack(spacing: 0) {
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
                }

                if let detail = detailItem {
                    detailCard(detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .overlay(acrToastOverlay, alignment: .bottom)
    }

    @ViewBuilder
    private var acrToastOverlay: some View {
        if let msg = vm.acrToast {
            Text(msg)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.82)))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: msg)
        }
    }

    // MARK: - Scrub Bar

    var scrubBar: some View {
        let duration = max(vm.durationSeconds, 0)
        let remaining = max(0, duration - vm.currentTimeSeconds)
        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { vm.currentTimeSeconds },
                    set: { vm.currentTimeSeconds = $0 }
                ),
                in: 0...max(duration, 1),
                onEditingChanged: { editing in
                    vm.isScrubbing = editing
                    if !editing { vm.scrub(toSeconds: vm.currentTimeSeconds) }
                }
            )
            .controlSize(.mini)
            .tint(PocketCastsTheme.accent)
            .disabled(duration <= 0)

            HStack {
                Text(vm.clockTime(vm.currentTimeSeconds))
                Spacer()
                Text("-\(vm.clockTime(remaining))")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(PocketCastsTheme.primaryText02)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Track Source Toggle (Tracklist ↔ ACR)

    private var trackSourceToggle: some View {
        let busy = vm.isIdentifying
        return Button(action: {
            guard !busy else { return }
            acrLog.debug("ACR identify tapped")
            vm.identifyNow()
        }) {
            Text(busy ? "Listening…" : "ACR")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(busy ? PocketCastsTheme.primaryText02 : PocketCastsTheme.primaryUi01)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(busy ? PocketCastsTheme.primaryUi04 : PocketCastsTheme.accent)
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(busy ? "Listening to stream…" : "Identify current track via ACRCloud")
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
        if name.contains("kcrw") { return "kcrw_logo" }
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
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
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

            // Push everything up so the outer VStack doesn't center this when
            // the active tab's content is short (e.g. loading state).
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                    let dateText = vm.relativePublishedText(for: release.published)
                    if !dateText.isEmpty {
                        Text(dateText)
                            .font(.system(size: 11))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if hoveredRowID == release.uuid {
                    infoButton { detailItem = .release(release) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in setRowHover(release.uuid, inside) }
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

                        let dateText = vm.relativePublishedText(for: episode.published)
                        let timeText = vm.timeRemainingText(for: episode)
                        if dateText.isEmpty && timeText.isEmpty {
                            Text(episode.podcastUUID)
                                .font(.system(size: 13))
                                .foregroundColor(PocketCastsTheme.primaryText02)
                                .lineLimit(1)
                        } else {
                            if !dateText.isEmpty {
                                Text(dateText)
                                    .font(.system(size: 12))
                                    .foregroundColor(PocketCastsTheme.primaryText02)
                                    .lineLimit(1)
                            }
                            if !timeText.isEmpty {
                                Text(timeText)
                                    .font(.system(size: 12))
                                    .foregroundColor(PocketCastsTheme.primaryText02)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Spacer()

                    if hoveredRowID == episode.uuid {
                        infoButton { detailItem = .episode(episode) }
                    } else if isCurrent && vm.isPlaying {
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
            .onHover { inside in setRowHover(episode.uuid, inside) }

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

                if hoveredRowID == station.id {
                    infoButton { detailItem = .station(station) }
                }

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
        .onHover { inside in setRowHover(station.id, inside) }
    }

    // MARK: - Row hover + ⓘ button

    /// Update which row shows its ⓘ. On exit, only clear if this row was the
    /// hovered one (avoids a late exit from row A wiping row B's hover).
    private func setRowHover(_ id: String, _ inside: Bool) {
        if inside {
            hoveredRowID = id
        } else if hoveredRowID == id {
            hoveredRowID = nil
        }
    }

    private func infoButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 15))
                .foregroundColor(PocketCastsTheme.primaryIcon02)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show details")
    }

    // MARK: - Detail Panel

    @ViewBuilder
    func detailCard(_ detail: DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Back / Close
            HStack(spacing: 0) {
                Button(action: { detailItem = nil }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back").font(.system(size: 12))
                    }
                    .foregroundColor(PocketCastsTheme.primaryText02)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)   // Esc

                Spacer()

                Button(action: { detailItem = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(PocketCastsTheme.primaryIcon02)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch detail {
            case .episode(let ep):
                episodeDetail(title: ep.title,
                              podcastUUID: ep.podcastUUID,
                              episodeUUID: ep.uuid,
                              published: ep.published,
                              duration: ep.duration,
                              podcastTitle: nil)
            case .release(let r):
                episodeDetail(title: r.title,
                              podcastUUID: r.podcastUUID,
                              episodeUUID: r.uuid,
                              published: r.published,
                              duration: r.duration,
                              podcastTitle: r.podcastTitle)
            case .station(let s):
                stationDetail(s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PocketCastsTheme.primaryUi01)
    }

    @ViewBuilder
    private func episodeDetail(title: String,
                               podcastUUID: String,
                               episodeUUID: String,
                               published: Date?,
                               duration: Int,
                               podcastTitle: String?) -> some View {
        let artworkURL = URL(string: "https://static.pocketcasts.com/discover/images/130/\(podcastUUID).jpg")
        let notes = vm.showNotes(forEpisode: episodeUUID)
        let isLoading = vm.loadingShowNotes.contains(episodeUUID)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().interpolation(.medium)
                    case .empty, .failure:
                        RoundedRectangle(cornerRadius: 6).fill(PocketCastsTheme.primaryUi04)
                    @unknown default:
                        RoundedRectangle(cornerRadius: 6).fill(PocketCastsTheme.primaryUi04)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(PocketCastsTheme.primaryText01)
                        .lineLimit(3)
                    if let podcastTitle, !podcastTitle.isEmpty {
                        Text(podcastTitle)
                            .font(.system(size: 12))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                            .lineLimit(1)
                    }
                    let meta = [vm.relativePublishedText(for: published),
                                vm.episodeDurationText(duration)]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundColor(PocketCastsTheme.primaryText02)
                    }
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)

            if let notes, !notes.description.isEmpty {
                ScrollView {
                    Text(notes.description)
                        .font(.system(size: 12))
                        .foregroundColor(PocketCastsTheme.primaryText01)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else if isLoading {
                HStack { Spacer(); ProgressView().scaleEffect(0.7); Spacer() }
                    .padding(.top, 12)
                Spacer()
            } else {
                Text("No description available.")
                    .font(.system(size: 12))
                    .foregroundColor(PocketCastsTheme.primaryText02)
                Spacer()
            }
        }
        .padding(12)
        .task(id: episodeUUID) {
            vm.loadShowNotesIfNeeded(episodeUUID: episodeUUID, podcastUUID: podcastUUID)
        }
    }

    @ViewBuilder
    private func stationDetail(_ s: RadioStation) -> some View {
        let logoURL = stationLogoURL(for: s)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().interpolation(.medium)
                    case .empty, .failure:
                        textPlaceholder(stationLogoFallbackText(for: s))
                    @unknown default:
                        textPlaceholder(stationLogoFallbackText(for: s))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(PocketCastsTheme.primaryText01)
                        .lineLimit(3)
                    Text("Live Stream")
                        .font(.system(size: 12))
                        .foregroundColor(PocketCastsTheme.primaryText02)
                }
                Spacer(minLength: 0)
            }

            Rectangle()
                .fill(PocketCastsTheme.primaryUi05)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 6) {
                stationMetaRow("Location", value: [s.country, s.language].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                stationMetaRow("Genre", value: s.tags?.replacingOccurrences(of: ",", with: ", "))
                stationMetaRow("Quality", value: stationQualityText(s))
                stationMetaRow("Popularity", value: s.votes.map { "\($0) votes" })
                if let home = s.homepage, !home.isEmpty, let url = URL(string: home) {
                    Link(destination: url) {
                        Text(home)
                            .font(.system(size: 12))
                            .foregroundColor(PocketCastsTheme.accent)
                            .lineLimit(1)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private func stationMetaRow(_ label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(PocketCastsTheme.primaryText02)
                    .frame(width: 70, alignment: .leading)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundColor(PocketCastsTheme.primaryText01)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stationQualityText(_ s: RadioStation) -> String? {
        var parts: [String] = []
        if let codec = s.codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if let bitrate = s.bitrate, bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
