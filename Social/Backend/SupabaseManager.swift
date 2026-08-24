//
//  SupabaseManager.swift
//  Social
//
//  Punto único de acceso al backend: auth, base de datos Postgres, storage
//  y realtime. Requiere añadir el paquete Swift `supabase-community/supabase-swift`
//  desde Xcode (File → Add Package Dependencies) antes de compilar este archivo.
//
//  Las credenciales NO se escriben en código: se leen de Config.plist
//  (añádelo al proyecto y a .gitignore, nunca lo subas a git).
//

import Foundation
import Supabase

final class SupabaseManager {

    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        guard
            let url = URL(string: Self.readConfig("SUPABASE_URL")),
            let key = Self.readConfig("SUPABASE_ANON_KEY") as String?
        else {
            fatalError("Faltan SUPABASE_URL o SUPABASE_ANON_KEY en Config.plist")
        }

        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
    }

    /// Lee un valor de Config.plist (no versionado). Ver Config.example.plist
    /// para el formato esperado.
    private static func readConfig(_ key: String) -> String {
        guard
            let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
            let value = dict[key]
        else {
            fatalError("No se pudo leer '\(key)' de Config.plist. Copia Config.example.plist y rellena tus credenciales de Supabase.")
        }
        return value
    }
}
