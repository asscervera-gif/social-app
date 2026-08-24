//
//  NewPostView.swift
//  Social
//
//  Compositor de publicaciones — no existía en ninguna plataforma (ver
//  NewPostViewModel para el hallazgo completo). Solo texto: sin foto/vídeo
//  porque no hay Supabase Storage real, pero `media_url` es opcional en el
//  esquema, así que esto es una publicación de verdad, no una simulación.
//  Equivalente de NewPostSheet.kt.
//

import SwiftUI
import PhotosUI

struct NewPostView: View {
    @StateObject private var viewModel = NewPostViewModel()
    @State private var caption = ""
    @State private var isSocialOnly = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    let onDismiss: () -> Void
    let onPosted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva publicación").font(.title2.bold())

            TextField("¿Qué quieres contar?", text: $caption, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            // Hallazgo real: el límite de 2200 caracteres es real
            // (posts_caption_length, 0023_text_length_limits.sql) y ya se
            // valida antes de publicar (NewPostViewModel.swift), pero
            // nada avisaba mientras se escribe — comparado con Instagram/
            // Twitter, que siempre muestran el contador restante. Mismo
            // fix ya construido en la versión Kotlin equivalente.
            Text("\(caption.count)/2200")
                .font(.caption2)
                .foregroundStyle(caption.count > 2200 ? .red : .secondary)

            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 180)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Text(imageData == nil ? "Añadir foto" : "Cambiar foto")
            }
            .buttonStyle(.bordered)
            .onChange(of: selectedPhoto) { newValue in
                Task {
                    imageData = try? await newValue?.loadTransferable(type: Data.self)
                }
            }

            Toggle("Solo visible para tus socials aceptados", isOn: $isSocialOnly)

            if let error = viewModel.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button {
                Task {
                    if await viewModel.post(caption: caption, isSocialOnly: isSocialOnly, imageData: imageData) {
                        onPosted()
                        onDismiss()
                    }
                }
            } label: {
                if viewModel.isPosting {
                    ProgressView()
                } else {
                    Text("Publicar").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isPosting)

            Spacer()
        }
        .padding()
    }
}
