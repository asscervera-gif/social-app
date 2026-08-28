//
//  AuthViewModel.swift
//  Social
//
//  Hallazgo real más grave de toda la sesión: no existía NINGÚN flujo de
//  registro/login en ninguna plataforma. Sin esto no hay forma de que un
//  usuario real entre en la app. Equivalente de AuthViewModel.kt.
//
//  Verificación de edad: `legal/privacy_policy_es.md` marca esto como "el
//  riesgo más grave posible" (localización precisa + desconocidos +
//  menores) y deja explícito que un checkbox no es verificación de edad
//  real. Lo que se construye aquí es la comprobación honesta que SÍ puede
//  hacerse desde el cliente sin infraestructura de terceros: fecha de
//  nacimiento real, cálculo de edad exacto, y bloqueo duro (nunca se llama
//  a signUp) si da menos de 18. Una verificación real contra documento de
//  identidad (KYC) sigue pendiente y se documenta como tal.
//

import Foundation
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?
    // Hallazgo real: si el proyecto Supabase exige confirmación de email
    // (configuración habitual por defecto), signUp no crea sesión —
    // AppRootView.swift se queda esperando en AuthView sin ningún mensaje,
    // dejando al usuario sin saber que tiene que revisar su correo.
    @Published var infoMessage: String?

    func signUp(email: String, password: String, displayName: String, birthDate: Date) async {
        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
        guard age >= 18 else {
            errorMessage = "SOCIAL es solo para mayores de 18 años."
            return
        }
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Escribe un nombre."
            return
        }
        // Mismo límite real que profiles_display_name_length
        // (0023_text_length_limits.sql) — validado aquí también para dar
        // un error claro en vez de que falle el insert del trigger
        // handle_new_user con un mensaje de Postgres críptico.
        guard displayName.count <= 50 else {
            errorMessage = "El nombre no puede tener más de 50 caracteres."
            return
        }
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            // Aviso de honestidad: `auth.signUp` en supabase-swift 2.x
            // devuelve un `AuthResponse` que distingue sesión creada de
            // confirmación pendiente (coherente con el hallazgo real ya
            // verificado con compilador en Android: `signUpWith` devuelve
            // null cuando el proyecto exige confirmación de email) — la
            // forma exacta de inspeccionar ese resultado en Swift no está
            // verificada con compilador real aquí (límite de plataforma).
            // Se asume conservadoramente que, si tras el signUp no hay
            // sesión activa, hace falta confirmar el email.
            // Hallazgo real: birthDate ya se pedía para verificar la edad
            // (arriba) pero se descartaba tras el cálculo -- ahora viaja
            // igual que display_name, y handle_new_user() (0140_birthday.sql)
            // la guarda en profiles.birth_date real.
            let birthDateFormatter = DateFormatter()
            birthDateFormatter.dateFormat = "yyyy-MM-dd"
            birthDateFormatter.timeZone = TimeZone(identifier: "UTC")
            try await SupabaseManager.shared.client.auth.signUp(
                email: email,
                password: password,
                data: [
                    "display_name": .string(displayName),
                    "birth_date": .string(birthDateFormatter.string(from: birthDate))
                ]
            )
            if (try? await SupabaseManager.shared.client.auth.session) == nil {
                infoMessage = "Te hemos enviado un email para confirmar tu cuenta. Revisa tu correo y vuelve a intentar iniciar sesión después."
            }
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: el registro es el primer paso de
            // cualquier embudo de producto y no se registraba en
            // absoluto — se marca aquí (la cuenta ya se creó de verdad,
            // con o sin confirmación de email pendiente).
            AnalyticsManager.track("signup_completed")
        } catch {
            errorMessage = "No se pudo crear la cuenta: \(error.localizedDescription)"
        }
    }

    /// Hallazgo real: no existía NINGÚN flujo de "olvidé mi contraseña" —
    /// un usuario que la olvida se quedaría bloqueado para siempre, sin
    /// forma de recuperar la cuenta desde la app. Equivalente de
    /// AuthViewModel.kt.resetPassword() — `auth.resetPasswordForEmail`
    /// verificado contra el compilador real en la versión Kotlin
    /// equivalente, mismo método documentado en supabase-swift.
    func resetPassword(email: String) async {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Escribe tu email primero."
            return
        }
        errorMessage = nil
        infoMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await SupabaseManager.shared.client.auth.resetPasswordForEmail(email)
            infoMessage = "Si existe una cuenta con ese email, te hemos enviado un enlace para restablecer tu contraseña."
        } catch {
            errorMessage = "No se pudo enviar el email de recuperación."
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await SupabaseManager.shared.client.auth.signIn(email: email, password: password)
            // Hallazgo real, mismo criterio ya aplicado en la versión
            // Kotlin equivalente: `signup_completed` se registraba, pero
            // volver a iniciar sesión — la métrica de participación
            // recurrente más básica de cualquier app — no se registraba
            // en absoluto.
            AnalyticsManager.track("signin_completed")
        } catch {
            // Hallazgo real: antes esto siempre mostraba "email o
            // contraseña incorrectos", incluso cuando la causa real era
            // que el email todavía no estaba confirmado (justo el caso
            // que signUp() ya avisa correctamente) — un usuario recién
            // registrado sin confirmar se llevaría un mensaje engañoso
            // sobre su contraseña. Heurística sobre el mensaje de error,
            // mismo criterio ya compiler-verificado en la versión Kotlin
            // equivalente, sin verificación de compilador real aquí.
            if error.localizedDescription.lowercased().contains("confirm") {
                errorMessage = "Todavía no has confirmado tu email. Revisa tu correo."
            } else {
                errorMessage = "Email o contraseña incorrectos."
            }
        }
    }
}
