package com.social.app.camera

import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat

/**
 * Vista previa de la cámara trasera en vivo — equivalente Android de
 * CameraPreviewView.swift (AVFoundation). Usa CameraX porque es la API
 * moderna recomendada por Google para esto, con el mismo alcance que la
 * versión iOS: solo vista previa, sin procesar la imagen (la posición de
 * los marcadores viene del UWB, no de visión por computador).
 */
@Composable
fun CameraPreview(modifier: Modifier = Modifier) {
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                try {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview)
                } catch (e: Exception) {
                    // Sin cámara trasera disponible (poco común, pero posible en
                    // emuladores mal configurados): la pantalla sigue funcionando
                    // sin vista previa, los marcadores UWB no dependen de esto.
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        }
    )
}
