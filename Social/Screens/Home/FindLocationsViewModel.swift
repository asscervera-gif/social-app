//
//  FindLocationsViewModel.swift
//  Social
//
//  "Find" — hallazgo real: era un texto de relleno ("Find: mapa de
//  ubicaciones públicas", un `.sheet` con un `Text` fijo, nunca un mapa
//  real) desde el principio de esta sesión. Ahora que `location_public`
//  tiene un interruptor real (ver PrivacySettingsViewModel.swift), tiene
//  sentido construir el mapa de verdad. `profiles_select_public`
//  (0002_rls.sql) ya expone `last_lat`/`last_lng` solo cuando
//  `location_public = true`. Equivalente de FindLocationsViewModel.kt.
//

import Foundation
import CoreLocation

struct PublicLocation: Identifiable {
    let id: UUID
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let avatarConfig: [String: String]?
}

@MainActor
final class FindLocationsViewModel: ObservableObject {
    @Published var locations: [PublicLocation] = []
    @Published var errorMessage: String?

    private struct LocationRow: Decodable {
        let id: UUID
        let display_name: String
        let last_lat: Double?
        let last_lng: Double?
        let avatar_config: [String: String]?
    }

    private struct BlockRow: Decodable { let blocked_id: UUID }

    func load() async {
        do {
            let client = SupabaseManager.shared.client
            let myID = try? await client.auth.session.user.id

            var blockedIDs: Set<UUID> = []
            if let blockRows: [BlockRow] = try? await client.from("blocks").select().execute().value {
                blockedIDs = Set(blockRows.map { $0.blocked_id })
            }

            // Mismo hallazgo real ya corregido en SearchViewModel.swift y
            // en la versión Kotlin equivalente de este archivo: sin este
            // filtro, el modo invisible no protegía la ubicación exacta
            // en el mapa — un hueco más grave que en el buscador, porque
            // aquí se filtran coordenadas reales, no solo el nombre.
            var query = client.from("profiles").select()
                .eq("location_public", value: true)
                .eq("is_invisible", value: false)
            if let myID {
                query = query.neq("id", value: myID)
            }
            let rows: [LocationRow] = try await query.limit(50).execute().value

            // location_public=true no garantiza que last_lat/last_lng
            // tengan un valor real — se filtran en cliente.
            locations = rows
                .filter { !blockedIDs.contains($0.id) }
                .compactMap { row in
                    guard let lat = row.last_lat, let lng = row.last_lng else { return nil }
                    return PublicLocation(id: row.id, displayName: row.display_name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), avatarConfig: row.avatar_config)
                }
        } catch {
            errorMessage = "No se pudieron cargar las ubicaciones."
        }
    }
}
