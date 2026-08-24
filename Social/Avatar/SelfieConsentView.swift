//
//  SelfieConsentView.swift
//  Social
//
//  Consentimiento explícito de datos biométricos antes de tomar la selfie
//  para generar el avatar. La foto original nunca se guarda: solo el
//  resultado del avatar generado (ver AvatarProvider.generateAvatar).
//

import SwiftUI

struct SelfieConsentView: View {

    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(.system(size: 44))
                .foregroundStyle(.purple)

            Text("Antes de tu selfie")
                .font(.title2.bold())

            Text("""
            Para crear tu avatar 3D necesitamos procesar una foto de tu cara. \
            Es un dato biométrico.

            • Tu foto se envía únicamente al motor de generación de avatares.
            • No guardamos la imagen de tu cara en ningún momento: solo se \
            almacena el avatar 3D resultante.
            • Puedes borrar tu avatar y volver a generarlo cuando quieras \
            desde tu perfil.
            """)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)

            Button("Acepto y continúo", action: onAccept)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("Ahora no", action: onDecline)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
