import AppKit
import ServiceManagement
import SwiftUI

/// The window shown on first launch, and from the ? button in the popover.
///
/// It exists for one reason: the app can't show anything until macOS lets it read
/// Claude Code's login out of the Keychain, and a permission dialog that arrives
/// with no explanation is a dialog people deny. So the window says what will be
/// read and why *before* asking, then asks on an explicit click.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    /// Set once the person has connected successfully, so the window opens only on first run.
    static let seenKey = "hasSeenWelcome"

    private var window: NSWindow?

    func show(store: UsageStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Claude Usage"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(store: store) { [weak self] in
            self?.window?.close()
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct WelcomeView: View {
    let store: UsageStore
    var dismiss: () -> Void

    @AppStorage(WelcomeWindowController.seenKey) private var hasSeenWelcome = false
    @State private var isConnecting = false
    @State private var problem: Credentials.ReadError?
    @State private var connected = false
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            Hairline().padding(.vertical, 18)
            Text("What it needs, and why")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 14) {
                Requirement(
                    symbol: "key.fill",
                    title: "Claude Code's login, read from your Keychain",
                    detail: "Used to ask Claude for your plan's usage. Read-only — the app never "
                        + "refreshes or changes the token, because that would sign Claude Code out.")
                Requirement(
                    symbol: "folder.fill",
                    title: "Your Claude Code transcripts in ~/.claude",
                    detail: "Counted on this Mac to chart your own token use. The transcripts "
                        + "themselves are never sent anywhere.")
                Requirement(
                    symbol: "lock.icloud.fill",
                    title: "One HTTPS request, every 15 minutes",
                    detail: "To api.anthropic.com and nowhere else. Redirects are refused, so the "
                        + "token can't be forwarded to another host.")
            }
            Spacer(minLength: 18)
            statusArea
        }
        .padding(24)
        .frame(width: 460, height: 500)
        .background(Palette.surface)
        .onAppear { connected = !store.limits.isEmpty && store.setupProblem == nil }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Usage")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Your Claude plan limits and today's token use, in the menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connected {
                Label {
                    Text("Connected. Look for the gauge in your menu bar.")
                        .foregroundStyle(Palette.ink)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                }
                .font(.system(size: 12))
                Toggle("Open Claude Usage at login", isOn: Binding(
                    get: { opensAtLogin },
                    set: setOpensAtLogin))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink2)
                if let loginMessage {
                    Text(loginMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let problem {
                advice(for: problem)
            } else {
                // Built from Text values rather than one interpolated string: concatenating
                // Swift strings first would lose the markdown styling on "Always Allow".
                (Text("macOS may ask for permission to read the Claude Code login. Choosing ")
                 + Text("Always Allow").bold()
                 + Text(" means it won't ask again."))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if connected {
                    Button("Done") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(isConnecting ? "Waiting for permission…" : "Connect to Claude Code") {
                        Task { await connect() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting)
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Not now") { finish() }
                }
                Spacer()
                Link("How it works", destination: URL(string: "https://github.com/chrisrmullinsdesign/usage")!)
                    .font(.system(size: 11))
            }
        }
    }

    /// Each failure has exactly one next step; say that step rather than the error.
    @ViewBuilder
    private func advice(for problem: Credentials.ReadError) -> some View {
        let (title, steps): (String, [String]) = switch problem {
        case .notFound: (
            "No Claude Code login found on this Mac.",
            ["Install Claude Code, then run `claude` in Terminal and sign in.",
             "Come back here and choose Connect again."])
        case .accessDenied: (
            "macOS didn't allow the Keychain read.",
            ["Choose Connect again and pick Always Allow in the dialog.",
             "If no dialog appears, open Keychain Access, find “Claude Code-credentials”, "
             + "and check Access Control."])
        case .timedOut: (
            "Your Keychain didn't answer.",
            ["Unlock your login Keychain, then choose Connect again."])
        case .malformed: (
            "The Claude Code login couldn't be read.",
            ["Run `claude` and sign in again to rewrite it, then choose Connect."])
        }
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).foregroundStyle(Palette.ink)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            }
            .font(.system(size: 12, weight: .medium))
            ForEach(steps, id: \.self) { step in
                Text("• \(step)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.banner))
    }

    /// macOS can accept the registration and still park it behind an approval switch,
    /// so report the status back rather than assuming the toggle took effect.
    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            loginMessage = nil
        } catch {
            loginMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        if status == .requiresApproval {
            loginMessage = "Approve Claude Usage in System Settings › General › Login Items."
        }
    }

    private func connect() async {
        isConnecting = true
        problem = await store.connect()
        isConnecting = false
        if problem == nil {
            connected = true
            hasSeenWelcome = true
        }
    }

    private func finish() {
        hasSeenWelcome = true
        dismiss()
    }
}

private struct Requirement: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)
                .frame(width: 18, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
