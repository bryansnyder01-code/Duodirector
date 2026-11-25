import MultipeerConnectivity
import SwiftUI

// =====================================================================================
//  Remote Producer UI (Phase 6)
//    RemoteSetupSheet: pick a role. "Allow a remote" (this is the camera) or
//                      "Control a camera" (this device is the remote), then pick a camera.
//    RemoteProducerView: the remote's full-screen control surface, sized for a phone
//                      in one hand or an iPad on a stand.
// =====================================================================================

struct RemoteSetupSheet: View {
    let link: RemoteProducerLink
    @Environment(\.dismiss) private var dismiss
    @State private var showRemote = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { link.role == .camera },
                                         set: { $0 ? link.startCamera() : link.stop() })) {
                        Label("Allow a remote to connect", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    if link.role == .camera {
                        LabeledContent("Status", value: link.connectedPeerName.map { "Connected: \($0)" } ?? "Waiting for a remote…")
                    }
                } header: {
                    Text("This iPhone is the camera")
                } footer: {
                    Text("A producer on another iPhone or iPad can start and stop takes, drop markers, rate takes and drive the prompter. You approve every connection. Nothing is sent over the internet.")
                }

                Section {
                    Button("Use this device as a remote", systemImage: "appletvremote.gen4") {
                        link.startRemote()
                    }
                    .disabled(link.role == .remote)
                    if link.role == .remote {
                        if link.discoveredPeers.isEmpty {
                            HStack { ProgressView(); Text("Looking for DuoDirector cameras nearby…").foregroundStyle(.secondary) }
                        }
                        ForEach(link.discoveredPeers, id: \.self) { peer in
                            Button {
                                link.connect(to: peer)
                                showRemote = true
                            } label: {
                                Label(peer.displayName, systemImage: "camera.fill")
                            }
                        }
                    }
                } header: {
                    Text("This device is the remote")
                }

                if let error = link.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Remote Producer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showRemote) {
                RemoteProducerView(link: link) { showRemote = false; link.stop() }
            }
        }
    }
}

struct RemoteProducerView: View {
    let link: RemoteProducerLink
    var onClose: () -> Void

    @State private var speed: Double = 40

    var body: some View {
        let status = link.remoteStatus
        VStack(spacing: 14) {
            header(status)
            preview(status)
            if let status { meters(status) }
            controls(status)
            prompter(status)
            Spacer(minLength: 0)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: status?.prompterSpeed) { _, new in if let new { speed = new } }
    }

    private func header(_ status: RemoteStatus?) -> some View {
        HStack {
            Button("Disconnect", systemImage: "xmark.circle.fill", action: onClose).labelStyle(.iconOnly).font(.title2)
            VStack(alignment: .leading) {
                Text(link.connectedPeerName ?? "Connecting…").font(.headline)
                if let status {
                    Text("Take \(status.takeNumber) · \(status.captureMode.label)\(status.activeShotTitle.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if status?.isLive == true {
                Text("LIVE").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(.white).background(.red, in: .rect(cornerRadius: 4))
                    .accessibilityLabel("Camera is streaming live")
            }
            if let guest = status?.guestName {
                Label(guest, systemImage: "person.wave.2.fill").font(.caption.bold()).lineLimit(1)
                    .foregroundStyle(.green)
            }
            if let status {
                // Tally: red while rolling, amber during countdown.
                Text(status.countdownRemaining.map { "\($0)" } ?? (status.isRecording ? "REC " + CameraEngine.timecode(status.recordingDuration) : "STBY"))
                    .font(.title3.monospacedDigit().bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(status.isRecording ? Color.red : status.countdownRemaining != nil ? .orange : Color.white.opacity(0.15),
                                in: .capsule)
            }
        }
    }

    @ViewBuilder
    private func preview(_ status: RemoteStatus?) -> some View {
        ZStack {
            Color(white: 0.08)
            if let image = link.remotePreview, status?.previewAvailable == true {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Label(status?.captureMode == .dualPodcastMultiCam ? "No preview in Dual-Cam (both cameras are recording)"
                                                                  : status == nil ? "Waiting for the camera…" : "Preview paused (iPhone is warm)",
                      systemImage: "video.slash")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if let status {
                HStack(spacing: 6) {
                    chip(ProcessInfo.ThermalState(rawValue: status.thermal)?.label ?? "?", "thermometer.medium",
                         status.thermal >= ProcessInfo.ThermalState.serious.rawValue ? .orange : .white)
                    if let level = status.batteryLevel {
                        chip("\(Int(level * 100))%", status.isCharging ? "battery.100.bolt" : "battery.50percent",
                             level < 0.2 && !status.isCharging ? .red : .white)
                    }
                    if let minutes = status.minutesLeft { chip("\(minutes) min", "internaldrive", minutes < 10 ? .red : .white) }
                }
                .padding(8)
            }
        }
    }

    private func meters(_ status: RemoteStatus) -> some View {
        VStack(spacing: 4) {
            meterBar("L", status.leftDB)
            meterBar("R", status.rightDB)
            if status.isClipping { Text("CLIP").font(.caption.bold()).foregroundStyle(.red) }
        }
    }

    private func meterBar(_ label: String, _ db: Float) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2.monospaced()).frame(width: 12)
            GeometryReader { proxy in
                let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(db > -6 ? Color.red : db > -18 ? .yellow : .green).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
    }

    private func controls(_ status: RemoteStatus?) -> some View {
        HStack(spacing: 14) {
            Button { link.send(.toggleRecording) } label: {
                Image(systemName: status?.isRecording == true ? "stop.fill" : "circle.fill")
                    .font(.system(size: 34)).foregroundStyle(.red)
                    .frame(width: 84, height: 84)
                    .background(.white.opacity(0.12), in: .circle)
            }
            .accessibilityLabel(status?.isRecording == true ? "Stop" : "Record")
            VStack(spacing: 10) {
                Button { link.send(.dropMarker(rating: 3, note: nil)) } label: {
                    Label("Marker\(status.map { " \($0.markerCount + 1)" } ?? "")", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).tint(.cyan).foregroundStyle(.black)
                .disabled(status?.isRecording != true)
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button { link.send(.rateTake(star == status?.takeRating ? 0 : star)) } label: {
                            Image(systemName: star <= (status?.takeRating ?? 0) ? "star.fill" : "star")
                                .foregroundStyle(.yellow).frame(width: 40, height: 40)
                        }
                        .accessibilityLabel("\(star) stars")
                    }
                }
            }
        }
        .disabled(status == nil)
    }

    private func prompter(_ status: RemoteStatus?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { link.send(.togglePrompter) } label: {
                    Image(systemName: status?.isPrompterPlaying == true ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                Button { link.send(.resetPrompter) } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.bordered)
                Slider(value: $speed, in: 10...120, step: 5) { editing in
                    if !editing { link.send(.setPrompterSpeed(speed)) }
                }
                Text("\(Int(speed))").font(.caption.monospacedDigit()).frame(width: 32)
                Button { link.send(.nextShot) } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Next shot")
            }
            if !link.remoteScript.isEmpty {
                ScrollView {
                    Text(link.remoteScript).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
        .disabled(status == nil)
    }

    private func chip(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(.black.opacity(0.6), in: .capsule)
    }
}
