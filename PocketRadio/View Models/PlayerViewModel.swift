//
//  PlayerViewModel.swift
//  PocketRadio Menubar
//
//  M1: Minimal AVPlayer wrapper — play/stop one stream.
//

import Foundation
import AVFoundation

@MainActor
class PlayerViewModel: ObservableObject {

    @Published var isPlaying: Bool = false
    var audioPlayer: AVPlayer = AVPlayer()

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
