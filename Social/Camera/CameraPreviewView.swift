//
//  CameraPreviewView.swift
//  Social
//
//  Vista previa de la cámara en vivo, usada como fondo de
//  SocialCameraView. Los marcadores UWB se dibujan encima con SwiftUI,
//  no se procesan con visión por computador: la posición viene de NearbyInteraction.
//
//  Cambiar entre cámara trasera/frontal real, comparado con
//  Snapchat/Instagram Stories/TikTok -- las tres dejan alternar de
//  cámara con un toque en su propia vista de cámara en vivo, hueco real
//  hasta ahora (siempre `.back`, sin ninguna forma de cambiarla).
//

import SwiftUI
import AVFoundation

/// Gestiona la sesión de captura de la cámara, trasera o frontal.
final class CameraController: NSObject, ObservableObject {

    let session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var statusMessage: String?
    @Published private(set) var position: AVCaptureDevice.Position = .back
    private var currentInput: AVCaptureDeviceInput?

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

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            statusMessage = position == .back ? "No se pudo acceder a la cámara trasera." : "No se pudo acceder a la cámara frontal."
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        currentInput = input
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    /// Cambiar entre cámara trasera/frontal real -- quita el input
    /// actual y añade el de la posición contraria sobre la MISMA sesión
    /// ya en marcha, sin reconstruir la vista previa. Mismo criterio
    /// real ya usado por cualquier app con cámara en vivo (Snapchat/
    /// Instagram Stories/TikTok).
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        guard let newCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: newCamera) else {
            statusMessage = newPosition == .back ? "No se pudo acceder a la cámara trasera." : "No se pudo acceder a la cámara frontal."
            return
        }
        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            currentInput = newInput
            position = newPosition
        } else if let currentInput {
            // Si por lo que sea la nueva cámara no se puede añadir, se
            // deja la sesión como estaba en vez de quedarse sin ninguna
            // cámara real activa.
            session.addInput(currentInput)
        }
        session.commitConfiguration()
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
