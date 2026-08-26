//
//  LiveStreamChatViewModel.swift
//  Social
//
//  Chat en vivo real durante un directo, comparado con Instagram/TikTok
//  Live -- ver 0059_live_stream_messages.sql para el hallazgo completo (el
//  vídeo ya existía desde la ronda anterior, pero nadie podía escribir
//  mientras lo veía). Mismo mecanismo de Realtime ya usado en
//  ChatViewModel.swift/GroupChatViewModel.swift. Equivalente de
//  LiveStreamChatViewModel.kt.
//

import Foundation
import Supabase

struct LiveStreamMessage: Codable, Identifiable {
    let id: UUID
    let streamID: UUID
    let senderID: UUID
    var body: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case streamID = "stream_id"
        case senderID = "sender_id"
        case body
        case createdAt = "created_at"
    }
}

@MainActor
final class LiveStreamChatViewModel: ObservableObject {
    let streamID: UUID

    @Published var messages: [LiveStreamMessage] = []
    @Published var senderNames: [UUID: String] = [:]

    private var channel: RealtimeChannelV2?

    init(streamID: UUID) {
        self.streamID = streamID
    }

    func load() async {
        do {
            messages = try await SupabaseManager.shared.client
                .from("live_stream_messages")
                .select()
                .eq("stream_id", value: streamID)
                .order("created_at", ascending: true)
                .limit(200)
                .execute()
                .value
            await resolveSenderNames(messages.map { $0.senderID })
        } catch {
            // El chat no es crítico para ver el vídeo -- si falla la
            // carga, el directo sigue reproduciéndose con normalidad.
        }
        await subscribeToRealtime()
    }

    private func resolveSenderNames(_ senderIDs: [UUID]) async {
        let missing = Array(Set(senderIDs)).filter { senderNames[$0] == nil }
        guard !missing.isEmpty else { return }
        struct NameRow: Decodable { let id: UUID; let display_name: String }
        if let rows: [NameRow] = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("id,display_name")
            .in("id", values: missing)
            .execute()
            .value {
            for row in rows { senderNames[row.id] = row.display_name }
        }
    }

    private func subscribeToRealtime() async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("live-chat-\(streamID.uuidString)")
        let messageInserts = ch.postgresChange(
            InsertAction.self, schema: "public", table: "live_stream_messages",
            filter: "stream_id=eq.\(streamID.uuidString)"
        )
        channel = ch
        await ch.subscribe()

        Task {
            for await change in messageInserts {
                if let message = try? change.decodeRecord(as: LiveStreamMessage.self, decoder: JSONDecoder()) {
                    if !messages.contains(where: { $0.id == message.id }) {
                        messages.append(message)
                        await resolveSenderNames([message.senderID])
                    }
                }
            }
        }
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Mismo límite real que live_stream_messages (char_length between
        // 1 and 200, 0059_live_stream_messages.sql).
        guard trimmed.count <= 200 else { return }
        struct NewLiveStreamMessage: Encodable {
            let stream_id: UUID
            let sender_id: UUID
            let body: String
        }
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            // Best-effort -- un mensaje de chat en vivo que falla no debe
            // interrumpir la visualización del directo.
            try? await SupabaseManager.shared.client
                .from("live_stream_messages")
                .insert(NewLiveStreamMessage(stream_id: streamID, sender_id: userID, body: trimmed))
                .execute()
        }
    }
}
