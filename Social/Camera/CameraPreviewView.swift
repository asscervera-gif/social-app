//
//  CameraPreviewView.swift
//  Social
//
//  Vista previa de la cámara trasera en vivo, usada como fondo de
//  SocialCameraView. Los marcadores UWB se dibujan encima con SwiftUI,
//  no se procesan con visión por computador: la posición viene de NearbyInteraction.
//

import SwiftUI
import AVFoundation

/// Gestiona la sesión de captura de la cámara trasera.
final class CameraController: NSObject, ObservableObject {

    let session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var statusMessage: String?

    func checkPermissionsAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.statusMessage = "SOCIAL necesita acceso a la cámara para mostrar a las personas cerca de ti."
                    }
                }
            }
        default:
            isAuthorized = false
            statusMessage = "Activa el permiso de cámara en Ajustes para usar SOCIAL."
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            statusMessage = "No se pudo acceder a la cámara trasera."
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }
}

/// Puente UIKit -> SwiftUI para mostrar el AVCaptureVideoPreviewLayer.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
