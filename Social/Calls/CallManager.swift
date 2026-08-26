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

    private var channel: RealtimeChannelV2?
    private var myID: UUID?

    func start() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        myID = userID
        await subscribeToRealtime(userID: userID)
    }

    func stop() async {
        await channel?.unsubscribe()
        channel = nil
    }

    /// El usuario ya vio el estado final -- limpia el estado local.
    /// Deliberadamente NO automático: temporizar el borrado aquí mismo
    /// competiría de verdad con el eco de Realtime de la propia
    /// actualización, pudiendo resucitar una llamada ya cerrada -- la
    /// pantalla decide cuándo.
    func dismiss() {
        activeCall = nil
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
    }
}
