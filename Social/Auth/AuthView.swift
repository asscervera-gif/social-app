//
//  AuthView.swift
//  Social
//
//  Pantalla de registro/login — no existía en ninguna plataforma, el hueco
//  raíz más grave de toda la sesión (ver AuthViewModel para el detalle
//  completo). Sin campo de foto/avatar aquí a propósito: la generación de
//  avatar sigue sin infraestructura real verificada y no se debe fingir
//  aquí — el registro deja un `display_name` real vía `handle_new_user`
//  (0014_handle_new_user.sql) y el avatar por defecto ya es el círculo con
//  gradiente de PlaceholderAvatarProvider. Equivalente de AuthScreen.kt.
//

import SwiftUI

struct AuthView: View {
    @StateObject private var viewModel = AuthViewModel()
    // Hallazgo real (redisenio, mismo patrón ya aplicado en
    // AuthScreen.kt): la app entraba directa al formulario completo de
    // registro al abrir, sin darle a elegir a alguien que YA tiene cuenta
    // la opción de iniciar sesión antes de ver seis campos que no le
    // hacen falta. nil = pantalla de bienvenida real, true/false = el
    // formulario para cada caso.
    @State private var authMode: Bool?
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var birthDate = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    // Hallazgo real: el registro dejaba crear una cuenta sin aceptar
    // ningún término — no existía ni siquiera el documento de términos de
    // servicio hasta esta pasada (ver legal/terms_of_service_es.md).
    @State private var acceptedTerms = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    private var isSignUp: Bool { authMode ?? true }

    var body: some View {
        if authMode == nil {
            WelcomeView(
                onSignIn: { authMode = false },
                onCreateAccount: { authMode = true }
            )
        } else {
            form
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("← Volver") { authMode = nil }
                    .font(.footnote)

                // Logo real de marca en vez del texto "SOCIAL" — mismo
                // asset que Android (Assets.xcassets/social_logo, copiado
                // de Android/app/.../drawable/social_logo.png).
                HStack {
                    Spacer()
                    Image("social_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 70)
                    Spacer()
                }
                Text(isSignUp ? "Crea tu cuenta" : "Inicia sesión")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                if isSignUp {
                    TextField("Nombre", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)

                SecureField("Contraseña", text: $password)
                    .textFieldStyle(.roundedBorder)

                if isSignUp {
                    DatePicker("Fecha de nacimiento", selection: $birthDate, displayedComponents: .date)
                    Text("SOCIAL es solo para mayores de 18 años.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("Acepto los términos y la política de privacidad", isOn: $acceptedTerms)
                        .font(.footnote)
                    HStack {
                        Button("Ver términos") { showTerms = true }
                        Button("Ver privacidad") { showPrivacy = true }
                    }
                    .font(.footnote)
                }

                if let error = viewModel.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if let info = viewModel.infoMessage {
                    // Hallazgo real (CI real): `.foregroundStyle(.accentColor)`
                    // busca `accentColor` como miembro estático del propio
                    // protocolo ShapeStyle (no existe) — `Color.accentColor`
                    // sí existe y sí conforma a ShapeStyle.
                    Text(info).font(.footnote).foregroundStyle(Color.accentColor)
                }

                Button {
                    Task {
                        if isSignUp {
                            await viewModel.signUp(email: email, password: password, displayName: displayName, birthDate: birthDate)
                        } else {
                            await viewModel.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(isSignUp ? "Crear cuenta" : "Entrar").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || email.isEmpty || password.isEmpty || (isSignUp && !acceptedTerms))

                Button(isSignUp ? "¿Ya tienes cuenta? Inicia sesión" : "¿No tienes cuenta? Regístrate") {
                    authMode = !isSignUp
                }
                .font(.footnote)

                if !isSignUp {
                    // Hallazgo real: no había ningún flujo de recuperación
                    // de contraseña — un usuario que la olvida se quedaría
                    // bloqueado para siempre.
                    Button("¿Olvidaste tu contraseña?") {
                        Task { await viewModel.resetPassword(email: email) }
                    }
                    .font(.footnote)
                }
            }
            .padding()
        }
        .sheet(isPresented: $showTerms) {
            NavigationStack { TermsOfServiceView() }
        }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { PrivacyPolicyView() }
        }
    }
}

/// Pantalla de bienvenida real (equivalente de WelcomeScreen en
/// AuthScreen.kt) — logo + eslogan + las dos acciones, en vez de entrar
/// directo al formulario de seis campos.
private struct WelcomeView: View {
    let onSignIn: () -> Void
    let onCreateAccount: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("social_logo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 120)
            Text("Descubre a la gente que tienes cerca de verdad")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            Button(action: onCreateAccount) {
                Text("Crear cuenta").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Ya tengo cuenta — Iniciar sesión", action: onSignIn)
                .font(.footnote)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}
