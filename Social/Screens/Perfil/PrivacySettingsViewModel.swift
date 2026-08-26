//
//  PrivacySettingsViewModel.swift
//  Social
//
//  Hallazgo real: `compat_public`/`location_public` se consultaban en
//  varios sitios (Match/Home para el % de compatibilidad sin solicitarla,
//  "Find" para el mapa de ubicaciones públicas) pero no había NINGÚN
//  interruptor para activarlos en ninguna plataforma — se quedaban
//  bloqueados en `false` para siempre. `profiles_update_own`
//  (0002_rls.sql) ya permite editar cualquier columna del propio perfil,
//  solo faltaba la UI. Equivalente de PrivacySettingsViewModel.kt.
//

import Foundation
import CoreLocation

/// Hallazgo real, encontrado auditando "Find" (FindLocationsViewModel.swift):
/// `last_lat`/`last_lng` existen en 0001_schema.sql desde el principio y
/// "Find" ya las lee correctamente cuando `location_public = true`, pero
/// NADA en toda la app las escribía nunca — ni aquí, ni en la cámara, ni en
/// Modo Evento (que solo lee ubicación, no la publica). El interruptor
/// llevaba pasadas enteras "funcionando" (guardaba el booleano) sin que
/// "Find" pudiera mostrar jamás una sola ubicación real. Mismo hallazgo y
/// mismo fix que PrivacySettingsViewModel.kt.publishCurrentLocation.
private final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func fetch() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.last)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

@MainActor
final class PrivacySettingsViewModel: ObservableObject {
    @Published var compatPublic = false
    @Published var locationPublic = false
    // Hallazgo real, comparado con Instagram/Twitter/Facebook/WhatsApp:
    // todas dejan silenciar "me gusta" sin silenciar "mensajes" -- esta
    // app solo tenía silenciar un CHAT completo (0047_message_notify_mute.sql),
    // nunca una CATEGORÍA de aviso en toda la app. Aplicado de verdad en
    // el servidor (send-push/index.ts, 0052_notification_prefs.sql), no
    // solo en el cliente.
    @Published var mutedKinds: Set<String> = []
    // Palabras silenciadas reales en comentarios (0078_muted_keywords.sql),
    // comparado con Instagram/Twitter -- oculta automáticamente cualquier
    // comentario propio (post o reel) que contenga una de estas palabras,
    // sin bloquear a nadie: el comentario sigue existiendo de verdad para
    // todos los demás, incluido quien lo escribió. Equivalente de
    // PrivacySettingsViewModel.kt.mutedKeywords.
    @Published var mutedKeywords: [String] = []
    @Published var errorMessage: String?

    private struct PrivacyRow: Decodable {
        let compat_public: Bool
        let location_public: Bool
        let muted_push_kinds: [String]
        let muted_keywords: [String]
    }

    func load() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let row: PrivacyRow = try await SupabaseManager.shared.client
                .from("profiles")
                .select("compat_public,location_public,muted_push_kinds,muted_keywords")
                .eq("id", value: userID)
                .single()
                .execute()
                .value
            compatPublic = row.compat_public
            locationPublic = row.location_public
            mutedKinds = Set(row.muted_push_kinds)
            mutedKeywords = row.muted_keywords
        } catch {
            errorMessage = "No se pudo cargar la privacidad."
        }
    }

    func addMutedKeyword(_ word: String) {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !mutedKeywords.contains(normalized) else { return }
        let previous = mutedKeywords
        mutedKeywords.append(normalized)
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            struct KeywordsUpdate: Encodable { let muted_keywords: [String] }
            do {
                try await SupabaseManager.shared.client
                    .from("profiles")
                    .update(KeywordsUpdate(muted_keywords: mutedKeywords))
                    .eq("id", value: userID)
                    .execute()
            } catch {
                errorMessage = "No se pudo guardar la palabra silenciada."
                mutedKeywords = previous
            }
        }
    }

    func removeMutedKeyword(_ word: String) {
        let previous = mutedKeywords
        mutedKeywords.removeAll { $0 == word }
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            struct KeywordsUpdate: Encodable { let muted_keywords: [String] }
            do {
                try await SupabaseManager.shared.client
                    .from("profiles")
                    .update(KeywordsUpdate(muted_keywords: mutedKeywords))
                    .eq("id", value: userID)
                    .execute()
            } catch {
                errorMessage = "No se pudo quitar la palabra silenciada."
                mutedKeywords = previous
            }
        }
    }

    /// [kinds] son los valores reales de `notifications.kind` que agrupa
    /// una categoría visible en Ajustes -- ver AjustesView.swift para el
    /// mapeo completo. Equivalente de PrivacySettingsViewModel.kt.setCategoryMuted().
    func setCategoryMuted(_ kinds: [String], muted: Bool) {
        let previous = mutedKinds
        if muted {
            mutedKinds.formUnion(kinds)
        } else {
            mutedKinds.subtract(kinds)
        }
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            struct MutedUpdate: Encodable { let muted_push_kinds: [String] }
            do {
                try await SupabaseManager.shared.client
                    .from("profiles")
                    .update(MutedUpdate(muted_push_kinds: Array(mutedKinds)))
                    .eq("id", value: userID)
                    .execute()
            } catch {
                errorMessage = "No se pudo guardar el cambio."
                mutedKinds = previous
            }
        }
    }

    func setCompatPublic(_ value: Bool) {
        let previous = compatPublic
        compatPublic = value
        Task {
            if !(await updateColumn(["compat_public": value])) { compatPublic = previous }
        }
    }

    func setLocationPublic(_ value: Bool) {
        let previous = locationPublic
        locationPublic = value
        Task {
            if !(await updateColumn(["location_public": value])) {
                locationPublic = previous
            } else if value {
                // Se publica una vez, en el momento de activar el
                // interruptor — no es un rastreo en segundo plano continuo
                // (decisión de alcance, no un descuido: eso requeriría un
                // CLLocationManager de larga duración con permiso "Always",
                // fuera de esta corrección).
                await publishCurrentLocation()
            }
        }
    }

    private func publishCurrentLocation() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        guard let location = await OneShotLocationFetcher().fetch() else { return }
        struct LocationUpdate: Encodable {
            let last_lat: Double
            let last_lng: Double
        }
        do {
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(LocationUpdate(last_lat: location.coordinate.latitude, last_lng: location.coordinate.longitude))
                .eq("id", value: userID)
                .execute()
        } catch {
            // No crítico: el interruptor ya se guardó, solo falló la
            // primera publicación de coordenadas.
        }
    }

    private func updateColumn(_ values: [String: Bool]) async -> Bool {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return false }
        do {
            try await SupabaseManager.shared.client
                .from("profiles")
                .update(values)
                .eq("id", value: userID)
                .execute()
            return true
        } catch {
            errorMessage = "No se pudo guardar el cambio."
            return false
        }
    }
}
