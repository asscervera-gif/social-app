//
//  SafetyToolbar.swift
//  Social
//
//  Hoja de denuncia real (`ReportSheet`, más abajo), usada desde cualquier
//  pantalla con un target real en contexto (perfil, chat, post, comentario,
//  mensaje).
//
//  Este archivo tenía antes un botón flotante global (`SafetyToolbar`),
//  overlay en RootTabView sobre las 4 pestañas sin cámara. Hallazgo real,
//  reportado directamente por el usuario probando la app de verdad: "hay
//  un icono de denunciar/bloquear que no sé en qué momento está ahí" --
//  desde que se cerró el bug de autodenuncia (ver historial de
//  RootTabView.swift), ese botón ya solo abría un aviso de "denúncialo
//  desde su perfil/chat/post/comentario", porque cada pantalla real ya
//  tiene su propio botón con el target correcto. Un icono flotante que
//  solo explica dónde ir ya no aportaba nada, solo confundía -- quitado
//  del todo.
//

import SwiftUI

/// Hoja de denuncia. `reportedID` se pasa desde la pantalla que abrió la
/// hoja (perfil, chat, post, comentario) — siempre con un target real.
struct ReportSheet: View {
    @EnvironmentObject private var safety: SafetyManager
    @Environment(\.dismiss) private var dismiss
    let userID: UUID
    let reportedID: UUID
    // Hallazgo real, comparado con Instagram/TikTok/Facebook: referencia
    // real al post/comentario denunciado (0045_reports_content_reference.sql),
    // en vez del texto libre y editable de antes ("Publicación {id}"
    // metido a mano en initialDetails).
    let postID: UUID?
    let commentID: UUID?
    // Hallazgo real, comparado con Instagram/WhatsApp/Messenger: mismo
    // hueco exacto que postID/commentID pero en un chat -- ver
    // 0048_reports_message_reference.sql.
    let messageID: UUID?
    // Mismo hueco exacto que messageID pero en un chat de grupo -- ver
    // 0067_reports_group_message_reference.sql.
    let groupMessageID: UUID?

    @State private var reason = "Comportamiento inapropiado"
    @State private var details: String
    let reasons = ["Comportamiento inapropiado", "Perfil falso", "Acoso", "Contenido ofensivo", "Otro"]

    init(userID: UUID, reportedID: UUID? = nil, initialDetails: String = "", postID: UUID? = nil, commentID: UUID? = nil, messageID: UUID? = nil, groupMessageID: UUID? = nil) {
        self.userID = userID
        self.reportedID = reportedID ?? userID
        self.postID = postID
        self.commentID = commentID
        self.messageID = messageID
        self.groupMessageID = groupMessageID
        _details = State(initialValue: initialDetails)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Motivo", selection: $reason) {
                    ForEach(reasons, id: \.self) { Text($0) }
                }
                TextField("Detalles (opcional)", text: $details, axis: .vertical)
                // Hallazgo real, mismo criterio ya aplicado a caption/
                // nombre/bio: el límite de 1000 caracteres es real
                // (reports_details_length, 0024_more_text_length_limits.sql)
                // y ya se valida antes de enviar (SafetyManager.swift),
                // pero nada avisaba mientras se escribe. Mismo fix ya
                // construido en la versión Kotlin equivalente.
                Text("\(details.count)/1000")
                    .font(.caption2)
                    .foregroundStyle(details.count > 1000 ? .red : .secondary)

                // Restringir una cuenta real, comparado con Instagram --
                // deliberadamente más suave que bloquear (abajo): sus
                // comentarios dejan de verse para los demás sin que se
                // entere de nada, sin cortar del todo la relación. Ver
                // SafetyManager.restrict(), 0093_restrict_account.sql.
                Section {
                    Button("Restringir a este usuario") {
                        Task {
                            await safety.restrict(userID: userID, restrictedID: reportedID)
                            dismiss()
                        }
                    }
                }
                // Silenciar una cuenta real, comparado con Instagram/
                // Twitter/X/Facebook -- sus publicaciones dejan de verse
                // en tu feed/Reels sin dejar de seguirla, sin bloquearla
                // y sin que se entere nunca. Ver
                // SafetyManager.muteAccount(), 0126_muted_accounts.sql.
                Section {
                    Button("🔇 Silenciar a este usuario") {
                        Task {
                            await safety.muteAccount(userID: userID, mutedID: reportedID)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Denunciar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar") {
                        Task {
                            await safety.report(reporterID: userID, reportedID: reportedID, reason: reason, details: details.isEmpty ? nil : details, postID: postID, commentID: commentID, messageID: messageID, groupMessageID: groupMessageID)
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                // Antes SafetyManager.block() existía pero nunca se llamaba
                // desde ningún sitio de la UI en ninguna plataforma.
                ToolbarItem(placement: .destructiveAction) {
                    Button("Bloquear", role: .destructive) {
                        Task {
                            await safety.block(userID: userID, blockedID: reportedID)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
