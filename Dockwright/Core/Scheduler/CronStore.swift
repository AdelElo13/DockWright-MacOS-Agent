import Foundation
import os

/// Thread-safe JSON persistence for cron jobs at ~/.dockwright/cron_jobs.json
final class CronStore: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.Aatje.Dockwright", category: "CronStore")
    private let queue = DispatchQueue(label: "com.Aatje.Dockwright.CronStore", qos: .utility)
    private var jobs: [String: CronJob] = [:]
    private let fileURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dockwright", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.fileURL = dir.appendingPathComponent("cron_jobs.json")
        loadFromDisk()
    }

    // MARK: - CRUD

    func add(_ job: CronJob) {
        queue.sync {
            jobs[job.id] = job
            saveToDisk()
        }
        logger.info("Job added: \(job.name) (\(job.id))")
    }

    func update(_ job: CronJob) {
        queue.sync {
            jobs[job.id] = job
            saveToDisk()
        }
    }

    func remove(_ id: String) -> Bool {
        var removed = false
        queue.sync {
            if jobs.removeValue(forKey: id) != nil {
                removed = true
                saveToDisk()
            }
        }
        if removed {
            logger.info("Job removed: \(id)")
        }
        return removed
    }

    func get(_ id: String) -> CronJob? {
        queue.sync { jobs[id] }
    }

    func listAll() -> [CronJob] {
        queue.sync { Array(jobs.values).sorted { $0.createdAt < $1.createdAt } }
    }

    func enabledJobs() -> [CronJob] {
        queue.sync { jobs.values.filter(\.enabled).sorted { $0.createdAt < $1.createdAt } }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger.info("No cron_jobs.json found, starting fresh.")
                return
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder.dockwright.decode([CronJob].self, from: data)
                jobs = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
                logger.info("Loaded \(decoded.count) cron jobs from disk.")
            } catch {
                logger.error("Corrupt cron_jobs.json: \(error.localizedDescription). Backing up and starting fresh.")
                let backupURL = fileURL.deletingPathExtension()
                    .appendingPathExtension("corrupt.\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: backupURL)
                jobs = [:]
            }
        }
    }

    private func saveToDisk() {
        // Called from within queue.sync, so already serialized
        do {
            let encoder = JSONEncoder.dockwright
            let data = try encoder.encode(Array(jobs.values))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save cron_jobs.json: \(error.localizedDescription)")
        }
    }
}

// MARK: - JSON Encoder/Decoder helpers

private extension JSONEncoder {
    static let dockwright: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let dockwright: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
