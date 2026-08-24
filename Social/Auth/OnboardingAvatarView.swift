//
//  OnboardingAvatarView.swift
//  Social
//
//  Hallazgo real, hueco grande documentado toda la sesión: `SelfieConsentView`
//  y `AvatarProvider.generateAvatar()` estaban completamente construidos
//  pero nunca se llamaban desde ningún sitio — no existía ningún flujo de
//  onboarding que los disparara. Ahora que el registro real existe
//  (AuthView.swift), este es el punto natural para conectarlos: se muestra
//  una vez, justo después de entrar por primera vez con `avatar_config`
//  todavía sin configurar (ver AppRootView.swift).
//
//  Sigue usando PlaceholderAvatarProvider (ActiveAvatarProvider.shared) —
//  no se ha inventado ninguna integración real de Avaturn/MetaPerson, ver
//  el aviso de honestidad en AvatarProvider.swift. Esto conecta el flujo
//  real de extremo a extremo con el motor placeholder, no simula un motor
//  que no existe.
//

import SwiftUI
import PhotosUI

struct OnboardingAvatarView: View {
    let onFinished: () -> Void

    private enum Step {
        case consent, pickPhoto, generating, error
    }

    @State private var step: Step = .consent
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            switch step {
            case .consent:
                SelfieConsentView(
                    onAccept: { step = .pickPhoto },
                    onDecline: onFinished
                )
            case .pickPhoto:
                VStack(spacing: 20) {
                    Text("Elige una foto de tu cara").font(.title3.bold())
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text("Elegir foto").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Ahora no", action: onFinished)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .onChange(of: selectedPhoto) { newValue in
                    guard let newValue else { return }
                    Task { await generateAvatar(from: newValue) }
                }
            case .generating:
                ProgressView("Generando tu avatar…")
                    .padding(28)
            case .error:
                VStack(spacing: 16) {
                    Text(errorMessage ?? "No se pudo generar el avatar.")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("Reintentar") { step = .pickPhoto }
                        .buttonStyle(.borderedProminent)
                    Button("Ahora no", action: onFinished)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
            }
        }
    }

    private func generateAvatar(from item: PhotosPickerItem) async {
        step = .generating
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let uiImage = UIImage(data: data)
            else {
                errorMessage = "No se pudo leer la foto."
                step = .error
                return
            }
            // La foto original nunca se guarda — solo el resultado del
            // avatar generado, ver SelfieConsentView.swift.
            let result = try await ActiveAvatarProvider.shared.generateAvatar(fromSelfie: uiImage)
            try await saveAvatarConfig(result.config)
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    private func saveAvatarConfig(_ config: [String: String]) async throws {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct AvatarUpdate: Encodable { let avatar_config: [String: String] }
        try await SupabaseManager.shared.client
            .from("profiles")
            .update(AvatarUpdate(avatar_config: config))
            .eq("id", value: userID)
            .execute()
    }
}
