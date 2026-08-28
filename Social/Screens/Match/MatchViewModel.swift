//
//  MatchViewModel.swift
//  Social
//
//  Cuadrícula de perfiles con compatibilidad pública o solicitable.
//

import Foundation
import CoreLocation

/// Fetch de ubicación de una sola vez, para el filtro real "Cerca" del
/// boceto — mismo patrón que OneShotLocationFetcher en
/// PrivacySettingsViewModel.swift (duplicado a propósito: son dos usos
/// independientes, sin estado compartido entre ellos).
private final class MatchLocationFetcher: NSObject, CLLocationManagerDelegate {
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
final class MatchViewModel: ObservableObject {

    struct Entry: Identifiable {
        var id: UUID { profile.id }
        let profile: Profile
        /// nil = compat no visible todavía (se muestra "?%" y botón de solicitar).
        var compatibility: Int?
        var requestSent: Bool
    }

    @Published var entries: [Entry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Expuesto para el filtro real "Tus gustos" del boceto (ver
    // MatchView.swift) — antes se calculaba dentro de load() y se tiraba
    // después de usarlo solo para estimatedCompatibility().
    @Published var myInterests: Set<String> = []
    @Published var myLocation: CLLocation?

    /// Sin permiso concedido todavía, simplemente no reordena por "Cerca"
    /// — el resto de la pantalla sigue funcionando (mismo criterio que
    /// PrivacySettingsViewModel.swift.publishCurrentLocation).
    func fetchMyLocation() async {
        myLocation = await MatchLocationFetcher().fetch()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let client = SupabaseManager.shared.client
            let userID = try? await client.auth.session.user.id

            // Hallazgo real: a quien bloqueas seguía apareciendo en Match —
            // el fix de invisible/self-exclusión de abajo nunca cubrió
            // bloqueados. Solo se puede filtrar "a quién he bloqueado yo"
            // (RLS de `blocks` no deja ver quién me bloqueó a mí — límite de
            // privacidad correcto, no un hueco a rellenar).
            struct BlockRow: Decodable { let blocked_id: UUID }
            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await client.from("blocks").select().execute().value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            // Antes se traían TODOS los perfiles, incluyendo a quien tiene el
            // modo invisible activo y al propio usuario — modo invisible es un
            // principio de producto "no negociable" (ver SocialCameraView.swift),
            // así que ignorarlo aquí era un fallo de privacidad real.
            //
            // Aviso de honestidad: encadenar var query = ... .eq(...) y luego
            // reasignar query = query.neq(...) antes de .limit() asume que
            // PostgrestFilterBuilder de supabase-swift permite este patrón de
            // reasignación fluida — no lo he podido verificar con compilador
            // real (solo disponible para Android en este entorno). El
            // equivalente Kotlin en MatchViewModel.kt SÍ está verificado (usa
            // el bloque `filter { }` en vez de encadenar, y compila limpio).
            // Si Xcode señala esta línea, es el único ajuste necesario.
            var query = client.from("profiles").select().eq("is_invisible", value: false)
            if let userID {
                query = query.neq("id", value: userID)
            }
            let allProfiles: [Profile] = try await query
                .limit(60)
                .execute()
                .value
            let profiles = allProfiles.filter { !blockedIDs.contains($0.id) }

            let myInterests: Set<String>
            if let userID,
               let me: Profile = try? await client.from("profiles").select().eq("id", value: userID).single().execute().value {
                myInterests = Set(me.interests)
            } else {
                myInterests = []
            }
            self.myInterests = myInterests

            entries = profiles.map { profile in
                Entry(profile: profile, compatibility: estimatedCompatibility(with: profile, myInterests: myInterests), requestSent: false)
            }
        } catch {
            errorMessage = "No se pudo cargar Match: \(error.localizedDescription)"
        }
    }

    /// Estimación heurística de compatibilidad por solapamiento de intereses
    /// (índice de Jaccard). No hay ninguna otra fuente de "% de compatibilidad
    /// con un desconocido" en el esquema: `chats.compatibility_score` existe
    /// solo una vez hay un chat, y ese valor evoluciona por interacción
    /// (votos/duelos), no sirve para el descubrimiento inicial en Match.
    /// Sustituir por un algoritmo real (embeddings, respuestas de perfil
    /// completo, etc.) es trabajo de producto/datos, no una corrección de
    /// bug — esto deja el campo funcionando de verdad en vez de siempre nil.
    private func estimatedCompatibility(with profile: Profile, myInterests: Set<String>) -> Int? {
        guard profile.compatPublic else { return nil }
        let theirInterests = Set(profile.interests)
        guard !myInterests.isEmpty, !theirInterests.isEmpty else { return nil }
        let intersection = myInterests.intersection(theirInterests).count
        let union = myInterests.union(theirInterests).count
        guard union > 0 else { return nil }
        return Int((Double(intersection) / Double(union)) * 100)
    }

    /// Crea una fila en compat_requests (Fase 2) para pedir ver el % de un
    /// perfil no público. [highlighted] real, comparado con Tinder/Bumble
    /// (Super Like) -- ver 0136_compat_request_highlight.sql. Límite real
    /// de una destacada al día reforzado por un índice único parcial en
    /// el propio servidor (`idx_compat_requests_highlighted_daily`); un
    /// segundo intento el mismo día real revierte el estado optimista y
    /// muestra el error real en vez de fingir que se destacó. Equivalente
    /// de MatchViewModel.kt.requestCompatibility(highlighted:).
    func requestCompatibility(for entry: Entry, highlighted: Bool = false) async {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].requestSent = true

        struct NewRequest: Encodable {
            let requester_id: UUID
            let target_id: UUID
            let highlighted: Bool
        }

        do {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            try await SupabaseManager.shared.client
                .from("compat_requests")
                .insert(NewRequest(requester_id: userID, target_id: entry.profile.id, highlighted: highlighted))
                .execute()
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: pedir ver la compatibilidad de alguien
            // tampoco se registraba.
            AnalyticsManager.track(highlighted ? "compat_request_highlighted" : "compat_request_sent")
        } catch {
            if highlighted {
                entries[index].requestSent = false
                errorMessage = "Ya has destacado una solicitud hoy."
            } else {
                errorMessage = "No se pudo enviar la solicitud de compatibilidad."
            }
        }
    }
}
