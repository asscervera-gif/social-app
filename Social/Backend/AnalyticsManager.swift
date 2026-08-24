//
//  AnalyticsManager.swift
//  Social
//
//  Analítica mínima auto-alojada en la propia tabla Supabase del proyecto
//  — equivalente a AnalyticsManager.kt (Android). Deliberadamente NO se
//  integra un SDK de terceros (Firebase Analytics, Mixpanel, etc.): la
//  tabla `analytics_events` (0005_analytics.sql) y la función
//  `event_density()` ya cubren la única métrica que growth_strategy.md
//  identifica como la que de verdad importa para un producto con umbral
//  físico — densidad efectiva por evento — sin añadir una dependencia de
//  pago ni un tracker de comportamiento genérico.
//
//  Fire-and-forget deliberado: un fallo de red al registrar un evento
//  nunca debe afectar a la funcionalidad real de la app.
//

import Foundation

enum AnalyticsManager {

    /// Hallazgo real: `event_density()` (0005_analytics.sql) cuenta actividad
    /// reciente filtrando `analytics_events` por `event_id`, pero `tab_view`/
    /// `app_open` — los únicos eventos que se disparan repetidamente mientras
    /// alguien sigue usando la app — nunca llevaban `event_id`. Solo
    /// `event_joined` lo llevaba, una vez. Corregido con este holder en
    /// memoria (mismo patrón que Android): `EventModeViewModel.joinEvent()`
    /// lo fija tras un `event_joined` real, y `track()` lo usa
    /// automáticamente como `event_id` para cualquier llamada que no pase
    /// uno explícito.
    static var currentEventID: UUID?

    private struct NewEvent: Encodable {
        let profile_id: UUID?
        let event_type: String
        let event_id: UUID?
    }

    static func track(_ eventType: String, eventID: UUID? = nil) {
        Task {
            do {
                let profileID = try? await SupabaseManager.shared.client.auth.session.user.id
                try await SupabaseManager.shared.client
                    .from("analytics_events")
                    .insert(NewEvent(profile_id: profileID, event_type: eventType, event_id: eventID ?? currentEventID))
                    .execute()
            } catch {
                // Ver comentario de arriba: nunca debe romper la app.
            }
        }
    }
}
