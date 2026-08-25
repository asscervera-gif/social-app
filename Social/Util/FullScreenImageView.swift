//
//  FullScreenImageView.swift
//  Social
//
//  Hallazgo real, comparado con Instagram/Twitter/WhatsApp: en ningún
//  sitio de la app (feed, chat) se podía tocar una imagen para verla a
//  tamaño completo -- solo el recorte fijo de la miniatura. Visor mínimo
//  (sin zoom/pinch, alcance deliberadamente acotado): fondo negro, imagen
//  ajustada a la pantalla, tocar en cualquier sitio para cerrar.
//  Reutilizable desde HomeView.swift y ChatView.swift. Equivalente de
//  FullScreenImageViewer.kt.
//

import SwiftUI

struct FullScreenImageView: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
        }
        .onTapGesture { onDismiss() }
    }
}
