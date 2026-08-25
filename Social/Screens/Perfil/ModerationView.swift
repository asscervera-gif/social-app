//
//  ModerationView.swift
//  Social
//
//  Panel de moderación real (primera pieza) — hallazgo documentado desde
//  hace muchas pasadas en LOOP_STATE.md: `reports` existía, tenía RLS, el
//  cliente ya insertaba denuncias reales, pero nadie podía leerlas nunca
//  sin entrar a la base de datos con una clave privilegiada
//  (`reports_select_admin`/`is_admin`, 0036_admin_moderation.sql, cierran
//  ese hueco del lado del servidor). Esta pantalla es solo visible para
//  quien tenga `profiles.is_admin = true` — una columna protegida por
//  trigger igual que `is_verified`, nunca autoconcedible por el cliente,
//  concedida a mano por `service_role` fuera de esta app. Equivalente de
//  ModerationScreen.kt. Sin verificación de compilador real (límite de
//  plataforma).
//

import Foundation
import SwiftUI

struct ReportEntry: Decodable, Identifiable {
    let id: UUID
    let reporter_id: UUID
    let reported_id: UUID
    let reason: String
    let details: String?
    let status: String
    let created_at: String
    let post_id: UUID?
    let comment_id: UUID?
    var reporterName: String?
    var reportedName: String?
    // Hallazgo real, comparado con Instagram/TikTok/Facebook: antes un
    // admin solo veía un texto libre editable ("Publicación {id}") sin
    // forma real de ver el contenido -- ahora se resuelve el post/
    // comentario real referenciado (0045_reports_content_reference.sql).
    var postCaption: String?
    var postMediaURL: String?
    var commentBody: String?
}

// Hallazgo real, comparado con Instagram/TikTok/Facebook, segunda mitad
// de 0043_ban_appeals.sql: hasta esta pasada un usuario baneado no tenía
// ninguna forma de apelar, y aunque la tuviera, ningún admin podía
// revisarlas -- mismo patrón que reports.
struct AppealEntry: Decodable, Identifiable {
    let id: UUID
    let profile_id: UUID
    let message: String
    let status: String
    let created_at: String
    var profileName: String?
}

@MainActor
final class ModerationViewModel: ObservableObject {
    @Published var reports: [ReportEntry] = []
    @Published var appeals: [AppealEntry] = []
    @Published var errorMessage: String?

    private func name(for userID: UUID) async -> String? {
        struct NameRow: Decodable { let display_name: String }
        let row: NameRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("display_name")
            .eq("id", value: userID)
            .single()
            .execute()
            .value
        return row?.display_name
    }

    /// Resuelve el contenido real denunciado -- si el post/comentario ya
    /// se borró (0045: `on delete set null`), simplemente no hay nada que
    /// mostrar, la denuncia en sí sigue existiendo para el historial.
    private func resolveContent(_ entry: ReportEntry) async -> ReportEntry {
        var entry = entry
        if let postID = entry.post_id {
            struct PostContentRow: Decodable {
                let caption: String?
                let media_url: String?
            }
            let post: PostContentRow? = try? await SupabaseManager.shared.client
                .from("posts")
                .select("caption,media_url")
                .eq("id", value: postID)
                .single()
                .execute()
                .value
            entry.postCaption = post?.caption
            entry.postMediaURL = post?.media_url
        }
        if let commentID = entry.comment_id {
            struct CommentContentRow: Decodable { let body: String }
            let comment: CommentContentRow? = try? await SupabaseManager.shared.client
                .from("comments")
                .select("body")
                .eq("id", value: commentID)
                .single()
                .execute()
                .value
            entry.commentBody = comment?.body
        }
        return entry
    }

    func load() async {
        do {
            // Si quien llama no es admin de verdad, `reports_select_admin`
            // simplemente devuelve cero filas — no hace falta comprobar
            // `is_admin` aquí también, RLS ya es la fuente de verdad.
            //
            // Hallazgo real: una denuncia sin resolver quién denunció a
            // quién es inútil para un moderador — `reports` tiene DOS
            // columnas que referencian `profiles` (reporter_id/
            // reported_id), mismo patrón sin join embebido/FK ambigua ya
            // usado en DuelHistoryViewModel/SocialsListViewModel. Mismo
            // fix ya construido en la versión Kotlin equivalente.
            let rows: [ReportEntry] = try await SupabaseManager.shared.client
                .from("reports")
                .select()
                .eq("status", value: "open")
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            var resolved: [ReportEntry] = []
            for var row in rows {
                row.reporterName = await name(for: row.reporter_id)
                row.reportedName = await name(for: row.reported_id)
                row = await resolveContent(row)
                resolved.append(row)
            }
            reports = resolved
        } catch {
            errorMessage = "No se pudieron cargar las denuncias."
        }
        await loadAppeals()
    }

    func setStatus(_ reportID: UUID, status: String) async {
        reports.removeAll { $0.id == reportID }
        do {
            try await SupabaseManager.shared.client
                .from("reports")
                .update(["status": status])
                .eq("id", value: reportID)
                .execute()
            AnalyticsManager.track("report_\(status)")
        } catch {
            errorMessage = "No se pudo actualizar la denuncia."
            await load()
        }
    }

    /// Hallazgo real, paridad de plataforma: `ModerationScreen.kt`
    /// (Android) ya podía banear directamente desde una denuncia hace
    /// varias pasadas (`admin_ban_user`, 0037_admin_ban.sql) -- un admin
    /// en iOS podía leer y descartar denuncias, pero no tenía ninguna
    /// acción real contra el usuario denunciado. Reutiliza el mismo
    /// `BanParams`/`.rpc()` ya verificado en `acceptAppeal`.
    func banReportedUser(_ reportID: UUID, reportedID: UUID, reason: String) async {
        do {
            try await SupabaseManager.shared.client
                .rpc("admin_ban_user", params: BanParams(p_target_id: reportedID, p_banned: true, p_until: nil, p_reason: reason))
                .execute()
            AnalyticsManager.track("user_banned")
            await setStatus(reportID, status: "reviewed")
        } catch {
            errorMessage = "No se pudo banear a este usuario."
        }
    }

    private func loadAppeals() async {
        do {
            // ban_appeals_select_admin (0043) devuelve cero filas si quien
            // llama no es admin real -- mismo criterio que reports.
            let rows: [AppealEntry] = try await SupabaseManager.shared.client
                .from("ban_appeals")
                .select()
                .eq("status", value: "open")
                .order("created_at", ascending: false)
                .limit(100)
                .execute()
                .value
            var resolved: [AppealEntry] = []
            for var row in rows {
                row.profileName = await name(for: row.profile_id)
                resolved.append(row)
            }
            appeals = resolved
        } catch {
            errorMessage = "No se pudieron cargar las apelaciones."
        }
    }

    private func setAppealStatus(_ appealID: UUID, status: String) async {
        appeals.removeAll { $0.id == appealID }
        do {
            try await SupabaseManager.shared.client
                .from("ban_appeals")
                .update(["status": status])
                .eq("id", value: appealID)
                .execute()
        } catch {
            errorMessage = "No se pudo actualizar la apelación."
            await loadAppeals()
        }
    }

    private struct BanParams: Encodable {
        let p_target_id: UUID
        let p_banned: Bool
        let p_until: String?
        let p_reason: String?
    }

    /// "Aceptar apelación": desbanea de verdad (mismo `admin_ban_user` que
    /// usaría un "Banear" desde denuncias, con `p_banned = false`) y marca
    /// la apelación como revisada -- una apelación aceptada siempre
    /// implica desbanear, no tiene sentido separarlo en dos pasos
    /// manuales. Primer uso de `.rpc()` en iOS, firma confirmada leyendo
    /// `SupabaseClient.swift`/`PostgrestClient.swift` reales en GitHub
    /// antes de escribirlo (no adivinada).
    func acceptAppeal(_ appealID: UUID, profileID: UUID) async {
        do {
            try await SupabaseManager.shared.client
                .rpc("admin_ban_user", params: BanParams(p_target_id: profileID, p_banned: false, p_until: nil, p_reason: nil))
                .execute()
            AnalyticsManager.track("appeal_accepted")
            await setAppealStatus(appealID, status: "reviewed")
        } catch {
            errorMessage = "No se pudo desbanear a este usuario."
        }
    }

    func dismissAppeal(_ appealID: UUID) async {
        await setAppealStatus(appealID, status: "dismissed")
    }
}

struct ModerationView: View {
    @StateObject private var viewModel = ModerationViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            // Hallazgo real, comparado con Instagram/TikTok/Facebook:
            // hasta esta pasada un usuario baneado no tenía ninguna forma
            // de apelar, y aunque la tuviera, ningún admin podía
            // revisarlas.
            if !viewModel.appeals.isEmpty {
                Section("Apelaciones de baneo") {
                    ForEach(viewModel.appeals) { appeal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appeal.profileName ?? "Perfil").font(.caption).foregroundStyle(.secondary)
                            Text(appeal.message).font(.subheadline)
                            HStack {
                                Button("Desbanear") {
                                    Task { await viewModel.acceptAppeal(appeal.id, profileID: appeal.profile_id) }
                                }
                                Button("Descartar") {
                                    Task { await viewModel.dismissAppeal(appeal.id) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("Denuncias") {
            if viewModel.reports.isEmpty {
                Text("No hay denuncias abiertas.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.reports) { report in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(report.reporterName ?? "Perfil") → \(report.reportedName ?? "Perfil")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(report.reason).font(.headline)
                    if let details = report.details {
                        Text(details).font(.subheadline)
                    }
                    // Hallazgo real, comparado con Instagram/TikTok/
                    // Facebook: antes, si la denuncia era sobre un post o
                    // un comentario concreto, no había forma real de
                    // verlo -- solo un texto libre editable por el
                    // denunciante. Ahora se muestra el contenido real, o
                    // un aviso honesto si ya se borró.
                    if report.post_id != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Publicación denunciada:").font(.caption2).foregroundStyle(.secondary)
                            if let mediaURLString = report.postMediaURL, let mediaURL = URL(string: mediaURLString) {
                                AsyncImage(url: mediaURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.15))
                                }
                                .frame(height: 120)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(report.postCaption ?? "(la publicación ya no existe)").font(.footnote)
                        }
                        .padding(.top, 4)
                    }
                    if report.comment_id != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Comentario denunciado:").font(.caption2).foregroundStyle(.secondary)
                            Text(report.commentBody ?? "(el comentario ya no existe)").font(.footnote)
                        }
                        .padding(.top, 4)
                    }
                    HStack {
                        Button("Marcar revisada") {
                            Task { await viewModel.setStatus(report.id, status: "reviewed") }
                        }
                        Button("Descartar") {
                            Task { await viewModel.setStatus(report.id, status: "dismissed") }
                        }
                        // Hallazgo real, paridad de plataforma: Android ya
                        // podía banear directamente desde una denuncia.
                        Button("Banear") {
                            Task { await viewModel.banReportedUser(report.id, reportedID: report.reported_id, reason: report.reason) }
                        }
                        .tint(.red)
                    }
                    .buttonStyle(.bordered)
                }
            }
            }
        }
        .navigationTitle("Moderación")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
