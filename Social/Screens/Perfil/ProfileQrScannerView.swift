//
//  ProfileQrScannerView.swift
//  Social
//
//  Escanear el código QR de otro perfil real, comparado con Snapchat
//  (Snapcode)/Instagram (Nametag)/WhatsApp -- hueco documentado a
//  propósito en la ronda anterior (ProfileQrView.swift, comentario "Solo
//  generación esta ronda, sin escáner todavía"). Cierra ese hueco con
//  AVCaptureMetadataOutput (AVFoundation nativo, mismo patrón de sesión
//  ya usado en CameraPreviewView.swift), sin ninguna dependencia nueva.
//  Solo reconoce el esquema propio "social://user/{id}" generado por
//  este mismo cliente -- cualquier otro QR se ignora en silencio, mismo
//  alcance acotado que QrScannerScreen.kt (Android).
//

import SwiftUI
import AVFoundation

final class QrScannerController: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var statusMessage: String?
    var onScanned: ((UUID) -> Void)?
    private var alreadyScanned = false

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
                        self?.statusMessage = "SOCIAL necesita acceso a la cámara para escanear un código QR."
                    }
                }
            }
        default:
            isAuthorized = false
            statusMessage = "Activa el permiso de cámara en Ajustes para escanear."
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            statusMessage = "No se pudo acceder a la cámara."
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            statusMessage = "No se pudo preparar el lector de QR."
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !alreadyScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let content = object.stringValue,
              content.hasPrefix("social://user/"),
              let profileID = UUID(uuidString: String(content.dropFirst("social://user/".count)))
        else { return }
        alreadyScanned = true
        onScanned?(profileID)
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
    }
}

struct QrScannerPreviewView: UIViewRepresentable {
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
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ProfileQrScannerView: View {
    let onScanned: (UUID) -> Void

    @StateObject private var controller = QrScannerController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if controller.isAuthorized {
                QrScannerPreviewView(session: controller.session)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    Text("Apunta a un código QR de perfil de SOCIAL")
                        .foregroundStyle(.white)
                        .padding(.bottom, 40)
                }
            } else if let message = controller.statusMessage {
                Text(message)
                    .foregroundStyle(.white)
                    .padding()
            }
            VStack {
                HStack {
                    Button {
                        controller.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .padding()
                    }
                    Spacer()
                }
                Spacer()
            }
        }
        .onAppear {
            controller.onScanned = { profileID in
                controller.stop()
                onScanned(profileID)
                dismiss()
            }
            controller.checkPermissionsAndStart()
        }
        .onDisappear {
            controller.stop()
        }
    }
}
