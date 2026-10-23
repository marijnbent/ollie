import Foundation
import Observation

enum SnippetStoreError: LocalizedError {
    case unreadableHistory
    case emptyTrigger
    case invalidTriggerCharacters
    case emptyContent
    case duplicateTrigger

    var errorDescription: String? {
        switch self {
        case .unreadableHistory: return "Saved snippets could not be read."
        case .emptyTrigger:
            return "Enter a trigger."
        case .invalidTriggerCharacters:
            return "Use letters and numbers only."
        case .emptyContent:
            return "Enter text to insert."
        case .duplicateTrigger:
            return "That trigger already exists."
        }
    }
}

@MainActor
@Observable
final class SnippetStore {

    private(set) var snippets: [Snippet] = []

    private(set) var persistenceError: String?
    @ObservationIgnored private let defaults: UserDefaults
    private var isWritable = true
    private let snippetsKey = "savedSnippets"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func saveSnippet(id: UUID? = nil, title: String, trigger: String, content: String) throws {
        guard isWritable else { throw SnippetStoreError.unreadableHistory }
        let normalizedTrigger = Snippet.normalizeTrigger(trigger)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingSnippet = id.flatMap { snippetID in
            snippets.first(where: { $0.id == snippetID })
        }

        guard !normalizedTrigger.isEmpty else { throw SnippetStoreError.emptyTrigger }
        guard Snippet.isSupportedTriggerInput(trigger) else { throw SnippetStoreError.invalidTriggerCharacters }
        guard !trimmedContent.isEmpty else { throw SnippetStoreError.emptyContent }
        guard !snippets.contains(where: { $0.trigger == normalizedTrigger && $0.id != id }) else {
            throw SnippetStoreError.duplicateTrigger
        }

        let snippet = Snippet(
            id: id ?? UUID(),
            title: title,
            trigger: normalizedTrigger,
            content: content,
            usageCount: existingSnippet?.usageCount ?? 0,
            lastUsedAt: existingSnippet?.lastUsedAt
        )

        if let existingIndex = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[existingIndex] = snippet
        } else {
            snippets.append(snippet)
        }

        sortSnippets()

        persist()
    }

    func deleteSnippet(id: UUID) {
        guard isWritable else { return }
        snippets.removeAll { $0.id == id }
        persist()
    }

    func exactTriggerMatch(for query: String) -> Snippet? {
        let normalizedQuery = Snippet.normalizeTrigger(query)
        guard !normalizedQuery.isEmpty else { return nil }

        return snippets.first { $0.trigger == normalizedQuery }
    }

    func matches(for query: String) -> [Snippet] {
        let normalizedQuery = Snippet.normalizeTrigger(query)
        return snippets
            .filter { snippet in
                guard !normalizedQuery.isEmpty else { return true }
                return snippet.trigger.contains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                let lhsPriority = matchPriority(for: lhs, normalizedQuery: normalizedQuery)
                let rhsPriority = matchPriority(for: rhs, normalizedQuery: normalizedQuery)

                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }

                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }

                let lhsLastUsedAt = lhs.lastUsedAt ?? .distantPast
                let rhsLastUsedAt = rhs.lastUsedAt ?? .distantPast
                if lhsLastUsedAt != rhsLastUsedAt {
                    return lhsLastUsedAt > rhsLastUsedAt
                }

                if lhs.trigger.count != rhs.trigger.count {
                    return lhs.trigger.count < rhs.trigger.count
                }

                return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
            }
    }

    func recordUsage(for snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }

        snippets[index].usageCount += 1
        snippets[index].lastUsedAt = Date()
        persist()
    }

    func load() {
        isWritable = true
        persistenceError = nil
        guard let data = defaults.data(forKey: snippetsKey) else { return }

        do {
            snippets = try JSONDecoder().decode([Snippet].self, from: data)
            sortSnippets()
        } catch {
            isWritable = false
            persistenceError = "Could not load saved snippets."
        }
    }

    private func persist() {
        guard isWritable else { return }
        do {
            defaults.set(try JSONEncoder().encode(snippets), forKey: snippetsKey)
            persistenceError = nil
        } catch { persistenceError = "Could not save snippets." }
    }

    private func sortSnippets() {
        snippets.sort { lhs, rhs in
            if lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedSame {
                return lhs.trigger < rhs.trigger
            }
            return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
        }
    }

    private func matchPriority(for snippet: Snippet, normalizedQuery: String) -> Int {
        guard !normalizedQuery.isEmpty else { return 0 }

        if snippet.trigger == normalizedQuery {
            return 3
        }

        if snippet.trigger.hasPrefix(normalizedQuery) {
            return 2
        }

        if snippet.trigger.contains(normalizedQuery) {
            return 1
        }

        return -1
    }
}
