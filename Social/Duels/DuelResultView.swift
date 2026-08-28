//
//  DuelResultView.swift
//  Social
//
//  Visor de solo lectura para un duelo YA completado — distinto de
//  DuelView, que siempre arranca un duelo NUEVO llamando a la IA (gastaría
//  cupo del rate-limit de 20/hora si se reutilizara aquí). Antes "Ver
//  duelo" en AvisosView.swift era un botón vacío (`{}`).
//
//  Aviso de honestidad: asume `payload["duel_id"]`, misma convención ya
//  documentada para chat_id/social_id/actor_id/compat_request_id.
//

import SwiftUI

struct DuelResultView: View {
    let duelID: UUID

    private struct DuelRow: Decodable {
        let compatibilityDelta: Int?
        let explanation: String?
        let initiatorID: UUID?
        let opponentID: UUID?

        enum CodingKeys: String, CodingKey {
            case compatibilityDelta = "compatibility_delta"
            case explanation
            case initiatorID = "initiator_id"
            case opponentID = "opponent_id"
        }
    }

    @State private var delta: Int?
    @State private var explanation: String?
    @State private var opponentName: String?
    @State private var errorMessage: String?
    // "Compartir el resultado de un duelo como Historia" real, comparado
    // con Wordle/Kahoot (compartir el resultado de un reto) -- hallazgo
    // real, confirmado con grep de "compartir"/"share" sin resultados en
    // este archivo. Reutiliza el mismo mecanismo real de `stories` ya
    // usado por "compartir post a Historia" (0129_story_shared_post.sql),
    // aquí con una tarjeta real generada con ImageRenderer (SwiftUI,
    // iOS 16+) en vez de una foto ya existente. Equivalente de
    // DuelResultScreen.kt.renderDuelResultCard().
    @State private var isSharing = false
    @State private var shareMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            if let delta {
                if let opponentName {
                    Text("Duelo contra \(opponentName)")
                        .font(.subheadline.bold())
                }
                Image(systemName: delta >= 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(delta >= 0 ? .green : .red)
                Text("\(delta >= 0 ? "+" : "")\(delta) de compatibilidad")
                    .font(.title3.bold())
                if let explanation {
                    Text(explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task { await shareToStory(delta: delta) }
                } label: {
                    Text(isSharing ? "Compartiendo…" : "Compartir como Historia")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSharing)
                .padding(.top, 8)
                if let shareMessage {
                    Text(shareMessage).font(.caption).foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                ProgressView("Cargando duelo…")
            }
        }
        .padding(28)
        .task {
            do {
                let row: DuelRow = try await SupabaseManager.shared.client
                    .from("duels")
                    .select()
                    .eq("id", value: duelID)
                    .single()
                    .execute()
                    .value
                delta = row.compatibilityDelta ?? 0
                explanation = row.explanation

                // Hallazgo real: igual que en DuelHistoryView antes de esta
                // pasada, este visor de resultado nunca mostraba contra
                // quién fue el duelo.
                let myID = try? await SupabaseManager.shared.client.auth.session.user.id
                let otherID = row.initiatorID == myID ? row.opponentID : row.initiatorID
                if let otherID {
                    struct NameRow: Decodable { let display_name: String }
                    let nameRow: NameRow? = try? await SupabaseManager.shared.client
                        .from("profiles")
                        .select("display_name")
                        .eq("id", value: otherID)
                        .single()
                        .execute()
                        .value
                    opponentName = nameRow?.display_name
                }
            } catch {
                errorMessage = "No se pudo cargar el duelo."
            }
        }
    }

    /// "Compartir el resultado de un duelo como Historia" real -- renderiza
    /// una tarjeta real con `ImageRenderer` (SwiftUI, iOS 16+, el
    /// deployment target exacto de este proyecto), la sube al mismo
    /// bucket real ya usado por el resto de fotos/historias, e inserta
    /// una fila real en `stories`. Equivalente de
    /// DuelResultScreen.kt.onClick del botón "Compartir como Historia".
    @MainActor
    private func shareToStory(delta: Int?) async {
        guard let delta else { return }
        isSharing = true
        defer { isSharing = false }
        do {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            let card = DuelResultCardView(opponentName: opponentName ?? "alguien", delta: delta)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            guard let uiImage = renderer.uiImage, let data = uiImage.jpegData(compressionQuality: 0.9) else {
                shareMessage = "No se pudo generar la tarjeta."
                return
            }
            let url = try await StorageUploader.uploadImage(data: data, fileExtension: "jpg", userID: userID)
            struct NewStory: Encodable {
                let author_id: UUID
                let media_url: String
            }
            try await SupabaseManager.shared.client
                .from("stories")
                .insert(NewStory(author_id: userID, media_url: url))
                .execute()
            shareMessage = "Compartido a tu historia"
        } catch {
            shareMessage = "No se pudo compartir a tu historia."
        }
    }
}

/// Tarjeta real del resultado de un duelo, renderizada fuera de pantalla
/// con `ImageRenderer` -- mismo contenido visual que `DuelResultView`
/// muestra en la propia pantalla, adaptado a una imagen cuadrada para
/// Historia. Equivalente de DuelResultCard.kt.renderDuelResultCard().
private struct DuelResultCardView: View {
    let opponentName: String
    let delta: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("Duelo contra \(opponentName)")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("\(delta >= 0 ? "+" : "")\(delta)")
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(.white)
            Text("de compatibilidad")
                .font(.title3)
                .foregroundStyle(.white)
            Spacer()
            Text("SOCIAL")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(40)
        .frame(width: 800, height: 1000)
        .background(LinearGradient(colors: [Color(red: 0.30, green: 0.67, blue: 0.97), Color(red: 0.65, green: 0.37, blue: 0.92)], startPoint: .top, endPoint: .bottom))
    }
}
