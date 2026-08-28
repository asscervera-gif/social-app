//
//  ScreenTimeView.swift
//  Social
//
//  "Tiempo en pantalla" real ("Bienestar digital"), comparado con
//  Instagram ("Tu actividad")/TikTok (Screen Time Management)/Facebook
//  ("Tu tiempo en Facebook")/Snapchat -- ver ScreenTimeManager.swift,
//  0149_screen_time.sql. Equivalente de ScreenTimeScreen.kt.
//

import SwiftUI

@MainActor
final class ScreenTimeViewModel: ObservableObject {
    @Published var dailyMinutes: [Date: Int] = [:]
    @Published var limitMinutes: Int?
    @Published var reminderEnabled = false

    private struct LimitRow: Decodable {
        let daily_time_limit_minutes: Int?
        let daily_reminder_enabled: Bool
    }

    func load() async {
        dailyMinutes = await ScreenTimeManager.loadLastSevenDays()
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        guard let row: LimitRow = try? await SupabaseManager.shared.client
            .from("profiles")
            .select("daily_time_limit_minutes,daily_reminder_enabled")
            .eq("id", value: userID)
            .single()
            .execute()
            .value else { return }
        limitMinutes = row.daily_time_limit_minutes
        reminderEnabled = row.daily_reminder_enabled
    }

    func setLimit(_ minutes: Int?, reminderEnabled: Bool) async {
        self.limitMinutes = minutes
        self.reminderEnabled = reminderEnabled
        guard let userID = try? await SupabaseManager.shared.client.auth.session.user.id else { return }
        struct LimitUpdate: Encodable {
            let daily_time_limit_minutes: Int?
            let daily_reminder_enabled: Bool
        }
        try? await SupabaseManager.shared.client
            .from("profiles")
            .update(LimitUpdate(daily_time_limit_minutes: minutes, daily_reminder_enabled: reminderEnabled))
            .eq("id", value: userID)
            .execute()
    }
}

struct ScreenTimeView: View {
    @StateObject private var viewModel = ScreenTimeViewModel()
    @State private var limitInput = ""

    private var lastSevenDays: [Date] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Últimos 7 días reales en SOCIAL.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                let days = lastSevenDays
                let maxMinutes = max(1, days.map { viewModel.dailyMinutes[$0] ?? 0 }.max() ?? 0)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        let minutes = viewModel.dailyMinutes[day] ?? 0
                        VStack {
                            Text("\(minutes)m").font(.caption2)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                                .frame(width: 20, height: max(2, CGFloat(100 * minutes / maxMinutes)))
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 140)
                .padding(.top, 8)

                Text("Límite diario").font(.headline).padding(.top, 12)

                Toggle("Recordatorio real al superar el límite", isOn: Binding(
                    get: { viewModel.reminderEnabled },
                    set: { newValue in Task { await viewModel.setLimit(Int(limitInput), reminderEnabled: newValue) } }
                ))
                Text("Aviso local, sin bloquear el uso de la app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Minutos por día", text: $limitInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                Button("Guardar") {
                    Task { await viewModel.setLimit(Int(limitInput), reminderEnabled: viewModel.reminderEnabled) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Tiempo en pantalla")
        .task {
            await viewModel.load()
            limitInput = viewModel.limitMinutes.map { String($0) } ?? ""
        }
    }
}
