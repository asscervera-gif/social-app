//
//  FullScreenVideoView.swift
//  Social
//
//  Vídeo real en el chat (0121_video_messages.sql), comparado con
//  WhatsApp/Telegram/iMessage -- mismo criterio de visor mínimo ya usado
//  en FullScreenImageView.swift, con AVKit.VideoPlayer nativo (controles
//  incluidos) en vez de construir controles propios. Equivalente de
//  FullScreenVideoViewer.kt.
//

import SwiftUI
import AVKit

struct FullScreenVideoView: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: AVPlayer(url: url))
            Button("✕") { onDismiss() }
                .foregroundStyle(.white)
                .padding()
        }
    }
}
