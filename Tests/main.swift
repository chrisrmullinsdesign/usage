import Foundation

// Minimal assertion runner: top-level code, so no XCTest or package manager is needed.
// Each failure is printed with its line; any failure makes the process exit non-zero.
var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "", line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func limit(_ kind: String = "weekly_all", percent: Double, resetsIn: TimeInterval?, now: Date) -> PlanLimit {
    PlanLimit(kind: kind, percent: percent, severity: nil,
              resetsAt: resetsIn.map { now.addingTimeInterval($0) }, scope: nil)
}

let now = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400

// MARK: Token validation — nothing malformed may reach a header
expect(Credentials.isWellFormed(token: "sk-ant-oat01-abcDEF_123-xyz"))
expect(!Credentials.isWellFormed(token: ""))
expect(!Credentials.isWellFormed(token: "abc def"), "space")
expect(!Credentials.isWellFormed(token: "abc\r\nX-Injected: 1"), "CRLF header injection")
expect(!Credentials.isWellFormed(token: "abc\ndef"), "newline")
expect(!Credentials.isWellFormed(token: "tökén"), "non-ASCII")
expect(Credentials.isWellFormed(token: String(repeating: "a", count: 4096)))
expect(!Credentials.isWellFormed(token: String(repeating: "a", count: 4097)), "too long")

// MARK: Pace and the weekly window
let half = limit(percent: 50, resetsIn: 3.5 * day, now: now)
expect(abs((half.elapsedFraction(now: now) ?? -1) - 0.5) < 1e-9, "half-way through the week")
let halfPace = Pace(limit: half, now: now)
expect(abs((halfPace?.expected ?? -1) - 50) < 1e-6)
expect(abs((halfPace?.projected ?? -1) - 100) < 1e-6, "50% used at 50% elapsed projects to 100%")
expect(halfPace?.isOver == true)

let slow = Pace(limit: limit(percent: 10, resetsIn: 3.5 * day, now: now), now: now)
expect(abs((slow?.projected ?? -1) - 20) < 1e-6)
expect(slow?.isOver == false)
expect(slow?.summary?.hasPrefix("Well under pace") == true, slow?.summary ?? "nil")

// Early in the week the tick still shows, but a projection would be noise.
let early = Pace(limit: limit(percent: 14, resetsIn: 6.2 * day, now: now), now: now)
expect(early != nil && early?.projected == nil && early?.summary == nil && early?.isOver == false,
       "a day-one burst must not warn that the limit will be hit")
expect(abs((early?.expected ?? -1) - 11.43) < 0.1)
expect(Pace(limit: limit(percent: 20, resetsIn: 5.2 * day, now: now), now: now)?.projected != nil,
       "projection starts once a quarter of the week has passed")
expect(limit(percent: 5, resetsIn: -60, now: now).elapsedFraction(now: now) == nil, "already reset")
expect(limit(percent: 5, resetsIn: 8 * day, now: now).elapsedFraction(now: now) == nil, "reset further out than a week")
expect(limit(percent: 5, resetsIn: nil, now: now).elapsedFraction(now: now) == nil, "no reset time")
expect(limit("session", percent: 5, resetsIn: 2 * day, now: now).elapsedFraction(now: now) == nil, "not a weekly limit")

// MARK: Formatting
expect(shortRemaining(now.addingTimeInterval(4 * day + 3600), now: now) == "4d")
expect(shortRemaining(now.addingTimeInterval(9 * 3600 + 60), now: now) == "9h")
expect(shortRemaining(now.addingTimeInterval(30 * 60 + 5), now: now) == "30m")
expect(shortRemaining(now.addingTimeInterval(-1), now: now) == nil)
expect(shortRemaining(nil, now: now) == nil)
expect(resetDescription(nil, now: now) == "No reset scheduled")
expect(resetDescription(now.addingTimeInterval(-5), now: now) == "Resetting now")
expect(resetDescription(now.addingTimeInterval(3 * day + 2 * 3600), now: now).hasPrefix("Resets in 3d 2h"))
expect(compact(999) == "999")
expect(compact(1_284) == "1.3K")
expect(compact(2_652_134) == "2.65M")
expect(percentText(12.5) == "13%" || percentText(12.5) == "12%")

// MARK: Severity falls back to thresholds on unknown API values
expect(Severity(api: nil, percent: 10) == .normal)
expect(Severity(api: nil, percent: 85) == .warning)
expect(Severity(api: nil, percent: 99) == .critical)
expect(Severity(api: "something-new", percent: 99) == .critical)
expect(Severity(api: "warning", percent: 1) == .warning, "the API's own severity wins")

// MARK: API decoding
let json = """
{"limits":[
  {"kind":"weekly_all","percent":13.0,"severity":"normal","resets_at":"2026-11-09T10:00:00.000Z"},
  {"kind":"weekly_scoped","percent":3.0,"resets_at":"2026-11-09T10:00:00Z","scope":{"model":{"display_name":"Fable"}}}
],"seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":9.0}]}}
"""
if let response = try? UsageResponse.decoder.decode(UsageResponse.self, from: Data(json.utf8)) {
    let limits = response.resolvedLimits
    expect(limits.count == 2)
    expect(limits.first?.title == "All models")
    expect(limits.last?.title == "Fable")
    expect(limits.last?.resetsAt != nil, "plain and fractional ISO dates both decode")
    expect(response.sevenDayBreakdown?.rows.first?.displayName == "Claude Code")
} else {
    expect(false, "weekly-only response failed to decode")
}

let legacy = #"{"five_hour":{"utilization":40,"resets_at":"2026-11-05T20:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2026-11-09T10:00:00Z"}}"#
if let response = try? UsageResponse.decoder.decode(UsageResponse.self, from: Data(legacy.utf8)) {
    expect(response.resolvedLimits.map(\.kind) == ["session", "weekly_all"], "older top-level windows still resolve")
} else {
    expect(false, "legacy response failed to decode")
}
expect((try? UsageResponse.decoder.decode(UsageResponse.self, from: Data("{}".utf8)))?.resolvedLimits.isEmpty == true,
       "an empty response yields no limits rather than throwing")

// MARK: Misc
expect(ModelUsage(model: "claude-fable-5-1").displayName == "Fable 5.1")
expect(ModelUsage(model: "claude-haiku-4-5-20251001").displayName == "Haiku 4.5")
expect(MenuBarMode(rawValue: "both") == nil && MenuBarMode(rawValue: "session") == nil,
       "stored pre-weekly modes must fail to decode so @AppStorage falls back to the default")
expect(MenuBarMode(rawValue: "icon") == .icon, "icon-only preference survives")

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
