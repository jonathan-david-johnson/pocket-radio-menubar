//
//  ContentView.swift
//  PocketRadio Menubar
//
//  M1: Minimal popover UI — play/stop toggle for one stream.
//

import SwiftUI

struct ContentView: View {

    @StateObject private var vm: PlayerViewModel

    init(vm: PlayerViewModel) {
        self._vm = StateObject(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("PocketRadio")
                .font(.headline)
                .padding(.top, 12)

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
            .padding(.bottom, 12)
        }
        .frame(width: 300)
    }
}
