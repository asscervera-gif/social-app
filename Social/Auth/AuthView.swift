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
    @State private var isSignUp = true
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("SOCIAL").font(.largeTitle.bold())
                Text(isSignUp ? "Crea tu cuenta" : "Inicia sesión")
                    .font(.title3)
                    .foregroundStyle(.secondary)

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
                    Text(info).font(.footnote).foregroundStyle(.accentColor)
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
                    isSignUp.toggle()
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
