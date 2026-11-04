
import SwiftUI
import MusicKit
import Foundation
import Observation

// MARK: - Now Playing JSON

struct NowPlayingPayload: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var artworkUrl: String
    var isPlaying: Bool
    var playbackTime: Double
    var updatedAt: Int64
}

// MARK: - Companion App Model

@MainActor
@Observable
final class NowPlayingViewModel {

    private let player = SystemMusicPlayer.shared

    var title = "Nothing Playing"
    var artist = "Waiting for Apple Music..."
    var album = ""
    var artworkURL: URL?

    var isPlaying = false
    var playbackTime: Double = 0

    var musicStatus = "Not Connected"
    var espStatus = "Not Connected"
    var errorMessage = ""

    var baseURL = "http://192.168.137.177"

    private var pollingTask: Task<Void, Never>?
    private var lastPayload: NowPlayingPayload?

    // MARK: Authorization

    func start() async {
        musicStatus = "Requesting Permission"

        let authorization = await MusicAuthorization.request()

        guard authorization == .authorized else {
            musicStatus = "Permission Denied"
            errorMessage = "Please allow MusicKit access in iPad Settings."
            return
        }

        musicStatus = "Authorized"
        errorMessage = ""

        startPolling()
    }

    // MARK: Polling

    func startPolling() {
        pollingTask?.cancel()

        pollingTask = Task {
            while !Task.isCancelled {
                await refreshNowPlaying()

                try? await Task.sleep(
                    for: .seconds(1)
                )
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: Read Apple Music

    func refreshNowPlaying() async {

        let entry = player.queue.currentEntry

        guard let entry else {
            title = "Nothing Playing"
            artist = "Waiting for Apple Music..."
            album = ""
            artworkURL = nil
            isPlaying = false
            playbackTime = 0

            lastPayload = nil
            return
        }

        title = entry.title
        artist = entry.subtitle ?? ""
        album = ""

        if let artwork = entry.artwork {
            artworkURL = artwork.url(
                width: 600,
                height: 600
            )
        } else {
            artworkURL = nil
        }

        isPlaying = player.state.playbackStatus == .playing

        let currentTime = player.playbackTime

        playbackTime = currentTime.isFinite
            ? max(0, currentTime)
            : 0

        let payload = NowPlayingPayload(
            title: title,
            artist: artist,
            album: album,
            artworkUrl: artworkURL?.absoluteString ?? "",
            isPlaying: isPlaying,
            playbackTime: playbackTime,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )

        if payload.title != lastPayload?.title ||
           payload.artist != lastPayload?.artist ||
           payload.album != lastPayload?.album ||
           payload.artworkUrl != lastPayload?.artworkUrl ||
           payload.isPlaying != lastPayload?.isPlaying ||
           Int(payload.playbackTime) != Int(lastPayload?.playbackTime ?? -1) {

            lastPayload = payload
            await sendToESP32(payload)
        } else if let lastPayload {
            // ส่งข้อมูลเวลาเล่นเป็นระยะ
            if Int(payload.playbackTime) != Int(lastPayload.playbackTime) {
                self.lastPayload = payload
                await sendToESP32(payload)
            }
        }
    }

    // MARK: Send JSON to ESP32

    func sendToESP32(_ payload: NowPlayingPayload) async {

        let cleanURL = baseURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let url = URL(
            string: cleanURL + "/api/nowplaying"
        ) else {
            espStatus = "Invalid Address"
            return
        }

        var request = URLRequest(url: url)

        request.httpMethod = "POST"
        request.timeoutInterval = 5

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)

            let (_, response) = try await URLSession.shared.data(
                for: request
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                espStatus = "Connection Error"
                return
            }

            if (200...299).contains(httpResponse.statusCode) {
                espStatus = "Connected"
                errorMessage = ""
            } else {
                espStatus = "HTTP Error \(httpResponse.statusCode)"
            }

        } catch {
            espStatus = "Disconnected"
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        pollingTask?.cancel()
    }
}

// MARK: - Main UI

struct ContentView: View {

    @State private var model = NowPlayingViewModel()

    @AppStorage("esp32BaseURL")
    private var esp32BaseURL = "http://192.168.137.177"

    var body: some View {

        NavigationStack {

            ScrollView {

                VStack(spacing: 24) {

                    // Artwork

                    Group {
                        if let artworkURL = model.artworkURL {

                            AsyncImage(url: artworkURL) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                artworkPlaceholder
                            }

                        } else {
                            artworkPlaceholder
                        }
                    }
                    .frame(width: 260, height: 260)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 24)
                    )
                    .shadow(radius: 12)

                    // Song Information

                    VStack(spacing: 8) {

                        Text(model.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text(model.artist)
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        if !model.album.isEmpty {
                            Text(model.album)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Playback Status

                    HStack(spacing: 8) {

                        Circle()
                            .fill(
                                model.isPlaying
                                ? Color.green
                                : Color.orange
                            )
                            .frame(width: 9, height: 9)

                        Text(
                            model.isPlaying
                            ? "Playing"
                            : "Paused / Stopped"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    // Playback Time

                    HStack {
                        Text("Playback")
                        Spacer()
                        Text(
                            "\(Int(model.playbackTime)) sec"
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    // MusicKit Connection

                    connectionRow(
                        title: "MusicKit",
                        value: model.musicStatus,
                        connected: model.musicStatus == "Authorized"
                    )

                    // ESP32 Connection

                    connectionRow(
                        title: "ESP32",
                        value: model.espStatus,
                        connected: model.espStatus == "Connected"
                    )

                    Divider()

                    // ESP32 Address

                    VStack(alignment: .leading, spacing: 8) {

                        Text("ESP32 Address")
                            .font(.headline)

                        TextField(
                            "http://192.168.137.177",
                            text: $esp32BaseURL
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    }

                    // Retry Authorization

                    Button {
                        Task {
                            model.baseURL = esp32BaseURL
                            await model.start()
                        }
                    } label: {
                        Label(
                            "Connect / Retry",
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !model.errorMessage.isEmpty {
                        Text(model.errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Music Remote Bridge")
            .task {
                model.baseURL = esp32BaseURL
                await model.start()
            }
            .onChange(of: esp32BaseURL) { _, newValue in
                model.baseURL = newValue
            }
            .onDisappear {
                model.stopPolling()
            }
        }
    }

    // MARK: Artwork Placeholder

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 70))
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: Connection Row

    private func connectionRow(
        title: String,
        value: String,
        connected: Bool
    ) -> some View {

        HStack {

            Text(title)
                .font(.headline)

            Spacer()

            Circle()
                .fill(
                    connected
                    ? Color.green
                    : Color.orange
                )
                .frame(width: 8, height: 8)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
