import Foundation

struct TranscriptionRecord: Equatable {
    let timestamp: String
    let text: String
}

final class TranscriptionStore {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let dir = directory {
            self.directory = dir
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        }
    }

    func save(_ text: String, timestamp: Date = Date()) -> URL? {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestampStr = formatter.string(from: timestamp)
        let path = directory.appendingPathComponent("\(timestampStr).txt")
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    func loadRecent(limit: Int) -> [TranscriptionRecord] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { file -> TranscriptionRecord? in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                return TranscriptionRecord(timestamp: file.deletingPathExtension().lastPathComponent, text: text)
            }
    }

    func count() -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        return ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "txt" }.count) ?? 0
    }

    func delete(timestamp: String) -> Bool {
        let path = directory.appendingPathComponent("\(timestamp).txt")
        do {
            try fileManager.removeItem(at: path)
            return true
        } catch {
            return false
        }
    }
}
