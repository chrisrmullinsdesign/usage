import Foundation
import Observation

// MARK: - Log

/// Appends to ~/Library/Logs/ClaudeUsage.log (and stderr). Never log the token.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeUsage.log")

    static func write(_ message: String) {
        guard let data = "\(Date().formatted(.iso8601)) \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func trimIfLarge() {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Credentials

/// An OAuth token to ask Claude for plan usage with, and where it came from.
struct Credentials: Sendable {
    /// Which Keychain item the token came from. Worth tracking because the two age very
    /// differently: Claude Code renews its own token, while a pasted one just expires.
    enum Source: Sendable { case claudeCode, pasted }

    let accessToken: String
    let expiresAt: Date?
    let planLabel: String?
    var source: Source = .claudeCode

    enum ReadError: LocalizedError {
        case notFound, accessDenied, malformed, timedOut

        var errorDescription: String? {
            switch self {
            case .notFound: "No Claude Code login found in Keychain. Install Claude Code and sign in."
            case .accessDenied: "macOS didn't allow the Keychain read. Click ? in the popover, then Connect, and choose Always Allow."
            case .timedOut: "Keychain didn't answer in time. It may be locked."
            case .malformed: "Couldn't read the Claude Code login from Keychain."
            }
        }
    }

    /// Prefers a token the person pasted in, and falls back to Claude Code's login.
    /// The pasted token wins because storing one is an explicit choice, usually made
    /// precisely because the Claude Code path didn't work on this Mac.
    static func resolve(allowPrompt: Bool = false) throws -> Credentials {
        if let pasted = TokenStore.read() {
            return Credentials(accessToken: pasted, expiresAt: nil, planLabel: nil, source: .pasted)
        }
        return try read(allowPrompt: allowPrompt)
    }

    /// `security`'s exit code for "no such Keychain item" (errSecItemNotFound), as opposed
    /// to the user denying access, which exits non-zero with a different code.
    private static let itemNotFoundStatus: Int32 = 44

    /// Reads via the `security` CLI. Read-only: this app never refreshes or writes the token,
    /// because rotating it would sign Claude Code out.
    ///
    /// - Parameter allowPrompt: pass `true` only from the welcome window. macOS may put up a
    ///   Keychain dialog the first time; a background poll must not sit behind one, but the
    ///   onboarding read is a direct response to a click, so it waits for the person to answer.
    static func read(allowPrompt: Bool = false) throws -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A locked Keychain can leave `security` waiting on an unlock dialog; don't let that stall polling.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + (allowPrompt ? 180 : 15), execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit else { throw ReadError.timedOut }
        guard process.terminationStatus == 0 else {
            throw process.terminationStatus == itemNotFoundStatus ? ReadError.notFound : ReadError.accessDenied
        }

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw ReadError.malformed }

        return Credentials(
            accessToken: token,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            planLabel: planLabel(subscription: oauth["subscriptionType"] as? String,
                                 tier: oauth["rateLimitTier"] as? String))
    }

    /// "default_claude_max_20x" → "Max 20×"; otherwise the capitalised subscription type.
    private static func planLabel(subscription: String?, tier: String?) -> String? {
        if let tier, let range = tier.range(of: #"max_\d+x"#, options: .regularExpression) {
            return "Max \(tier[range].dropFirst(4).dropLast())×"
        }
        return subscription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }
}

// MARK: - API model

struct PlanLimit: Decodable, Identifiable {
    struct Scope: Decodable {
        struct ModelRef: Decodable { let displayName: String? }
        let model: ModelRef?
    }

    let kind: String
    let percent: Double
    let severity: String?
    let resetsAt: Date?
    let scope: Scope?

    var id: String { kind + (scope?.model?.displayName ?? "") }

    static let weekLength: TimeInterval = 7 * 24 * 3600

    /// How far through the 7-day window we are (0...1), derived from the reset time.
    func elapsedFraction(now: Date) -> Double? {
        guard kind.hasPrefix("weekly"), let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= Self.weekLength else { return nil }
        return 1 - remaining / Self.weekLength
    }

    var title: String {
        switch kind {
        case "session": "Current session"
        case "weekly_all": "All models"
        case "weekly_scoped": scope?.model?.displayName ?? "Scoped"
        default: kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Response of GET /api/oauth/usage — the same data Claude Code's /usage shows.
struct UsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: Date?
    }

    struct Breakdown: Decodable {
        struct Row: Decodable, Identifiable {
            let key: String
            let displayName: String
            let percent: Double
            var id: String { key }
        }
        let rows: [Row]
    }

    let limits: [PlanLimit]?
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayBreakdown: Breakdown?

    /// Prefers the `limits` array; falls back to the older top-level windows.
    var resolvedLimits: [PlanLimit] {
        if let limits, !limits.isEmpty { return limits }
        return [("session", fiveHour), ("weekly_all", sevenDay)].compactMap { kind, window in
            guard let window, let utilization = window.utilization else { return nil }
            return PlanLimit(kind: kind, percent: utilization, severity: nil, resetsAt: window.resetsAt, scope: nil)
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = fractional.date(from: string) ?? plain.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(string)"))
        }
        return decoder
    }()
}

// MARK: - Store

/// A redirect would carry the Authorization header to wherever it points; treat it as a failed response instead.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum FetchStatus: Equatable {
    case loading, ok
    case stale(String)
    case failed(String)

    var message: String? {
        switch self {
        case .stale(let text), .failed(let text): text
        case .loading, .ok: nil
        }
    }
}

@MainActor @Observable
final class UsageStore {
    /// One store for the process: the scene and the app delegate both need it,
    /// and a second one would mean a second poll timer and transcript scanner.
    static let shared = UsageStore()

    private(set) var limits: [PlanLimit] = []
    private(set) var breakdown: [UsageResponse.Breakdown.Row] = []
    private(set) var plan: String?
    private(set) var updatedAt: Date?
    private(set) var status: FetchStatus = .loading
    private(set) var isRefreshing = false
    private(set) var local = LocalUsage()
    /// Whether Claude specifically rejected the token (401/403), as opposed to the request
    /// failing for some unrelated reason. Only an auth rejection says anything about the token.
    private(set) var lastAuthRejected = false

    /// The most recent Keychain failure, of any kind, or nil once a read succeeds.
    /// This has to cover *every* failure: the welcome window treats nil as "connected",
    /// so narrowing it to the failures a user can act on would report success after a
    /// timed-out or malformed read.
    private(set) var lastReadError: Credentials.ReadError?

    @ObservationIgnored private let scanner = TranscriptScanner()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var backoffUntil: Date?

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Plan limits move slowly (weekly window), so poll gently.
    static let pollInterval: TimeInterval = 15 * 60
    /// Opening the popover only refreshes figures older than this.
    static let staleOnOpen: TimeInterval = 5 * 60

    /// No disk cache, no cookies, no redirects: the bearer token only ever goes to `endpoint`.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    init() {
        Log.trimIfLarge()
        Log.write("launch")
        Task { await refresh() }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = 60 // let macOS coalesce the wake-up with other work
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Until the welcome window has been answered, leave the Keychain alone: the first read
    /// should follow the explanation and an explicit click, not race them at launch.
    private var awaitingWelcome: Bool {
        !UserDefaults.standard.bool(forKey: WelcomeWindowController.seenKey)
    }

    var weekly: PlanLimit? { limits.first { $0.kind == "weekly_all" } }
    /// Per-model weekly limits (e.g. Fable), highest usage first.
    var scopedWeekly: [PlanLimit] { limits.filter { $0.kind == "weekly_scoped" }.sorted { $0.percent > $1.percent } }
    /// Anything else the API returns (e.g. a session window, if it ever comes back).
    var otherLimits: [PlanLimit] { limits.filter { $0.kind != "weekly_all" && $0.kind != "weekly_scoped" } }

    var menuBarSymbol: String {
        // Any fetch problem (expired token, offline, rate limited) flags the menu bar, so frozen figures don't pass as live.
        if status.message != nil { return "exclamationmark.triangle" }
        guard let weekly else { return "gauge.with.dots.needle.0percent" }
        switch weekly.percent {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    /// The welcome window's Connect button. One read that is allowed to sit behind a Keychain
    /// dialog for as long as the person needs, then the usual fetch. Returns what still needs
    /// fixing, or nil if the app is now connected.
    func connect() async -> Credentials.ReadError? {
        await refresh(manual: true, allowPrompt: true)
        return lastReadError
    }

    /// What happened to a token the person pasted in.
    enum SaveOutcome {
        /// Stored and confirmed working.
        case connected
        /// Claude refused it. Not kept.
        case rejected(String)
        /// Stored, but something unrelated stopped us confirming it — no network, or a
        /// rate limit. Kept, because discarding a token over a transient failure would
        /// lose something that is probably fine.
        case savedUnverified(String)
    }

    /// True when the token in use was pasted in rather than read from Claude Code.
    var usesPastedToken: Bool { TokenStore.read() != nil }

    /// Stores a pasted token, then immediately tries to use it. A token that doesn't work
    /// isn't kept: leaving a bad one behind would silently shadow the Claude Code login.
    /// Returns nil on success, or a message explaining what went wrong.
    func savePastedToken(_ token: String) async -> SaveOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("Paste a token first.") }

        let previous = TokenStore.read()
        do {
            try TokenStore.save(trimmed)
        } catch {
            return .rejected(error.localizedDescription)
        }

        await refresh(manual: true)
        if status == .ok, lastReadError == nil {
            Log.write("pasted token accepted (\(trimmed.count) chars)")
            return .connected
        }

        guard lastAuthRejected else {
            // Length only — never the token itself. Enough to tell a truncated paste from
            // a rejected one without putting a credential in a log file.
            Log.write("pasted token saved but unverified (\(trimmed.count) chars): "
                      + (status.message ?? "no status message"))
            return .savedUnverified((status.message ?? "Couldn't reach Claude just now.")
                + " The token was saved and will be used at the next refresh.")
        }

        // Claude actually refused it, so put back whatever was there before.
        if let previous { try? TokenStore.save(previous) } else { try? TokenStore.clear() }
        Log.write("pasted token rejected (\(trimmed.count) chars), reverted")
        return .rejected("Claude rejected that token. Check you copied the whole "
                         + "accessToken value, and that it hasn't expired.")
    }

    /// Forgets the pasted token and goes back to Claude Code's login.
    func forgetPastedToken() async {
        try? TokenStore.clear()
        Log.write("pasted token cleared")
        await refresh(manual: true)
    }

    /// - Parameters:
    ///   - minInterval: skip if the last attempt was more recent (debounces popover opens and clicks).
    ///   - manual: a user click ignores the rate-limit backoff.
    ///   - allowPrompt: let the Keychain read wait on a permission dialog (onboarding only).
    func refresh(minInterval: TimeInterval = 0, manual: Bool = false, allowPrompt: Bool = false) async {
        guard !isRefreshing, Date().timeIntervalSince(lastAttempt) >= minInterval else { return }
        isRefreshing = true
        lastAttempt = Date()
        defer { isRefreshing = false }

        let scanner = scanner
        let scan = Task(priority: .utility) { await scanner.scan() }
        let backoffElapsed = backoffUntil.map { Date() >= $0 } ?? true
        if (allowPrompt || !awaitingWelcome) && (manual || backoffElapsed) {
            await fetchPlanUsage(allowPrompt: allowPrompt)
        }
        local = await scan.value
    }

    private func fetchPlanUsage(allowPrompt: Bool = false) async {
        let credentials: Credentials
        do {
            credentials = try await Task.detached(priority: allowPrompt ? .userInitiated : .utility) {
                try Credentials.resolve(allowPrompt: allowPrompt)
            }.value
        } catch {
            lastReadError = error as? Credentials.ReadError ?? .malformed
            status = .failed(error.localizedDescription)
            Log.write("keychain: \(error.localizedDescription)")
            return
        }
        lastReadError = nil
        plan = credentials.planLabel

        if let expiry = credentials.expiresAt, expiry < Date() {
            status = .stale("Claude Code's login token has expired. Open Claude Code and it will renew it.")
            Log.write("token expired at \(expiry.formatted(.iso8601))")
            return
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let code: Int
        do {
            let (body, response) = try await Self.session.data(for: request)
            data = body
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            status = .stale("Couldn't reach Claude: \(error.localizedDescription)")
            Log.write("usage request failed: \(error.localizedDescription)")
            return
        }

        switch code {
        case 200:
            do {
                let decoded = try UsageResponse.decoder.decode(UsageResponse.self, from: data)
                lastAuthRejected = false
                limits = decoded.resolvedLimits
                breakdown = decoded.sevenDayBreakdown?.rows.filter { $0.percent > 0 } ?? []
                updatedAt = Date()
                status = .ok
                backoffUntil = nil
                Log.write("usage 200: " + limits.map { "\($0.id)=\(Int($0.percent))%" }.joined(separator: " "))
            } catch {
                status = .stale("Claude's usage response changed shape; showing older figures.")
                Log.write("usage decode failed: \(error)")
            }
        case 401, 403:
            lastAuthRejected = true
            status = .stale(credentials.source == .pasted
                ? "The token you pasted has expired or been revoked. Paste a fresh one."
                : "Claude rejected the login token. Open Claude Code to renew it.")
            Log.write("usage HTTP \(code) (\(credentials.source == .pasted ? "pasted" : "claude code") token)")
        case 429:
            backoffUntil = Date().addingTimeInterval(30 * 60)
            status = .stale("Rate limited by Claude. Trying again in 30 minutes.")
            Log.write("usage HTTP 429, backing off")
        default:
            status = .stale("Claude returned HTTP \(code).")
            Log.write("usage HTTP \(code)")
        }
    }
}
