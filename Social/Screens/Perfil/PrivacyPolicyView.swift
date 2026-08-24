//
//  PrivacyPolicyView.swift
//  Social
//
//  Hallazgo real, legalmente relevante: `legal/privacy_policy_es.md`
//  existe en el repositorio (el documento que ya se auditó y corrigió
//  varias veces esta sesión) pero nunca se mostraba DENTRO de la app.
//  App Store/Play Store exigen que la política de privacidad sea
//  accesible desde la propia app. Copiado como recurso del bundle (ver
//  project.yml) — texto plano, sin renderer de Markdown, dependencia
//  nueva innecesaria solo para esto. Equivalente de PrivacyPolicyScreen.kt.
//

import SwiftUI

private struct LegalDocView: View {
    let resourceName: String
    let fallback: String
    @State private var text = "Cargando…"

    var body: some View {
        ScrollView {
            Text(text)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            if let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                text = content
            } else {
                text = fallback
            }
        }
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocView(resourceName: "privacy_policy_es", fallback: "No se pudo cargar la política de privacidad.")
            .navigationTitle("Política de privacidad")
    }
}

/// Términos de servicio — mismo hallazgo, hueco real: no existía ni
/// siquiera el documento en `legal/` hasta esta pasada, y el registro
/// dejaba crear una cuenta sin aceptar ningún término (ver AuthView.swift).
struct TermsOfServiceView: View {
    var body: some View {
        LegalDocView(resourceName: "terms_of_service_es", fallback: "No se pudieron cargar los términos de servicio.")
            .navigationTitle("Términos de servicio")
    }
}
