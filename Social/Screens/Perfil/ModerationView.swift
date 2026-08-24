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
    var reporterName: String?
    var reportedName: String?
}

@MainActor
final class ModerationViewModel: ObservableObject {
    @Published var reports: [ReportEntry] = []
    @Published var errorMessage: String?

    private func name(for userID: UUID) async -> String? {
        struct NameRow: Decodable { let display_name: String }
        let row: NameRow? = try? await SupabaseManager.shared.client
            .from("profiles")
            .select(columns: "display_name")
            .eq("id", value: userID)
            .single()
            .execute()
            .value
        return row?.display_name
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
                resolved.append(row)
            }
            reports = resolved
        } catch {
            errorMessage = "No se pudieron cargar las denuncias."
        }
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
}

struct ModerationView: View {
    @StateObject private var viewModel = ModerationViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
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
                    HStack {
                        Button("Marcar revisada") {
                            Task { await viewModel.setStatus(report.id, status: "reviewed") }
                        }
                        Button("Descartar") {
                            Task { await viewModel.setStatus(report.id, status: "dismissed") }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Moderación")
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
    }
}
