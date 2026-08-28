//
//  DevicesView.swift
//  Social
//
//  "Dispositivos conectados", comparado con Instagram ("Actividad de
//  inicio de sesión")/Facebook ("Dónde iniciaste sesión")/Snapchat
//  ("Dispositivos vinculados") -- hueco real, confirmado con grep de
//  "login_activity|active_sessions|device_sessions" sin resultados en
//  todo el repo. Sin migración nueva: device_tokens (0040) ya registra
//  un token real por dispositivo/plataforma con RLS completa
//  (select/insert/update/delete solo-propio), pero nunca se le mostraba
//  al usuario -- solo se escribía desde PushTokenManager.swift, nadie
//  lo leía. Reutilizado tal cual como registro real de "en qué
//  dispositivos tienes sesión", sin tabla nueva. Equivalente de
//  DevicesScreen.kt.
//
//  Aviso de honestidad explícito: "Cerrar sesión aquí" borra el token
//  de push real de esa fila (deja de recibir avisos push en ese
//  dispositivo), pero NO invalida de verdad el JWT de sesión de ese
//  otro dispositivo -- eso necesitaría infraestructura de revocación de
//  sesión server-side que no existe en este proyecto. Para el PROPIO
//  dispositivo actual, además se cierra la sesión real de verdad
//  (auth.signOut()).
//

import SwiftUI

struct DeviceTokenRow: Decodable, Identifiable {
    let id: UUID
    let platform: String
    let created_at: String
    let updated_at: String
    let token: String
}

@MainActor
final class DevicesViewModel: ObservableObject {
    @Published var devices: [DeviceTokenRow] = []
    @Published var errorMessage: String?

    func load() async {
        do {
            devices = try await SupabaseManager.shared.client
                .from("device_tokens")
                .select()
                .order("updated_at", ascending: false)
                .execute()
                .value
        } catch {
            errorMessage = "No se pudieron cargar tus dispositivos."
        }
    }

    func revoke(_ device: DeviceTokenRow, isCurrentDevice: Bool) async {
        devices.removeAll { $0.id == device.id }
        do {
            try await SupabaseManager.shared.client
                .from("device_tokens")
                .delete()
                .eq("id", value: device.id)
                .execute()
            if isCurrentDevice {
                try? await SupabaseManager.shared.client.auth.signOut()
            }
        } catch {
            errorMessage = "No se pudo cerrar la sesión en ese dispositivo."
        }
    }
}

struct DevicesView: View {
    @StateObject private var viewModel = DevicesViewModel()

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if viewModel.devices.isEmpty && viewModel.errorMessage == nil {
                Text("Ningún dispositivo registrado todavía.").foregroundStyle(.secondary)
            }
            ForEach(viewModel.devices) { device in
                let isCurrentDevice = PushTokenManager.currentToken != nil && device.token == PushTokenManager.currentToken
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((device.platform == "ios" ? "🍎 iOS" : "🤖 Android") + (isCurrentDevice ? " (este dispositivo)" : ""))
                        Text("Última actividad: \(device.updated_at)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isCurrentDevice ? "Cerrar sesión" : "Quitar") {
                        Task { await viewModel.revoke(device, isCurrentDevice: isCurrentDevice) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Dispositivos conectados")
        .task { await viewModel.load() }
    }
}
