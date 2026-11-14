import Foundation

enum RecordingCleanup {
    enum Mode: String { case audio, recording }
    struct Policy: Equatable {
        let mode: Mode
        let days: Int
    }

    static func policy(in config: [String: Any]) throws -> Policy? {
        guard let value = config["cleanup"] else { return nil }
        guard value is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let rawMode = Config.value(.cleanupMode, in: config) ?? Config.defaultString(.cleanupMode)
        guard let mode = rawMode as? String else { throw CocoaError(.fileReadCorruptFile) }
        if mode == "off" { return nil }
        guard let mode = Mode(rawValue: mode), let number = Config.value(.cleanupDays, in: config) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let days = Int(number.stringValue), valid(days: days) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return Policy(mode: mode, days: days)
    }

    static func valid(days: Int) -> Bool { days > 0 && days <= Int.max / 86_400 }

    static func started(in meta: [String: Any]) -> Date? {
        guard let text = meta["started"] as? String else { return nil }
        let format = ISO8601DateFormatter()
        if let date = format.date(from: text) { return date }
        format.formatOptions.insert(.withFractionalSeconds)
        return format.date(from: text)
    }

    /// Only physical audio owned by this session, including interrupted archive leftovers.
    static func audioFiles(in dir: URL, meta: [String: Any]) throws -> [URL] {
        guard let files = meta["files"] as? [String: String] else { throw CocoaError(.fileReadCorruptFile) }
        let parsed = try SessionMeta.read(from: dir)
        let known = Set(["mic", "system", "source"] + (parsed.callAudio?.tracks.map(\.fileKey) ?? []))
        guard Set(files.keys).isSubset(of: known) else { throw CocoaError(.fileReadCorruptFile) }
        let archived: [String: String]
        if let value = meta["archived_from"] {
            guard let parsed = value as? [String: String] else { throw CocoaError(.fileReadCorruptFile) }
            archived = parsed
        } else { archived = [:] }
        guard Set(archived.keys).isSubset(of: known) else { throw CocoaError(.fileReadCorruptFile) }
        var names: Set<String> = ["mic.caf", "system.caf", "audio.m4a", "audio.tmp.m4a",
                                  "mixed.m4a", "mixed.tmp.m4a", "multichannel.m4a", "multichannel.tmp.m4a"]
        for name in Array(files.values) + Array(archived.values) {
            guard name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("\\"),
                  ["caf", "m4a", "wav"].contains((name as NSString).pathExtension.lowercased()) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            names.insert(name)
            let stem = (name as NSString).deletingPathExtension
            names.insert(stem + ".caf")
            names.insert(stem + ".m4a")
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        names.formUnion(entries.filter {
            ($0.hasPrefix("diarization-source-") && $0.hasSuffix(".caf"))
                || ($0.hasPrefix(".archive-") && $0.hasSuffix(".m4a"))
        })
        return try names.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard entries.contains(name) else { return nil }
            let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            guard type == .typeRegular else { throw CocoaError(.fileReadNoPermission) }
            return url
        }
    }
}

@MainActor
final class RecordingCleanupController {
    typealias Recycle = @MainActor (URL, @escaping @MainActor @Sendable (URL?, Error?) -> Void) -> Void
    private let root: () -> URL
    private let config: () throws -> [String: Any]
    private let busy: (URL) -> Bool
    private let recycle: Recycle
    private let now: () -> Date
    private let interval: TimeInterval
    private let operations: ProcessingOperations
    let reportURL: URL
    var onChange: (() -> Void)?
    private var timer: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var stopped = false
    private(set) var status = ""
    var isRunning: Bool { work != nil }

    init(root: @escaping () -> URL, operations: ProcessingOperations = .shared,
         config: @escaping () throws -> [String: Any] = {
             try Config.requireReadable(); return Config.raw()
         }, busy: @escaping (URL) -> Bool = { _ in false },
         reportURL: URL = Home.current.configDirectory.appendingPathComponent("cleanup-report.txt"),
         now: @escaping () -> Date = Date.init, interval: TimeInterval = 86_400,
         recycle: @escaping Recycle = SessionDeletionController.moveToTrash) {
        self.root = root; self.operations = operations; self.config = config; self.busy = busy
        self.reportURL = reportURL; self.now = now; self.interval = interval; self.recycle = recycle
    }

    deinit { timer?.cancel(); work?.cancel() }

    func start() {
        guard timer == nil, !stopped else { return }
        request()
        timer = Task { [weak self, interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                self?.request()
            }
        }
    }

    @discardableResult
    func request() -> Task<Void, Never>? {
        guard !stopped, work == nil else { return work }
        work = Task { [self] in
            defer { work = nil; onChange?() }
            await run()
        }
        onChange?()
        return work
    }

    func stopForTermination() -> Task<Void, Never> {
        stopped = true
        timer?.cancel(); timer = nil
        work?.cancel()
        let pending = work
        return Task { await pending?.value }
    }

    private func save(_ report: String) throws {
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func run() async {
        var report = "", moved = 0, failed = 0, skipped = 0
        do {
            guard let policy = try RecordingCleanup.policy(in: config()) else {
                status = localised("Automatic cleanup is off.", "Автоматическая очистка выключена."); return
            }
            let instant = now(), folder = root().standardizedFileURL.resolvingSymlinksInPath()
            report = "\(instant.formatted())\n" + localised(
                "Cleanup: \(policy.mode.rawValue), age ≥ \(policy.days) days from recording start.\nRestore from Trash using Finder’s Put Back. Turn cleanup off before restoring. Space is freed only when you empty Trash.\n",
                "Очистка: \(policy.mode == .audio ? "только аудио" : "запись целиком"), возраст ≥ \(policy.days) дней от начала записи.\nПеред восстановлением выключите очистку. В Корзине Finder выберите «Вернуть на место». Место освободится после очистки Корзины.\n")
            try save(report)
            let dirs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                guard !stopped, operations.isAccepting,
                      try RecordingCleanup.policy(in: config()) == policy,
                      root().standardizedFileURL.resolvingSymlinksInPath() == folder else { break }
                let fm = FileManager.default
                guard fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else { continue }
                do {
                    guard try fm.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType == .typeDirectory,
                          try fm.attributesOfItem(atPath: dir.appendingPathComponent("meta.json").path)[.type] as? FileAttributeType == .typeRegular,
                          let meta = SessionState.read(dir), let started = RecordingCleanup.started(in: meta) else {
                        skipped += 1
                        report += localised("Skipped (unreadable date or unsafe path): ", "Пропущено (дата не читается или небезопасный путь): ") + dir.path + "\n"
                        try save(report); continue
                    }
                    guard instant.timeIntervalSince(started) >= Double(policy.days) * 86_400 else { continue }
                    let canonical = dir.standardizedFileURL.resolvingSymlinksInPath()
                    guard !busy(canonical), !operations.snapshot().contains(where: { $0.session?.path == canonical.path }),
                          !fm.fileExists(atPath: dir.appendingPathComponent(".recording.json").path),
                          !SessionClaim.isHeld(dir) else {
                        skipped += 1
                        report += localised("Skipped (busy or open): ", "Пропущено (занято или открыто): ") + dir.path + "\n"
                        try save(report); continue
                    }
                    try SessionClaim.acquire(dir, stage: .finish)
                    defer { SessionClaim.release(dir) }
                    let targets = try policy.mode == .recording ? [dir] : RecordingCleanup.audioFiles(in: dir, meta: meta)
                    for target in targets {
                        try Task.checkCancellation()
                        guard !stopped, !busy(canonical), operations.isAccepting,
                              !operations.snapshot().contains(where: { $0.session?.path == canonical.path }),
                              try RecordingCleanup.policy(in: config()) == policy,
                              root().standardizedFileURL.resolvingSymlinksInPath() == folder else { break }
                        guard try fm.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType == .typeDirectory,
                              try fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == (policy.mode == .recording ? .typeDirectory : .typeRegular) else {
                            throw CocoaError(.fileReadNoPermission)
                        }
                        // Persist intent before Finder runs: a crash leaves a useful recovery location.
                        try save(report + localised("Move requested; check Trash: ", "Запрошен перенос; проверьте Корзину: ") + target.path + "\n")
                        let (destination, error): (URL?, Error?) = await withCheckedContinuation { continuation in
                            recycle(target) { destination, error in continuation.resume(returning: (destination, error)) }
                        }
                        if let destination {
                            if policy.mode == .recording { SessionClaim.release(destination) }
                            moved += 1
                            report += localised("Moved: ", "Перемещено: ") + target.path + " → " + destination.path + "\n"
                        }
                        if let error {
                            failed += 1
                            report += localised("Failed: ", "Ошибка: ") + target.path + ": " + error.localizedDescription + "\n"
                        } else if destination == nil {
                            failed += 1
                            report += localised("No Trash destination returned: ", "Корзина не подтвердила перенос: ") + target.path + "\n"
                        }
                        try save(report)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failed += 1
                    report += localised("Failed: ", "Ошибка: ") + dir.path + ": " + error.localizedDescription + "\n"
                    try save(report)
                }
            }
            status = localised("Moved to Trash: \(moved). Failed: \(failed). Skipped: \(skipped).",
                               "В Корзине: \(moved). Ошибок: \(failed). Пропущено: \(skipped).")
            try save(report + "\n" + status)
        } catch is CancellationError {
            status = localised("Cleanup stopped. See the report for completed moves.", "Очистка остановлена. Выполненные переносы — в отчёте.")
        } catch {
            status = localised("Cleanup stopped: ", "Очистка остановлена: ") + error.localizedDescription
        }
    }
}
