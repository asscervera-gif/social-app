//
//  CallManager.swift
//  Social
//
//  Videollamada/llamada de voz 1:1 real (0079_calls.sql), comparado con
//  WhatsApp/Messenger/Instagram -- las tres dejan llamar directamente
//  desde un chat privado; SOCIAL no tenía nada de esto, la única pieza de
//  vídeo en tiempo real era "En directo" (audiencia pública,
//  LiveStreamsViewModel.swift). Equivalente de CallManager.kt.
//
//  Global, montado una sola vez en RootTabView.swift (mismo criterio que
//  NotificationsBadgeViewModel.swift) -- una llamada entrante tiene que
//  poder avisar sin importar en qué pestaña esté el usuario. Mismo canal
//  por-usuario ya usado ahí (`calls-{userID}`), no un canal global:
//  `legal/scaling_notes.md` documenta explícitamente que los canales de
//  Realtime de este proyecto son por chat o por usuario, nunca globales.
//
//  Aviso de honestidad, mismo criterio que "En directo": esto SÍ detecta
//  una llamada entrante en tiempo real mientras la app está abierta (en
//  cualquier pestaña) vía Supabase Realtime -- lo que NO puede hacer sin
//  push real (APNs/FCM, ver LOOP_STATE.md "Pendiente real") es sonar con
//  la app cerrada o en segundo plano del todo.
//

import Foundation
import Supabase

@MainActor
final class CallManager: ObservableObject {
    @Published var activeCall: Call?
    // Solo relevante para llamadas de GRUPO (0083_group_calls.sql): una
    // fila real por miembro del grupo, a diferencia de la 1:1 que solo
    // tiene caller/callee dentro de la propia fila de `calls`.
    @Published var participants: [CallParticipant] = []

    private var channel: RealtimeChannelV2?
    private var participantsChannel: RealtimeChannelV2?
    private var myID: UUID?

    func start() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        myID = userID
        await subscribeToRealtime(userID: userID)
    }

    func stop() async {
        await channel?.unsubscribe()
        channel = nil
        await participantsChannel?.unsubscribe()
        participantsChannel = nil
    }

    /// El usuario ya vio el estado final -- limpia el estado local.
    /// Deliberadamente NO automático: temporizar el borrado aquí mismo
    /// competiría de verdad con el eco de Realtime de la propia
    /// actualización, pudiendo resucitar una llamada ya cerrada -- la
    /// pantalla decide cuándo.
    func dismiss() {
        activeCall = nil
        participants = []
        Task {
            await participantsChannel?.unsubscribe()
            participantsChannel = nil
        }
    }

    private struct NewCall: Encodable {
        let chat_id: UUID
        let caller_id: UUID
        let callee_id: UUID
        let kind: String
    }

    func startCall(chatID: UUID, calleeID: UUID, kind: String) {
        guard let userID = myID, activeCall == nil else { return }
        Task {
            do {
                let call: Call = try await SupabaseManager.shared.client
                    .from("calls")
                    .insert(NewCall(chat_id: chatID, caller_id: userID, callee_id: calleeID, kind: kind))
                    .select()
                    .single()
                    .execute()
                    .value
                activeCall = call
            } catch {
                // No se pudo iniciar -- se queda sin llamada activa, mismo
                // criterio de "falla en silencio, sin romper el resto del
                // chat" ya aplicado a activity-ai/icebreaker-ai.
            }
        }
    }

    func accept() { updateStatus("accepted") }
    func decline() { updateStatus("declined") }
    func cancelOutgoing() { updateStatus("ended") }

    private struct NewGroupCall: Encodable {
        let group_chat_id: UUID
        let caller_id: UUID
        let kind: String
    }

    /// Videollamada de GRUPO real (0083_group_calls.sql), comparado con
    /// WhatsApp/Messenger/Telegram -- a diferencia de startCall() (1:1),
    /// no hay un único destinatario que la acepte primero: el propio
    /// emisor queda ya 'accepted' de inmediato (populate_call_participants
    /// lo garantiza también del lado del servidor). Equivalente de
    /// CallManager.kt.startGroupCall().
    func startGroupCall(groupChatID: UUID, kind: String) {
        guard let userID = myID, activeCall == nil else { return }
        Task {
            do {
                var call: Call = try await SupabaseManager.shared.client
                    .from("calls")
                    .insert(NewGroupCall(group_chat_id: groupChatID, caller_id: userID, kind: kind))
                    .select()
                    .single()
                    .execute()
                    .value
                // El RETURNING de este INSERT todavía refleja 'ringing'
                // (el valor por defecto de la columna, antes de que el
                // trigger AFTER INSERT la corrija con un UPDATE aparte --
                // RETURNING nunca ve cambios de un trigger AFTER sobre
                // otra sentencia, mismo hallazgo real documentado en
                // test_rls.mjs) -- se corrige aquí mismo en vez de hacer
                // una segunda ida y vuelta de red solo para confirmar algo
                // que el propio diseño del servidor ya garantiza.
                call.status = "accepted"
                activeCall = call
                await loadParticipants(callID: call.id)
                await subscribeToParticipants(callID: call.id)
            } catch {
                // Falla en silencio, mismo criterio que startCall().
            }
        }
    }

    func acceptGroupCall() { updateMyParticipation("accepted") }
    func declineGroupCall() { updateMyParticipation("declined") }

    /// Colgar MI PROPIA participación real en una llamada de grupo -- a
    /// diferencia de end() (1:1), esto nunca termina la llamada para el
    /// resto: cada participante sale por su cuenta, mismo criterio que
    /// WhatsApp/Messenger.
    func leaveGroupCall() { updateMyParticipation("ended") }

    private func updateMyParticipation(_ status: String) {
        guard let call = activeCall, let userID = myID else { return }
        if let index = participants.firstIndex(where: { $0.userID == userID }) {
            participants[index].status = status
        }
        Task {
            struct ParticipationUpdate: Encodable {
                let status: String
                let joined_at: String?
                let left_at: String?
            }
            let update = ParticipationUpdate(
                status: status,
                joined_at: status == "accepted" ? ISO8601DateFormatter().string(from: Date()) : nil,
                left_at: status == "ended" ? ISO8601DateFormatter().string(from: Date()) : nil
            )
            try? await SupabaseManager.shared.client
                .from("call_participants")
                .update(update)
                .eq("call_id", value: call.id)
                .eq("user_id", value: userID)
                .execute()
        }
    }

    private func loadParticipants(callID: UUID) async {
        do {
            let rows: [CallParticipant] = try await SupabaseManager.shared.client
                .from("call_participants")
                .select()
                .eq("call_id", value: callID)
                .execute()
                .value
            participants = rows
        } catch {
            // Se queda vacía -- IncomingGroupCallView/LiveGroupCallView
            // simplemente no tendrán roster hasta que Realtime traiga algo.
        }
    }

    /// Canal real acotado a UNA llamada de grupo concreta (no global, no
    /// por-usuario): mismo criterio de "nunca un canal global" que el
    /// resto de este archivo, pero aquí hace falta ver el estado de TODOS
    /// los participantes reales de esta llamada (quién se
    /// unió/rechazó/salió), no solo el propio -- se crea al entrar en la
    /// llamada y se destruye al salir (dismiss()/el siguiente
    /// startGroupCall()).
    private func subscribeToParticipants(callID: UUID) async {
        await participantsChannel?.unsubscribe()
        let client = SupabaseManager.shared.client
        let ch = client.channel("call-participants-\(callID.uuidString)")
        let updates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "call_participants",
            filter: "call_id=eq.\(callID.uuidString)"
        )
        participantsChannel = ch
        await ch.subscribe()

        Task {
            for await change in updates {
                guard let updated = try? change.decodeRecord(as: CallParticipant.self, decoder: JSONDecoder()) else { continue }
                if let index = participants.firstIndex(where: { $0.userID == updated.userID }) {
                    participants[index] = updated
                }
            }
        }
    }

    func end() {
        guard let call = activeCall else { return }
        Task {
            struct EndUpdate: Encodable { let status: String; let ended_at: String }
            try? await SupabaseManager.shared.client
                .from("calls")
                .update(EndUpdate(status: "ended", ended_at: ISO8601DateFormatter().string(from: Date())))
                .eq("id", value: call.id)
                .execute()
        }
    }

    private func updateStatus(_ status: String) {
        guard var call = activeCall else { return }
        call.status = status
        activeCall = call
        Task {
            struct StatusUpdate: Encodable { let status: String }
            try? await SupabaseManager.shared.client
                .from("calls")
                .update(StatusUpdate(status: status))
                .eq("id", value: call.id)
                .execute()
        }
    }

    struct LiveKitTokenResponse: Decodable {
        let token: String
        let wsUrl: String
        let roomName: String
    }

    /// Mismo patrón exacto que LiveStreamsViewModel.swift.requestToken() --
    /// solo se emite un token real cuando la llamada YA está `accepted`
    /// de verdad en la base de datos (comprobado en call-token/index.ts,
    /// nunca confiado al cliente).
    func requestToken(callID: UUID) async -> LiveKitTokenResponse? {
        struct TokenRequest: Encodable { let callId: UUID }
        do {
            let response: LiveKitTokenResponse = try await SupabaseManager.shared.client.functions
                .invoke("call-token", options: .init(body: TokenRequest(callId: callID)))
            return response
        } catch {
            return nil
        }
    }

    private func subscribeToRealtime(userID: UUID) async {
        let client = SupabaseManager.shared.client
        let ch = client.channel("calls-\(userID.uuidString)")

        let incoming = ch.postgresChange(
            InsertAction.self, schema: "public", table: "calls",
            filter: "callee_id=eq.\(userID.uuidString)"
        )
        let outgoingUpdates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "calls",
            filter: "caller_id=eq.\(userID.uuidString)"
        )
        let incomingUpdates = ch.postgresChange(
            UpdateAction.self, schema: "public", table: "calls",
            filter: "callee_id=eq.\(userID.uuidString)"
        )
        // Llamada de GRUPO entrante real (0083_group_calls.sql): mi propia
        // fila real en call_participants se inserta en el momento de crear
        // la llamada, ya 'accepted' si soy quien llama o 'ringing' si soy
        // cualquier otro miembro real del grupo -- mismo canal por-usuario
        // que el resto de este método, nunca global.
        let incomingGroupCalls = ch.postgresChange(
            InsertAction.self, schema: "public", table: "call_participants",
            filter: "user_id=eq.\(userID.uuidString)"
        )

        channel = ch
        await ch.subscribe()

        Task {
            // Alguien me está llamando de verdad ahora mismo -- ignora una
            // segunda llamada entrante mientras ya hay una activa (mismo
            // criterio simple que "ocupado" en cualquier app de llamadas).
            for await change in incoming {
                if activeCall != nil { continue }
                if let call = try? change.decodeRecord(as: Call.self, decoder: JSONDecoder()), call.status == "ringing" {
                    activeCall = call
                }
            }
        }
        Task {
            // La otra parte aceptó/rechazó/colgó una llamada que YO inicié.
            for await change in outgoingUpdates {
                if let call = try? change.decodeRecord(as: Call.self, decoder: JSONDecoder()), activeCall?.id == call.id {
                    activeCall = call
                }
            }
        }
        Task {
            // Reflejar en este dispositivo un cambio de estado de una
            // llamada donde YO soy quien recibe (p. ej. la acepté desde
            // otra sesión).
            for await change in incomingUpdates {
                if let call = try? change.decodeRecord(as: Call.self, decoder: JSONDecoder()), activeCall?.id == call.id {
                    activeCall = call
                }
            }
        }
        Task {
            for await change in incomingGroupCalls {
                guard let participant = try? change.decodeRecord(as: CallParticipant.self, decoder: JSONDecoder()) else { continue }
                if activeCall?.id == participant.callID { continue }
                if activeCall != nil { continue }
                do {
                    let call: Call = try await SupabaseManager.shared.client
                        .from("calls")
                        .select()
                        .eq("id", value: participant.callID)
                        .single()
                        .execute()
                        .value
                    activeCall = call
                    await loadParticipants(callID: call.id)
                    await subscribeToParticipants(callID: call.id)
                } catch {
                    // No crítico: la llamada real sigue viva en el
                    // servidor aunque este dispositivo no la muestre.
                }
            }
        }
    }
}
