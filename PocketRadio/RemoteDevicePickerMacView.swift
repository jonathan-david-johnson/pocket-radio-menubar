import SwiftUI

struct RemoteDevicePickerMacView: View {
    @ObservedObject var remoteControl: RemoteControlService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Play on\u{2026}")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            let devices = remoteControl.otherDevices()
            if devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No devices found")
                        .font(.subheadline)
                    Text("Open PocketStreams on another device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
            } else {
                ForEach(devices, id: \.deviceId) { device in
                    Button {
                        let newTarget = device.deviceId == remoteControl.activeTargetDeviceId ? nil : device.deviceId
                        remoteControl.setTarget(newTarget)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: device.deviceType == "macos" ? "desktopcomputer" : "iphone")
                                .frame(width: 20)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.deviceName)
                                    .foregroundColor(.primary)
                                Text(stateLabel(device.playback.state.rawValue))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if device.deviceId == remoteControl.activeTargetDeviceId {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if remoteControl.activeTargetDeviceId != nil {
                Divider()
                Button {
                    remoteControl.setTarget(nil)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle")
                        Text("Stop Remote")
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240)
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "playing": return "Playing"
        case "paused": return "Paused"
        default: return "Idle"
        }
    }
}
