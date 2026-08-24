//
//  EventModeViewModel.swift
//  Social
//
//  Modo Evento: dentro de un recinto, todos los asistentes se ven entre sí,
//  con ranking de socials del evento (tablas events/event_attendees, Fase 7).
//

import Foundation
import CoreLocation

@MainActor
final class EventModeViewModel: ObservableObject {

    struct EventInfo: Decodable {
        let id: UUID
        let name: String
        let venueLat: Double
        let venueLng: Double
        let radiusMeters: Int

        enum CodingKeys: String, CodingKey {
            case id, name
            case venueLat = "venue_lat"
            case venueLng = "venue_lng"
            case radiusMeters = "radius_meters"
        }
    }

    struct RankedAttendee: Identifiable {
        let id: UUID
        let displayName: String
        let socialCount: Int
    }

    @Published var activeEvent: EventInfo?
    @Published var ranking: [RankedAttendee] = []
    @Published var errorMessage: String?
    /// Se actualiza en loadRanking() a partir de la misma fila que ya trae
    /// el id de cada asistente — evita una consulta aparte solo para saber
    /// si el usuario actual ya está en event_attendees.
    @Published var hasJoined = false

    /// Comprueba si la ubicación actual cae dentro del radio de algún evento activo.
    func checkForNearbyEvent(location: CLLocation) async {
        do {
            let events: [EventInfo] = try await SupabaseManager.shared.client
                .from("events")
                .select()
                .lte("starts_at", value: ISO8601DateFormatter().string(from: Date()))
                .gte("ends_at", value: ISO8601DateFormatter().string(from: Date()))
                .execute()
                .value

            activeEvent = events.first { event in
                let venue = CLLocation(latitude: event.venueLat, longitude: event.venueLng)
                return location.distance(from: venue) <= Double(event.radiusMeters)
            }

            if let event = activeEvent {
                await loadRanking(eventID: event.id)
            } else if hasJoined {
                // Ya no hay ningún evento activo cerca — deja de contar como
                // actividad "dentro de un evento" para event_density() (ver
                // AnalyticsManager.currentEventID).
                AnalyticsManager.currentEventID = nil
                hasJoined = false
            }
        } catch {
            errorMessage = "No se pudo comprobar eventos cercanos."
        }
    }

    func joinEvent(eventID: UUID, userID: UUID) async {
        struct NewAttendee: Encodable {
            let event_id: UUID
            let profile_id: UUID
        }
        do {
            try await SupabaseManager.shared.client
                .from("event_attendees")
                .insert(NewAttendee(event_id: eventID, profile_id: userID))
                .execute()
            AnalyticsManager.track("event_joined", eventID: eventID)
            // A partir de aquí, tab_view/app_open cuentan como actividad
            // real dentro de este evento para event_density(), no solo el
            // propio join.
            AnalyticsManager.currentEventID = eventID
            await loadRanking(eventID: eventID)
        } catch {
            errorMessage = "No se pudo unir al evento."
        }
    }

    private func loadRanking(eventID: UUID) async {
        struct Row: Decodable {
            let socialCount: Int
            let profile: Profile

            enum CodingKeys: String, CodingKey {
                case socialCount = "social_count"
                case profile = "profiles"
            }
        }
        do {
            let rows: [Row] = try await SupabaseManager.shared.client
                .from("event_attendees")
                .select("social_count, profiles(*)")
                .eq("event_id", value: eventID)
                .order("social_count", ascending: false)
                .limit(50)
                .execute()
                .value
            ranking = rows.map { RankedAttendee(id: $0.profile.id, displayName: $0.profile.displayName, socialCount: $0.socialCount) }
            if let myID = try? await SupabaseManager.shared.client.auth.session.user.id {
                hasJoined = ranking.contains { $0.id == myID }
            }
        } catch {
            errorMessage = "No se pudo cargar el ranking del evento."
        }
    }
}
