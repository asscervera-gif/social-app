//
//  LiveStreamsViewModel.swift
//  Social
//
//  "Directo" real por primera vez, comparado con Instagram/TikTok Live --
//  el último hueco grande identificado leyendo SOCIAL_APP.html. Backend ya
//  construido y verificado en la ronda anterior (0056_live_streams.sql,
//  115/115 tests locales). Motor real: LiveKit (elegido explícitamente por
//  el usuario, Cloud frente a self-hosted). Equivalente de
//  LiveStreamsViewModel.kt.
//
//  El token real de conexión se pide a `live-token` (Edge Function, ver
//  supabase/functions/live-token/index.ts) -- nunca se construye en el
//  cliente, eso requeriría el secreto de LiveKit.
//

import Foundation

struct LiveStream: Codable, Identifiable {
    let id: UUID
    let hostID: UUID
    var title: String?
    var roomName: String
    var isSocialOnly: Bool
    var status: String
    var viewerCount: Int
    var startedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case title
        case roomName = "room_name"
        case isSocialOnly = "is_social_only"
        case status
        case viewerCount = "viewer_count"
        case startedAt = "started_at"
    }
}

struct LiveKitTokenResponse: Decodable {
    let token: String
    let wsUrl: String
    let roomName: String
}

@MainActor
final class LiveStreamsViewModel: ObservableObject {

    @Published var streams: [LiveStream] = []
    @Published var hostProfiles: [UUID: Profile] = [:]
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: [LiveStream] = try await SupabaseManager.shared.client
                .from("live_streams")
                .select()
                .eq("status", value: "live")
                .order("started_at", ascending: false)
                .execute()
                .value
            streams = loaded

            let hostIDs = Array(Set(loaded.map { $0.hostID }))
            if !hostIDs.isEmpty,
               let hosts: [Profile] = try? await SupabaseManager.shared.client
                   .from("profiles")
                   .select()
                   .in("id", values: hostIDs)
                   .execute()
                   .value {
                hostProfiles = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
            }
        } catch {
            errorMessage = "No se pudieron cargar los directos: \(error.localizedDescription)"
        }
    }

    /// Empieza un directo real: inserta la fila (RLS `live_streams_insert_own`,
    /// 0056_live_streams.sql) -- el token de publicar se pide aparte con
    /// `requestHostToken` una vez la fila ya existe de verdad.
    func startStream(title: String, isSocialOnly: Bool) async -> LiveStream? {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return nil }
        struct NewLiveStream: Encodable {
            let host_id: UUID
            let title: String?
            let is_social_only: Bool
        }
        do {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let inserted: LiveStream = try await SupabaseManager.shared.client
                .from("live_streams")
                .insert(NewLiveStream(host_id: userID, title: trimmed.isEmpty ? nil : trimmed, is_social_only: isSocialOnly))
                .select()
                .single()
                .execute()
                .value
            return inserted
        } catch {
            errorMessage = "No se pudo empezar el directo."
            return nil
        }
    }

    /// Termina el propio directo real -- solo el host puede (RLS
    /// `live_streams_update_own`). `viewer_count` está protegido por
    /// `trg_protect_live_stream_viewer_count`, no se toca aquí.
    func endStream(_ stream: LiveStream) async {
        struct EndUpdate: Encodable {
            let status = "ended"
            let ended_at: String
        }
        do {
            try await SupabaseManager.shared.client
                .from("live_streams")
                .update(EndUpdate(ended_at: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: stream.id)
                .execute()
        } catch {
            errorMessage = "No se pudo terminar el directo."
        }
    }

    /// Se une como espectador real (RLS `live_stream_viewers_insert_own`,
    /// comprueba bloqueo contra el host) y pide el token real de LiveKit.
    func joinAndGetToken(_ stream: LiveStream) async -> LiveKitTokenResponse? {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return nil }
        if stream.hostID != userID {
            struct NewViewer: Encodable {
                let stream_id: UUID
                let viewer_id: UUID
            }
            // Restricción unique(stream_id, viewer_id): si ya estaba unido
            // (p.ej. tras reconectar), no es un error real -- mismo
            // criterio que HomeViewModel.toggleLike().
            try? await SupabaseManager.shared.client
                .from("live_stream_viewers")
                .insert(NewViewer(stream_id: stream.id, viewer_id: userID))
                .execute()
        }
        return await requestToken(streamID: stream.id)
    }

    /// Pide el token de PUBLICAR para el propio host -- misma función, la
    /// Edge Function decide `canPublish` comparando `host_id` con el
    /// usuario real, nunca a partir de lo que mande este cliente.
    func requestHostToken(_ stream: LiveStream) async -> LiveKitTokenResponse? {
        await requestToken(streamID: stream.id)
    }

    struct LiveViewerEntry: Identifiable {
        let id: UUID
        let displayName: String?
        let avatarConfig: [String: String]?
    }

    private struct ViewerRow: Decodable { let viewer_id: UUID }
    private struct NameRow: Decodable {
        let id: UUID
        let display_name: String
        let avatar_config: [String: String]?
    }

    /// Lista real de quién está viendo el directo AHORA MISMO, comparado
    /// con Instagram/TikTok Live -- `live_stream_viewers`
    /// (0056_live_streams.sql) ya existía de verdad (sincroniza
    /// `viewer_count` real, RLS ya limitaba la lista completa al propio
    /// host), pero ningún cliente la consultaba nunca -- el número se
    /// veía, la lista real detrás nunca. Equivalente de
    /// LiveStreamsViewModel.kt.fetchViewers().
    func fetchViewers(_ streamID: UUID) async -> [LiveViewerEntry] {
        guard let viewerRows: [ViewerRow] = try? await SupabaseManager.shared.client
            .from("live_stream_viewers")
            .select("viewer_id")
            .eq("stream_id", value: streamID)
            .execute()
            .value else { return [] }
        let viewerIDs = viewerRows.map { $0.viewer_id }
        guard !viewerIDs.isEmpty else { return [] }
        guard let profiles: [NameRow] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id,display_name,avatar_config")
            .in("id", values: viewerIDs)
            .execute()
            .value else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return viewerIDs.compactMap { id in
            byID[id].map { LiveViewerEntry(id: id, displayName: $0.display_name, avatarConfig: $0.avatar_config) }
        }
    }

    private func requestToken(streamID: UUID) async -> LiveKitTokenResponse? {
        struct TokenRequest: Encodable {
            let streamId: UUID
        }
        do {
            let response: LiveKitTokenResponse = try await SupabaseManager.shared.client.functions
                .invoke("live-token", options: .init(body: TokenRequest(streamId: streamID)))
            return response
        } catch {
            errorMessage = "No se pudo conectar al directo."
            return nil
        }
    }

    /// Sale de un directo ajeno real -- borra la propia fila (RLS
    /// `live_stream_viewers_delete_own`); baja `viewer_count` el trigger
    /// real, no este código.
    func leaveStream(_ stream: LiveStream) async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        try? await SupabaseManager.shared.client
            .from("live_stream_viewers")
            .delete()
            .eq("stream_id", value: stream.id)
            .eq("viewer_id", value: userID)
            .execute()
    }
}
