//
//  ScreenTimeManager.swift
//  Social
//
//  Tiempo en pantalla real ("Bienestar digital"), comparado con
//  Instagram ("Tu actividad")/TikTok (Screen Time Management)/Facebook
//  ("Tu tiempo en Facebook")/Snapchat -- hueco real, confirmado con grep
//  de "screen_time|time_limit|daily_limit|usage_time" sin resultados en
//  todo el repo. AnalyticsManager.track() ya registraba eventos
//  puntuales, pero nunca CUÁNTO tiempo real pasa alguien dentro de la
//  app. Equivalente de ScreenTimeManager.kt.
//
//  Alcance deliberadamente acotado: SIN bloqueo real del uso al llegar
//  al límite (eso necesitaría Screen Time/Family Controls de Apple,
//  fuera de alcance aquí) -- solo un recordatorio local real cuando
//  este mismo cliente detecta que ya se pasó el límite diario
//  configurado. Llamado desde SocialApp.swift con scenePhase
//  (.active/.background) -- una fila real de app_sessions por cada vez
//  que la app pasa a primer plano hasta que vuelve a segundo plano, ver
//  0149_screen_time.sql.
//

import Foundation
import UserNotifications

enum ScreenTimeManager {
    private static var currentSessionID: UUID?
    private static var sessionStartedAt: Date?

    static func startSession() {
        Task {
            guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
            let now = Date()
            sessionStartedAt = now
            struct NewSession: Encodable {
                let user_id: UUID
                let started_at: String
            }
            struct SessionIDRow: Decodable { let id: UUID }
            do {
                let row: SessionIDRow = try await SupabaseManager.shared.client
                    .from("app_sessions")
                    .insert(NewSession(user_id: userID, started_at: ISO8601DateFormatter().string(from: now)))
                    .select("id")
                    .single()
                    .execute()
                    .value
                currentSessionID = row.id
            } catch {
                // Sin sesión registrada real -- no debe bloquear el resto
                // de la app.
            }
        }
    }

    static func endSession() {
        guard let sessionID = currentSessionID, let startedAt = sessionStartedAt else { return }
        currentSessionID = nil
        sessionStartedAt = nil
        let durationSeconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        Task {
            struct SessionUpdate: Encodable {
                let ended_at: String
                let duration_seconds: Int
            }
            do {
                try await SupabaseManager.shared.client
                    .from("app_sessions")
                    .update(SessionUpdate(ended_at: ISO8601DateFormatter().string(from: Date()), duration_seconds: durationSeconds))
                    .eq("id", value: sessionID)
                    .execute()
                await checkDailyLimit()
            } catch {
                // No crítico.
            }
        }
    }

    private struct LimitRow: Decodable {
        let daily_time_limit_minutes: Int?
        let daily_reminder_enabled: Bool
    }

    private struct DurationRow: Decodable {
        let duration_seconds: Int?
    }

    private static func checkDailyLimit() async {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        guard let limitRow: LimitRow = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("daily_time_limit_minutes,daily_reminder_enabled")
            .eq("id", value: userID)
            .single()
            .execute()
            .value else { return }
        guard let limitMinutes = limitRow.daily_time_limit_minutes, limitRow.daily_reminder_enabled else { return }
        let todayStart = Calendar(identifier: .gregorian).startOfDay(for: Date())
        guard let todaySessions: [DurationRow] = try? await SupabaseManager.shared.client
            .from("app_sessions")
            .select("duration_seconds")
            .eq("user_id", value: userID)
            .gte("started_at", value: ISO8601DateFormatter().string(from: todayStart))
            .execute()
            .value else { return }
        let totalMinutes = todaySessions.reduce(0) { $0 + ($1.duration_seconds ?? 0) } / 60
        if totalMinutes >= limitMinutes {
            await notifyLimitReached(totalMinutes: totalMinutes)
        }
    }

    private static func notifyLimitReached(totalMinutes: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "⏱ Límite diario alcanzado"
        content.body = "Llevas \(totalMinutes) minutos reales hoy en SOCIAL."
        let request = UNNotificationRequest(identifier: "screen_time_limit", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private struct SessionDateRow: Decodable {
        let started_at: String
        let duration_seconds: Int?
    }

    /// Últimos 7 días reales, para la gráfica de barras de
    /// ScreenTimeView.swift -- un `sum(duration_seconds)` agrupado por
    /// fecha, calculado en el CLIENTE (sin función RPC nueva).
    /// Equivalente de ScreenTimeManager.kt.loadLastSevenDays().
    static func loadLastSevenDays() async -> [Date: Int] {
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return [:] }
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        let sessions: [SessionDateRow] = (try? await SupabaseManager.shared.client
            .from("app_sessions")
            .select("started_at,duration_seconds")
            .eq("user_id", value: userID)
            .gte("started_at", value: ISO8601DateFormatter().string(from: sevenDaysAgo))
            .order("started_at", ascending: true)
            .execute()
            .value) ?? []
        var result: [Date: Int] = [:]
        let calendar = Calendar(identifier: .gregorian)
        // Postgres real devuelve timestamptz con fracción de segundo
        // real (".123456+00:00") -- ISO8601DateFormatter() por defecto
        // NO la admite, hace falta .withFractionalSeconds explícito (con
        // el formateador simple como respaldo real), mismo criterio ya
        // usado en CallHistoryView.swift.
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for session in sessions {
            guard let duration = session.duration_seconds,
                  let date = fractionalFormatter.date(from: session.started_at) ?? ISO8601DateFormatter().date(from: session.started_at)
            else { continue }
            let day = calendar.startOfDay(for: date)
            result[day, default: 0] += duration / 60
        }
        return result
    }
}
