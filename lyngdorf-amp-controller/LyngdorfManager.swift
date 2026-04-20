import Foundation
import Network
import Combine
import AppKit

class LyngdorfManager: ObservableObject {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var syncTimer: Timer?
    private var progressPollTimer: Timer?
    private var ampHost: String?
    private var lastStreamId: Int? = nil
    private var toggleCooldown = false
    private var ignoreAudioStatus = false
    private var browseTimeoutTask: Task<Void, Never>?
    private var lastConnectedEndpoint: NWEndpoint?


    @Published var availableAmps: [NWEndpoint] = []
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var isMuted = false
    @Published var isPlaying = false
    @Published var currentVolume: String = "--"
    @Published var statusMessage: String = "Searching..."
    @Published var browseTimedOut = false

    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var trackArtworkURL: URL? = nil

    // Playback progress in seconds. -1 = not available.
    @Published var playbackPosition: Double = -1
    @Published var playbackDuration: Double = -1

    init() {
        startBrowsing()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // Periodic health check — if stuck, retry browsing
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.isConnected && !self.isConnecting {
                self.startBrowsing()
            }
        }
    }

    @objc private func handleWake() {
        // Network is dead after sleep — restart everything
        connection?.cancel()
        connection = nil
        isConnected = false
        isConnecting = false
        availableAmps = []
        startBrowsing()
    }

    func startBrowsing() {
        browser?.cancel()
        browseTimedOut = false
        browseTimeoutTask?.cancel()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_slactrl._tcp", domain: nil), using: parameters)

        browser?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .ready = state {
                    // Browser is active (permission granted), start timeout now
                    self?.startBrowseTimeout()
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                if !results.isEmpty {
                    self?.browseTimeoutTask?.cancel()
                    self?.browseTimedOut = false
                }
                self?.availableAmps = results.map { $0.endpoint }
                if results.count == 1, !(self?.isConnecting ?? false), !(self?.isConnected ?? false) {
                    self?.connect(to: results.first!.endpoint)
                } else if !results.isEmpty {
                    self?.statusMessage = "Amps Found"
                }
            }
        }
        browser?.start(queue: .main)
    }

    private func startBrowseTimeout() {
        browseTimeoutTask?.cancel()
        browseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.availableAmps.isEmpty == true, !(self?.isConnecting ?? false) {
                    self?.browseTimedOut = true
                }
            }
        }
    }

    func connect(to endpoint: NWEndpoint) {
        connection?.cancel()
        syncTimer?.invalidate()
        stopProgressPolling()
        isConnecting = true

        lastConnectedEndpoint = endpoint
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .ready = state {
                    self?.isConnecting = false
                    self?.isConnected = true
                    self?.setupReceive()
                    self?.isPlaying = false

                    if let path = self?.connection?.currentPath,
                       let remoteEndpoint = path.remoteEndpoint {
                        self?.ampHost = self?.resolveHost(from: remoteEndpoint)
                    }

                    self?.sendCommand("VERB(1)")
                    self?.sendCommand("PWR?")
                    self?.sendCommand("VOL?")
                    self?.sendCommand("MUTE?")
                    self?.sendCommand("SRC?")
                    self?.sendCommand("STREAMTYPE?")
                    self?.sendCommand("AUDIOSTATUS?")

                    self?.startProgressPolling()

                } else if case .failed = state {
                    self?.isConnecting = false
                    self?.isConnected = false
                    self?.stopProgressPolling()
                    self?.startBrowsing()
                } else if case .waiting = state {
                    self?.isConnecting = false
                    self?.isConnected = false
                    self?.stopProgressPolling()
                    self?.connection?.cancel()
                    self?.startBrowsing()
                }
            }
        }
        connection?.start(queue: .main)
    }

    func sendCommand(_ command: String) {
        let formatted = "!\(command)\r"
        guard let data = formatted.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    func togglePlayPause() {
        guard !toggleCooldown else { return }
        toggleCooldown = true
        ignoreAudioStatus = true

        // Optimistic update for instant UI feedback
        isPlaying.toggle()
        sendCommand("PLAY")

        // Allow another tap after a short cooldown to prevent double-sends
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.toggleCooldown = false
        }
        // Mute the AUDIOSTATUS handler longer so the amp's transition
        // pushes don't fight the optimistic state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.ignoreAudioStatus = false
        }
    }

    private func setupReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data, _, isComplete, error) in
            if let data = data, let response = String(data: data, encoding: .utf8) {
                let lines = response.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                DispatchQueue.main.async {
                    for line in lines where !line.isEmpty { self?.handleResponse(line) }
                }
            }
            if error == nil && !isComplete { self?.setupReceive() }
        }
    }

    private func handleResponse(_ response: String) {
        print("AMP RESPONSE: \(response)")
        let res = response.uppercased()

        // AUDIOSTATUS is the single source of truth for isPlaying.
        // VERB(1) means the amp pushes this automatically on any change.
        // Ignored briefly after a user-initiated toggle to prevent fighting
        // with the optimistic UI update.
        if res.contains("!AUDIOSTATUS") && !ignoreAudioStatus {
            if res.contains("ZERO") || res.contains("SILENT") || res.contains("NONE") {
                isPlaying = false
            } else {
                isPlaying = true
            }
        }

        if res.contains("MUTE(ON)") { isMuted = true }
        if res.contains("MUTE(OFF)") { isMuted = false }

        if res.contains("!PWR(OFF)") { isConnecting = false; statusMessage = "Standby" }
        if res.contains("!PWR(ON)") { isConnecting = false; statusMessage = "Awake" }

        if res.contains("!VOL") {
            let parts = response.components(separatedBy: CharacterSet(charactersIn: "()"))
            if parts.count >= 2, let val = Double(parts[1]) {
                currentVolume = String(format: "%.1f dB", val / 10.0)
            }
        }
    }

    // MARK: - HTTP Progress Polling (port 8080)

    private func startProgressPolling() {
        progressPollTimer?.invalidate()
        fetchPlayerData()
        progressPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchPlayTime()
            self?.fetchPlayerData()
        }
    }

    private func stopProgressPolling() {
        progressPollTimer?.invalidate()
        progressPollTimer = nil
        playbackPosition = -1
        playbackDuration = -1
    }

    private func fetchPlayTime() {
        guard let host = ampHost else { return }
        fetchDataPoint(host: host, path: "player:player/data/playTime") { [weak self] ms in
            DispatchQueue.main.async {
                self?.playbackPosition = ms >= 0 ? ms / 1000.0 : -1
            }
        }
    }

    private func fetchPlayerData() {
        guard let host = ampHost else { return }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        let path = "player:player/data"
        let roles = "value,timestamp,path,title,rowsOperation"
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedRoles = roles.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "http://\(host):8080/api/getData?path=\(encodedPath)&roles=\(encodedRoles)&_=\(Int(Date().timeIntervalSince1970 * 1000))")
        else { return }

        URLSession.shared.dataTask(with: URLRequest(url: url)) { [weak self] data, _, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let playerObj = json.first as? [String: Any]
            else { return }

            let durationMs: Double?
            if let status = playerObj["status"] as? [String: Any] {
                if let d = status["duration"] as? Double { durationMs = d }
                else if let d = status["duration"] as? Int { durationMs = Double(d) }
                else { durationMs = nil }
            } else { durationMs = nil }

            let newStreamId = playerObj["streamId"] as? Int
            let playerState = playerObj["state"] as? String

            // Extract track info from trackRoles
            var title = ""
            var artist = ""
            var artworkURL: URL? = nil
            if let trackRoles = playerObj["trackRoles"] as? [String: Any] {
                title = trackRoles["title"] as? String ?? ""
                if let iconString = trackRoles["icon"] as? String {
                    artworkURL = URL(string: iconString)
                }
                if let mediaData = trackRoles["mediaData"] as? [String: Any],
                   let metaData = mediaData["metaData"] as? [String: Any] {
                    artist = metaData["artist"] as? String ?? ""
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if let newId = newStreamId, newId != self.lastStreamId {
                    self.lastStreamId = newId
                    self.playbackPosition = 0
                }
                self.playbackDuration = (durationMs ?? 0) > 0 ? durationMs! / 1000.0 : -1
                self.trackTitle = title
                self.trackArtist = artist
                self.trackArtworkURL = artworkURL

                // Use the HTTP API state as primary source — it's fast and reliable.
                // Skip during user-initiated toggle cooldown to avoid fighting the optimistic state.
                if let state = playerState, !self.ignoreAudioStatus {
                    self.isPlaying = (state == "playing")
                }
            }
        }.resume()
    }

    private func fetchDataPoint(host: String, path: String, completion: @escaping (Double) -> Void) {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        let roles = "value%2Ctimestamp"

        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "http://\(host):8080/api/getData?path=\(encodedPath)&roles=\(roles)&_=\(Int(Date().timeIntervalSince1970 * 1000))")
        else { return }

        URLSession.shared.dataTask(with: URLRequest(url: url)) { data, _, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let valueObj = json.first as? [String: Any]
            else { return }

            let ms: Double
            if let v = valueObj["i64_"] as? Double      { ms = v }
            else if let v = valueObj["i64_"] as? Int    { ms = Double(v) }
            else if let v = valueObj["f64_"] as? Double { ms = v }
            else { return }

            completion(ms)
        }.resume()
    }

    // MARK: - Host Resolution

    private func resolveHost(from endpoint: NWEndpoint) -> String? {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr):
                return "\(addr)".components(separatedBy: "%").first
            case .ipv6(let addr):
                let clean = "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
                return "[\(clean)]"
            case .name(let name, _):
                return name.components(separatedBy: "%").first
            @unknown default: return nil
            }
        }
        return nil
    }
}
