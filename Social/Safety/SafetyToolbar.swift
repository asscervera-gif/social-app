//
//  SafetyToolbar.swift
//  Social
//
//  Botón flotante de denuncia, accesible desde cualquier pestaña — se añade
//  como overlay en RootTabView (principio de producto "seguridad primero").
//  El modo invisible en un toque vive en SocialCameraView, no aquí: ahí es
//  donde tiene efecto real sobre el motor UWB (SocialProximity.setDiscoverable),
//  así que repetirlo en las otras 4 pestañas solo daría una falsa sensación
//  de control sin acción real detrás.
//

import SwiftUI

struct SafetyToolbar: View {

    @State private var showExplanation = false
    let userID: UUID

    var body: some View {
        HStack {
            Spacer()
            Button {
                showExplanation = true
            } label: {
                Image(systemName: "exclamationmark.shield.fill")
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .padding()
        }
        // Hallazgo real, corregido esta pasada (bug de seguridad genuino,
        // no solo cosmético): este botón abría ReportSheet con
        // `reportedID` = el propio `userID` por defecto (sin usuario
        // concreto en contexto) -- dos toques bastaban para denunciarse o
        // BLOQUEARSE a uno mismo por accidente. Ahora que el resto de la
        // app tiene entradas de denuncia/bloqueo con el target real
        // (perfil, chat, post, comentario), este overlay deja de abrir un
        // ReportSheet sin sentido y en su lugar explica dónde denunciar
        // de verdad.
        .alert("Denunciar o bloquear", isPresented: $showExplanation) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Para denunciar o bloquear a alguien, hazlo desde su perfil, un chat, una publicación o un comentario suyo.")
        }
    }
}

/// Hoja de denuncia. `reportedID` se pasa desde la pantalla que abrió la
/// hoja (perfil, chat, post, comentario) — siempre con un target real,
/// nunca desde un overlay global sin contexto (ver SafetyToolbar más arriba).
struct ReportSheet: View {
    @EnvironmentObject private var safety: SafetyManager
    @Environment(\.dismiss) private var dismiss
    let userID: UUID
    let reportedID: UUID

    @State private var reason = "Comportamiento inapropiado"
    @State private var details: String
    let reasons = ["Comportamiento inapropiado", "Perfil falso", "Acoso", "Contenido ofensivo", "Otro"]

    init(userID: UUID, reportedID: UUID? = nil, initialDetails: String = "") {
        self.userID = userID
        self.reportedID = reportedID ?? userID
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
            }
            .navigationTitle("Denunciar")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar") {
                        Task {
                            await safety.report(reporterID: userID, reportedID: reportedID, reason: reason, details: details.isEmpty ? nil : details)
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
