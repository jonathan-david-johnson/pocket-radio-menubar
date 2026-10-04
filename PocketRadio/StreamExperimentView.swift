import SwiftUI

/// Debug-only session modes. Apply is explicit, reversible, and never persisted.
struct StreamExperimentView: View {
    @ObservedObject var vm: PlayerViewModel
    @State private var routeCategory = "unrecorded"

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 9) {
            Text("KCRW AAC/HLS — \(vm.streamExperimentMode.rawValue)")
                .font(.headline)
            if vm.streamExperimentExportStatus.hasPrefix("Exported:") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Last capture saved", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                    Text("Pausing live radio saves and ends its capture. Resume joins a fresh item; start a separate capture to record it.")
                        .font(.caption)
                    Text(vm.streamExperimentExportStatus)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
            } else if vm.streamExperimentExportStatus.hasPrefix("Capture incomplete") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Capture incomplete", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text(vm.streamExperimentExportStatus)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
            }
            Picker("Experiment", selection: Binding(
                get: { vm.streamExperimentMode },
                set: { vm.setStreamExperimentMode($0) }
            )) {
                ForEach(StreamExperimentMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text("Changing modes reconnects a playing KCRW item. Other stations and podcasts keep their normal URLs. No settings are saved.")
                .font(.caption)
            Divider()
            line("Playback", vm.isPlaying ? "playing" : "stopped")
            line("Active source", vm.streamExperimentSourceName)
            line("Stored stream (redacted)", vm.streamExperimentSourceURL)
            line("Player item (redacted)", vm.streamExperimentItemURL)
            line("Eligibility", vm.streamExperimentEligibility)
            Divider()
            line("Endpoint", vm.streamExperimentSnapshot?.endpoint.absoluteString
                 ?? "\(StreamExperimentConfiguration.measuredEndpoint.absoluteString) (armed only)")
            line(vm.streamExperimentMode == .applyCandidate ? "Applied title" : "Legacy published",
                 vm.nowPlayingTitle.isEmpty ? "—" : vm.nowPlayingTitle)
            line("Feed top", vm.streamExperimentSnapshot?.feedTop ?? "unavailable")
            line("Candidate", vm.streamExperimentSnapshot?.candidate ?? "unavailable")
            line("Reason", vm.streamExperimentSnapshot?.reason ?? "No active experimental item")
            if vm.streamExperimentMode == .applyCandidate {
                line("Lyric resource", vm.streamExperimentLyricReason)
            }
            line("Feed", vm.streamExperimentSnapshot?.feedStatus ?? "not requested")
            if let sample = vm.streamExperimentSnapshot {
                line("Media", sample.mediaSeconds.map { String(format: "%.3fs", $0) } ?? "unavailable")
                line("Program date", sample.programDate.map { $0.formatted(.iso8601) } ?? "unavailable")
                line("Song estimate", sample.songSeconds.map { String(format: "%.3fs", $0) } ?? "unavailable")
                line("Cache age", sample.cacheAgeSeconds.map { String(format: "%.0fs", $0) } ?? "not reported")
                line("Occurrence", sample.candidateID?.rawValue ?? "unavailable")
                line("Item generation", sample.generation.uuidString)
            }
            Divider()
            Picker("Output route", selection: $routeCategory) {
                ForEach(["speaker", "headphones", "bluetooth", "other", "unrecorded"], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            Text("Choose the actual output route. Unrecorded captures do not validate a route.")
                .font(.caption)
            HStack {
                if vm.isStreamExperimentCapturing {
                    Button("Stop export") { vm.endStreamExperimentCapture() }
                    Button("Song change") { vm.markStreamExperiment("heard_song_change") }
                    Button("Lyric line") { vm.markStreamExperiment("lyric_landmark") }
                } else {
                    Button("Start same-player capture (reconnect)") {
                        vm.beginStreamExperimentCapture(routeCategory: routeCategory)
                    }
                    .disabled(vm.streamExperimentMode == .off || !vm.isPlaying)
                }
            }
            if vm.isStreamExperimentCapturing {
                HStack {
                    Button("Wrong title / line") { vm.markStreamExperiment("wrong_title_or_line") }
                    Button("Speech / commercial") { vm.markStreamExperiment("speech_or_commercial") }
                }
            }
            if !vm.streamExperimentExportStatus.hasPrefix("Exported:") &&
               !vm.streamExperimentExportStatus.hasPrefix("Capture incomplete") {
                Text(vm.streamExperimentExportStatus)
                    .font(.caption)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text(vm.streamExperimentMode == .applyCandidate
                 ? "Apply publishes the estimated candidate to title, history, Now Playing and eligible lyrics. Missing alignment hides timed lyrics; +160s is not verified lyric accuracy. Off restores normal playback. No saved URLs or lyric offsets change."
                 : "Observe does not publish the candidate. +160s is an estimate for this endpoint; it is not lyric or speaker alignment. Capture writes local owner-only trace and decision files, without audio or lyrics.")
                .font(.caption)
        }
        .font(.system(size: 11))
        .textSelection(.enabled)
        .padding(12)
        .frame(width: 370, alignment: .leading)
        }
        .frame(maxHeight: 620)
    }

    private func line(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).fontWeight(.semibold)
            Text(value).lineLimit(3).truncationMode(.middle)
        }
    }
}
