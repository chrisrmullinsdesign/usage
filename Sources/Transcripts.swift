import Foundation

struct TokenTotals: Sendable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var messages = 0

    mutating func add(_ other: TokenTotals) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        messages += other.messages
    }
}

struct DayUsage: Sendable, Identifiable {
    let date: Date
    var totals = TokenTotals()
    var id: Date { date }
}

struct ModelUsage: Sendable, Identifiable {
    let model: String
    var totals = TokenTotals()
    var id: String { model }

    /// "claude-fable-5-1" → "Fable 5.1", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    var displayName: String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first, Int(family) == nil else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

struct LocalUsage: Sendable {
    /// The last 7 local calendar days, oldest first; the last entry is today.
    var days: [DayUsage] = []
    var todayByModel: [ModelUsage] = []
    var scannedAt: Date?

    var today: TokenTotals { days.last?.totals ?? TokenTotals() }
}

/// Totals the token usage Claude Code records on assistant messages in its local
/// transcripts (~/.claude/projects/**/*.jsonl, including nested subagent logs).
/// Files are read incrementally: each scan only parses bytes appended since the last.
actor TranscriptScanner {
    private struct Record {
        let date: Date
        let model: String
        let totals: TokenTotals
    }

    private static let needle = Array(#""usage""#.utf8)
    private static let maxLineBytes = 32 << 20
    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    private var offsets: [String: UInt64] = [:]
    /// Keyed by API message id: Claude Code writes one line per content block, so a message repeats.
    private var records: [String: Record] = [:]
    private let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainISO = ISO8601DateFormatter()

    func scan() -> LocalUsage {
        let started = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: started)
        let windowStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var filesRead = 0

        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= windowStart else { continue }
                let size = UInt64(values.fileSize ?? 0)
                var offset = offsets[url.path] ?? 0
                if size < offset { offset = 0 } // rewritten; message-id dedupe makes a re-read safe
                guard size > offset else { continue }
                offsets[url.path] = readLines(of: url, from: offset, windowStart: windowStart)
                filesRead += 1
            }
        }

        records = records.filter { $0.value.date >= windowStart }

        var days = (0..<7).map { DayUsage(date: calendar.date(byAdding: .day, value: $0 - 6, to: todayStart) ?? todayStart) }
        var models: [String: TokenTotals] = [:]
        for record in records.values {
            guard let index = calendar.dateComponents([.day], from: windowStart, to: calendar.startOfDay(for: record.date)).day,
                  days.indices.contains(index) else { continue }
            days[index].totals.add(record.totals)
            if index == days.count - 1 { models[record.model, default: TokenTotals()].add(record.totals) }
        }
        let byModel = models
            .map { ModelUsage(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.output > $1.totals.output }

        Log.write("transcripts: read \(filesRead) files, \(records.count) messages in window, "
            + "today out=\(days[6].totals.output) in=\(days[6].totals.input) msgs=\(days[6].totals.messages), "
            + "\(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return LocalUsage(days: days, todayByModel: byModel, scannedAt: Date())
    }

    /// Reads complete lines from `start` to EOF and returns the offset after the last newline,
    /// so a line Claude Code is still writing gets picked up on the next scan.
    private func readLines(of url: URL, from start: UInt64, windowStart: Date) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? handle.close() }
        var consumed = start
        var pending = Data()      // complete lines plus the start of the unfinished one
        var droppingLine = false // inside an over-long line; skip through its newline
        do {
            try handle.seek(toOffset: start)
            var atEnd = false
            while !atEnd {
                // FileHandle reads and JSONSerialization both autorelease, and concurrency threads
                // don't drain promptly: without a pool per chunk a first full scan holds ~300 MB.
                try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                        atEnd = true
                        return
                    }
                    guard let lastNewline = chunk.lastIndex(of: 0x0A) else {
                        pending.append(chunk)
                        // A line this long is a pasted image or file dump, never a usage record:
                        // stop buffering it so one huge line can't balloon memory.
                        if pending.count > Self.maxLineBytes {
                            consumed += UInt64(pending.count)
                            pending.removeAll()
                            droppingLine = true
                        }
                        return
                    }
                    let tailStart = chunk.index(after: lastNewline)
                    pending.append(chunk[chunk.startIndex..<tailStart])
                    var lines = pending[...]
                    if droppingLine, let end = lines.firstIndex(of: 0x0A) {
                        lines = lines[lines.index(after: end)...]
                        droppingLine = false
                    }
                    parse(lines, windowStart: windowStart)
                    consumed += UInt64(pending.count)
                    pending = Data(chunk[tailStart...])
                }
            }
        } catch {
            Log.write("transcripts: couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return consumed
    }

    /// Splits on newlines and only JSON-decodes lines that mention "usage".
    private func parse(_ data: Data, windowStart: Date) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            let count = buffer.count
            var lineStart = 0
            while lineStart < count {
                let newline: UnsafeMutableRawPointer? = memchr(base + lineStart, 0x0A, count - lineStart)
                let lineEnd = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let length = lineEnd - lineStart
                if length > 0, memmem(base + lineStart, length, Self.needle, Self.needle.count) != nil {
                    record(line: Data(bytes: base + lineStart, count: length), windowStart: windowStart)
                }
                lineStart = lineEnd + 1
            }
        }
    }

    private func record(line: Data, windowStart: Date) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let id = message["id"] as? String,
              let stamp = object["timestamp"] as? String,
              let date = fractionalISO.date(from: stamp) ?? plainISO.date(from: stamp),
              date >= windowStart else { return }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return }

        let totals = TokenTotals(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            messages: 1)
        // Repeated lines for one message: keep the most complete (largest output) copy.
        if let existing = records[id], existing.totals.output >= totals.output { return }
        records[id] = Record(date: date, model: model, totals: totals)
    }
}
