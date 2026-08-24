//
//  ChangePasswordView.swift
//  Social
//
//  Hallazgo real: había recuperación de contraseña por email (pasada
//  anterior) pero ninguna forma de cambiarla estando ya dentro de la
//  cuenta. Equivalente de ChangePasswordViewModel.kt.
//

import SwiftUI
import Supabase

@MainActor
final class ChangePasswordViewModel: ObservableObject {
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    func changePassword(_ newPassword: String) async {
        guard newPassword.count >= 6 else {
            errorMessage = "La contraseña debe tener al menos 6 caracteres."
            return
        }
        errorMessage = nil
        successMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            // Aviso de honestidad: `auth.update(user: UserAttributes(...))`
            // es el método documentado de supabase-swift 2.x para cambiar
            // la contraseña de la sesión activa, coherente con
            // `auth.updateUser { password = ... }` ya compiler-verificado
            // en la versión Kotlin equivalente — sin verificación de
            // compilador real aquí (límite de plataforma).
            try await SupabaseManager.shared.client.auth.update(user: UserAttributes(password: newPassword))
            successMessage = "Contraseña actualizada."
        } catch {
            errorMessage = "No se pudo cambiar la contraseña: \(error.localizedDescription)"
        }
    }
}

struct ChangePasswordSection: View {
    @StateObject private var viewModel = ChangePasswordViewModel()
    @State private var newPassword = ""

    var body: some View {
        Text("Cuenta").font(.headline)
        SecureField("Nueva contraseña", text: $newPassword)
            .textFieldStyle(.roundedBorder)
        if let error = viewModel.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if let success = viewModel.successMessage {
            Text(success).font(.caption).foregroundStyle(Color.accentColor)
        }
        Button {
            Task { await viewModel.changePassword(newPassword) }
        } label: {
            if viewModel.isSaving {
                ProgressView()
            } else {
                Text("Cambiar contraseña").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isSaving)
    }
}
