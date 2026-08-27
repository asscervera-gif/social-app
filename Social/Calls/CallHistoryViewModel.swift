//
//  CallHistoryViewModel.swift
//  Social
//
//  Historial de llamadas real, comparado con WhatsApp/Messenger/FaceTime --
//  SOCIAL ya tenía llamadas 1:1 y de grupo reales (0079_calls.sql/
//  0083_group_calls.sql), pero ninguna pantalla mostraba quién llamó, quién
//  perdió una llamada, ni la duración real -- confirmado en el propio
//  código (grep de "historial de llamadas"/"call history" sin resultados
//  en todo el repo). Sin migración: `calls` ya tiene todo lo necesario,
//  `calls_select` (última versión real: 0083) ya restringe a quien
//  participó de verdad -- una consulta sin filtro extra ya solo devuelve
//  mis propias llamadas (1:1 o de grupo). Equivalente de
//  CallHistoryViewModel.kt.
//

import Foundation

@MainActor
final class CallHistoryViewModel: ObservableObject {
    struct CallEntry: Identifiable {
        let call: Call
        let isOutgoing: Bool
        let otherName: String
        let isGroup: Bool
        var id: UUID { call.id }
    }

    @Published var entries: [CallEntry] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let myID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        do {
            let calls: [Call] = try await SupabaseManager.shared.client
                .from("calls")
                .select()
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value

            let otherIDs = Array(Set(calls.compactMap { $0.callerID == myID ? $0.calleeID : $0.callerID }))
            var profiles: [UUID: Profile] = [:]
            if !otherIDs.isEmpty, let rows: [Profile] = try? await SupabaseManager.shared.client
                .from("profiles")
                .select()
                .in("id", values: otherIDs)
                .execute()
                .value {
                profiles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            }

            let groupIDs = Array(Set(calls.compactMap { $0.groupChatID }))
            var groupNames: [UUID: String] = [:]
            if !groupIDs.isEmpty {
                struct GroupChatNameRow: Decodable { let id: UUID; let name: String }
                if let rows: [GroupChatNameRow] = try? await SupabaseManager.shared.client
                    .from("group_chats")
                    .select("id,name")
                    .in("id", values: groupIDs)
                    .execute()
                    .value {
                    groupNames = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
                }
            }

            entries = calls.map { call in
                let isGroup = call.groupChatID != nil
                let isOutgoing = call.callerID == myID
                let otherName: String
                if isGroup {
                    otherName = groupNames[call.groupChatID!] ?? "Grupo"
                } else {
                    let otherID = isOutgoing ? call.calleeID : call.callerID
                    otherName = otherID.flatMap { profiles[$0]?.displayName } ?? "Perfil"
                }
                return CallEntry(call: call, isOutgoing: isOutgoing, otherName: otherName, isGroup: isGroup)
            }
        } catch {
            errorMessage = "No se pudo cargar el historial de llamadas."
        }
    }
}
