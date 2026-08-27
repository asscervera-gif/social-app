//
//  RecentSearchesPreference.swift
//  Social
//
//  Búsquedas recientes reales, comparado con Instagram/Twitter/TikTok --
//  las tres muestran una lista de búsquedas anteriores en cuanto se toca
//  el buscador vacío, con un toque para repetirla y una forma real de
//  borrarlas. SearchView.swift/SearchViewModel.swift nunca recordaban
//  nada entre sesiones. Sin columna/tabla nueva -- puramente local,
//  `UserDefaults` (mismo criterio ya usado en AccentPreference,
//  Theme.swift). Equivalente de RecentSearchesPreference.kt.
//

import Foundation

final class RecentSearchesPreference: ObservableObject {
    static let shared = RecentSearchesPreference()

    private let key = "recent_searches"
    private let maxEntries = 10

    @Published private(set) var recent: [String]

    private init() {
        recent = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Guarda una búsqueda real ya ejecutada -- más reciente primero, sin
    /// duplicados (una repetida sube al principio en vez de aparecer dos
    /// veces), tope de `maxEntries` mismo criterio de no dejar crecer la
    /// lista sin límite.
    func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = ([trimmed] + recent.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }).prefix(maxEntries)
        recent = Array(updated)
        UserDefaults.standard.set(recent, forKey: key)
    }

    func clear() {
        recent = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
