import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Palette
// Surfaces, ink, the blue accent ramp and the fixed status colours from the dataviz
// reference palette. Meters: fill carries severity, track is a lighter step of that ramp.

enum Palette {
    static let surface = Color.adaptive(light: 0xFCFCFB, dark: 0x1A1A19)
    static let banner = Color.adaptive(light: 0xF0EFEC, dark: 0x2C2C2A)
    static let ink = Color.adaptive(light: 0x0B0B0B, dark: 0xFFFFFF)
    static let ink2 = Color.adaptive(light: 0x52514E, dark: 0xC3C2B7)
    static let muted = Color(hex: 0x898781)
    static let hairline = Color.adaptive(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let baseline = Color.adaptive(light: 0xC3C2B7, dark: 0x383835)
    static let accent = Color.adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let accentTrack = Color.adaptive(light: 0xCDE2FB, dark: 0x104281)
    static let deemphasis = Color.adaptive(light: 0xC3C2B7, dark: 0x52514E)
    static let deemphasisHover = Color(hex: 0x898781)
    static let warning = Color(hex: 0xFAB219)
    static let serious = Color(hex: 0xEC835A)
    static let critical = Color(hex: 0xD03B3B)
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Severity {
    case normal, warning, serious, critical

    /// Uses the API's own severity; unknown values fall back to thresholds on the percent.
    init(api: String?, percent: Double) {
        switch api?.lowercased() {
        case "normal", "ok", "good", "low": self = .normal
        case "warning", "elevated", "medium": self = .warning
        case "serious", "high": self = .serious
        case "critical", "exceeded", "limited", "blocked": self = .critical
        default: self = percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
        }
    }

    var fill: Color {
        switch self {
        case .normal: Palette.accent
        case .warning: Palette.warning
        case .serious: Palette.serious
        case .critical: Palette.critical
        }
    }

    var track: Color { self == .normal ? Palette.accentTrack : fill.opacity(0.25) }

    /// Status never rides on colour alone: non-normal states also get an icon and words.
    var note: String? {
        switch self {
        case .normal: nil
        case .warning: "Getting close"
        case .serious: "Nearly used"
        case .critical: "At limit"
        }
    }

    var symbol: String { self == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill" }
}

// MARK: - Formatting

func percentText(_ percent: Double) -> String { "\(Int(percent.rounded()))%" }

/// 1,284 → "1.3K", 2,652,134 → "2.65M".
func compact(_ value: Int) -> String {
    let v = Double(value)
    switch v {
    case 1e9...: return String(format: "%.2fB", v / 1e9)
    case 1e7...: return String(format: "%.1fM", v / 1e6)
    case 999_500...: return String(format: "%.2fM", v / 1e6)
    case 1e5...: return String(format: "%.0fK", v / 1e3)
    case 1e3...: return String(format: "%.1fK", v / 1e3)
    default: return "\(value)"
    }
}

func resetDescription(_ date: Date?, now: Date) -> String {
    guard let date else { return "No reset scheduled" }
    let minutes = Int(date.timeIntervalSince(now) / 60)
    guard date > now else { return "Resetting now" }
    let span = minutes >= 1440 ? "\(minutes / 1440)d \(minutes % 1440 / 60)h"
        : minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m"
        : "\(max(minutes, 1))m"
    let when = Calendar.current.isDate(date, inSameDayAs: now)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    return "Resets in \(span) · \(when)"
}

/// "4d", "9h", "30m" until the date, or nil if unknown/past.
func shortRemaining(_ date: Date?, now: Date) -> String? {
    guard let date, date > now else { return nil }
    let minutes = Int(date.timeIntervalSince(now) / 60)
    if minutes >= 1440 { return "\(minutes / 1440)d" }
    if minutes >= 60 { return "\(minutes / 60)h" }
    return "\(max(minutes, 1))m"
}

/// Compares usage so far with an even burn across the 7-day window.
struct Pace {
    let expected: Double   // % that would be used by now at an even pace
    let projected: Double  // % at reset if the current rate continues

    init?(limit: PlanLimit, now: Date) {
        // Too early in the window the rate is noise.
        guard let elapsed = limit.elapsedFraction(now: now), elapsed >= 0.03 else { return nil }
        expected = elapsed * 100
        projected = limit.percent / elapsed
    }

    var summary: String {
        if projected >= 100 { return "On track to hit the limit before reset" }
        if projected >= 85 { return "Heading for ~\(percentText(projected)) by reset" }
        return projected < 50 ? "Well under pace · ~\(percentText(projected)) by reset"
                              : "On pace · ~\(percentText(projected)) by reset"
    }

    var isOver: Bool { projected >= 100 }
}

// MARK: - Menu bar label

enum MenuBarMode: String, CaseIterable, Identifiable {
    case weekly, weeklyReset, icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: "Weekly %"
        case .weeklyReset: "Weekly % · days left"
        case .icon: "Icon only"
        }
    }
}

struct MenuBarLabel: View {
    let store: UsageStore
    @AppStorage("menuBarMode") private var mode: MenuBarMode = .weekly

    var body: some View {
        let icon = Image(systemName: store.menuBarSymbol)
        let weekly = store.weekly.map { percentText($0.percent) } ?? "–"
        switch mode {
        case .icon: icon
        case .weekly: HStack(spacing: 4) { icon; Text(weekly) }
        case .weeklyReset:
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 4) {
                    icon
                    Text(weekly + (store.weekly.flatMap { shortRemaining($0.resetsAt, now: context.date) }.map { " · \($0)" } ?? ""))
                }
            }
        }
    }
}

// MARK: - Popover

struct UsagePopover: View {
    let store: UsageStore
    @AppStorage("menuBarMode") private var mode: MenuBarMode = .weekly
    @State private var hoveredDay: Int?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                    .padding(.bottom, 12)
                if let message = store.status.message {
                    banner(message)
                        .padding(.bottom, 12)
                }
                planSection(now: context.date)
                Hairline().padding(.vertical, 14)
                localSection
                Hairline().padding(.vertical, 12)
                footer
            }
            .padding(16)
            .frame(width: 340)
        }
        .background(Palette.surface)
        // The popover's view persists between openings, so onAppear fires only once;
        // the window becoming key fires on every open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await store.refresh(minInterval: UsageStore.staleOnOpen) }
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Claude usage")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let plan = store.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().stroke(Palette.baseline, lineWidth: 1))
            }
            Spacer()
            Text(updatedText(now: now))
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            if store.isRefreshing {
                ProgressView().controlSize(.mini).frame(width: 16, height: 16)
            } else {
                Button {
                    Task { await store.refresh(minInterval: 15, manual: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.ink2)
                .help("Refresh now")
            }
        }
    }

    private func updatedText(now: Date) -> String {
        guard let updatedAt = store.updatedAt else { return store.isRefreshing ? "Loading…" : "" }
        let seconds = now.timeIntervalSince(updatedAt)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        return "Updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .foregroundStyle(Palette.ink)
                if let updatedAt = store.updatedAt, !store.limits.isEmpty {
                    Text("Showing figures from \(updatedAt.formatted(date: .omitted, time: .shortened)).")
                        .foregroundStyle(Palette.ink2)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.banner))
    }

    private func planSection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.limits.isEmpty {
                Text(store.status == .loading ? "Loading plan limits…" : "No plan usage available.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            } else {
                if let weekly = store.weekly {
                    WeeklyHero(limit: weekly, now: now)
                }
                ForEach(store.scopedWeekly) { limit in
                    LimitMeter(limit: limit, now: now, titlePrefix: "Weekly · ")
                }
                ForEach(store.otherLimits) { limit in
                    LimitMeter(limit: limit, now: now)
                }
                if !store.breakdown.isEmpty {
                    Text("This week by surface: " + store.breakdown
                        .map { "\($0.displayName) \(percentText($0.percent))" }
                        .joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink2)
                }
            }
        }
    }

    private var localSection: some View {
        let local = store.local
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Code on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if local.scannedAt != nil {
                    Text("Today · \(local.today.messages) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
            }

            if local.scannedAt == nil {
                Text("Reading transcripts…")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 0) {
                    StatTile(label: "Output", value: local.today.output)
                    StatTile(label: "Input", value: local.today.input)
                    StatTile(label: "Cache write", value: local.today.cacheWrite)
                    StatTile(label: "Cache read", value: local.today.cacheRead)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(chartReadout(local.days))
                        .font(.system(size: 11))
                        .foregroundStyle(hoveredDay == nil ? Palette.muted : Palette.ink2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    DailyColumns(days: local.days, hovered: $hoveredDay)
                }
                .padding(.top, 4)

                if !local.todayByModel.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(local.todayByModel) { model in
                            HStack {
                                Text(model.displayName)
                                    .foregroundStyle(Palette.ink)
                                Spacer()
                                Text("\(model.totals.messages) msgs")
                                    .foregroundStyle(Palette.muted)
                                Text("\(compact(model.totals.output)) out")
                                    .foregroundStyle(Palette.ink2)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 11).monospacedDigit())
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func chartReadout(_ days: [DayUsage]) -> String {
        guard let index = hoveredDay, days.indices.contains(index) else {
            return "Output tokens per day · last 7 days"
        }
        let day = days[index]
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return "\(date) · \(compact(day.totals.output)) out · \(compact(day.totals.input)) in · "
            + "\(compact(day.totals.cacheRead)) cache read · \(day.totals.messages) msgs"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Menu bar shows", selection: $mode) {
                        ForEach(MenuBarMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "menubar.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("What the menu bar shows")

                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: setOpensAtLogin))
                    .toggleStyle(.checkbox)

                Spacer()

                Link("Usage page", destination: URL(string: "https://claude.ai/settings/usage")!)
                Button {
                    WelcomeWindowController.shared.show(store: store)
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("What this app reads, and how to reconnect it")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.ink2)

            if let loginMessage {
                Text(loginMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        if status == .requiresApproval {
            loginMessage = "Approve ClaudeUsage in System Settings › General › Login Items."
        }
    }
}

// MARK: - Components

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }
}

/// The headline weekly figure: big percent, a meter with an "even pace" tick, the reset countdown and a projection.
struct WeeklyHero: View {
    let limit: PlanLimit
    let now: Date

    var body: some View {
        let severity = Severity(api: limit.severity, percent: limit.percent)
        let fraction = min(max(limit.percent / 100, 0), 1)
        let pace = Pace(limit: limit, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Weekly · all models")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if let note = severity.note {
                    Image(systemName: severity.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(severity.fill)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink2)
                }
            }
            Text(percentText(limit.percent))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.ink)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(severity.track)
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(severity.fill)
                            .frame(width: max(8, geometry.size.width * fraction))
                    }
                    if let pace {
                        Rectangle()
                            .fill(Palette.ink2)
                            .frame(width: 2, height: 14)
                            .offset(x: geometry.size.width * min(pace.expected / 100, 1) - 1)
                    }
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(resetDescription(limit.resetsAt, now: now))
                    .foregroundStyle(Palette.ink2)
                if let pace {
                    HStack(spacing: 4) {
                        if pace.isOver {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.serious)
                        }
                        Text(pace.summary)
                    }
                    .foregroundStyle(pace.isOver ? Palette.ink : Palette.muted)
                    Text("Tick marks an even pace: \(percentText(pace.expected)) used by now.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.muted)
                }
            }
            .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
    }
}

struct LimitMeter: View {
    let limit: PlanLimit
    let now: Date
    var titlePrefix = ""

    var body: some View {
        let severity = Severity(api: limit.severity, percent: limit.percent)
        let fraction = min(max(limit.percent / 100, 0), 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titlePrefix + limit.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                if let note = severity.note {
                    Image(systemName: severity.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(severity.fill)
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink2)
                }
                Text(percentText(limit.percent))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(severity.track)
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(severity.fill)
                            .frame(width: max(6, geometry.size.width * fraction))
                    }
                }
            }
            .frame(height: 6)
            Text(resetDescription(limit.resetsAt, now: now))
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatTile: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
            Text(compact(value))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Seven columns of output tokens; today in the accent, earlier days de-emphasised.
/// Every column carries its value on the cap; hover shows the full day in the readout.
struct DailyColumns: View {
    let days: [DayUsage]
    @Binding var hovered: Int?

    private let plotHeight: CGFloat = 52

    var body: some View {
        let peak = max(days.map(\.totals.output).max() ?? 0, 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let isToday = index == days.count - 1
                    let isHovered = hovered == index
                    let output = day.totals.output
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        Text(compact(output))
                            .font(.system(size: 9))
                            .foregroundStyle(isToday || isHovered ? Palette.ink2 : Palette.muted)
                            .lineLimit(1)
                        UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(isToday ? Palette.accent : isHovered ? Palette.deemphasisHover : Palette.deemphasis)
                            .frame(width: 20, height: output == 0 ? 0 : max(3, plotHeight * CGFloat(output) / CGFloat(peak)))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: plotHeight + 16)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = index } else if hovered == index { hovered = nil }
                    }
                }
            }
            Rectangle().fill(Palette.baseline).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Text(index == days.count - 1 ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9))
                        .foregroundStyle(index == days.count - 1 ? Palette.ink2 : Palette.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days
            .map { "\($0.date.formatted(.dateTime.weekday(.wide))): \(compact($0.totals.output)) output tokens" }
            .joined(separator: ", "))
    }
}
