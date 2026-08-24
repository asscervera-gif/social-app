//
//  DuelEntryPoint.swift
//  Social
//
//  Carga las secciones del oponente antes de arrancar el duelo, y solo
//  entonces monta DuelView — equivalente a DuelEntryPoint.kt en Android.
//  Antes DuelView no tenía ningún punto de entrada real en la app: la
//  ruta existía en el código pero nada la montaba (mismo hallazgo que con
//  Modo Evento). Se cablea aquí y se llama desde ChatView.swift, que es el
//  sitio natural para retar a duelo a la persona con la que ya se chatea.
//

import SwiftUI

struct DuelEntryPoint: View {
    let chatID: UUID
    let currentUserID: UUID
    let opponentID: UUID

    @State private var viewModel: DuelViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DuelView(viewModel: viewModel)
            } else {
                ProgressView("Preparando el duelo…")
            }
        }
        .task {
            // El DuelViewModel se crea UNA vez (guardado en @State), no en
            // cada redibujado — si no, cada recomposición reiniciaría el
            // duelo desde cero.
            guard viewModel == nil else { return }
            let sections: [ProfileSection] = (try? await SupabaseManager.shared.client
                .from("profile_sections")
                .select()
                .eq("profile_id", value: opponentID)
                .execute()
                .value) ?? []
            let newViewModel = DuelViewModel(chatID: chatID, initiatorID: currentUserID, opponentID: opponentID)
            viewModel = newViewModel
            await newViewModel.start(opponentSections: sections)
        }
    }
}
