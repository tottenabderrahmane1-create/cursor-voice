import Foundation

/// Persistent memory for the assistant. Stored as a JSON array at
/// ~/Library/Application Support/CursorVoice/memory.json. The model
/// writes facts via the `remember` tool and reads them via `recall`.
/// At session start, all current memories are appended to the system
/// instructions so the model knows what it already knows.
final class MemoryStore {
    static let shared = MemoryStore()

    private let url: URL
    private let queue = DispatchQueue(label: "CursorVoice.MemoryStore")
    private var items: [Item] = []

    struct Item: Codable, Equatable {
        let content: String
        let timestamp: TimeInterval
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("CursorVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("memory.json")
        load()
    }

    func remember(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            // Dedup case-insensitive; refresh timestamp instead of duplicating.
            if let idx = items.firstIndex(where: { $0.content.lowercased() == trimmed.lowercased() }) {
                items.remove(at: idx)
            }
            items.append(Item(content: trimmed, timestamp: Date().timeIntervalSince1970))
            // Cap to last 200 items to keep the file reasonable.
            if items.count > 200 {
                items.removeFirst(items.count - 200)
            }
            save()
        }
    }

    func recall(matching query: String?) -> [Item] {
        queue.sync {
            guard let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty else {
                return items
            }
            return items.filter { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    func all() -> [Item] {
        queue.sync { items }
    }

    func forget(matching query: String) -> Int {
        queue.sync {
            let before = items.count
            items.removeAll { $0.content.localizedCaseInsensitiveContains(query) }
            save()
            return before - items.count
        }
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = arr
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
