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
 * Vista previa de la cámara en vivo — equivalente Android de
 * CameraPreviewView.swift (AVFoundation). Usa CameraX porque es la API
 * moderna recomendada por Google para esto, con el mismo alcance que la
 * versión iOS: solo vista previa, sin procesar la imagen (la posición de
 * los marcadores viene del UWB, no de visión por computador).
 *
 * Cambiar entre cámara trasera/frontal real, comparado con
 * Snapchat/Instagram Stories/TikTok -- las tres dejan alternar de cámara
 * con un toque en su propia vista de cámara en vivo, hueco real hasta
 * ahora (`DEFAULT_BACK_CAMERA` estaba fijo, sin ninguna forma de
 * cambiarlo). [useFrontCamera] rebinda con el selector real correspondiente
 * cada vez que cambia -- CameraX admite volver a enlazar con un
 * `CameraSelector` distinto sobre el mismo `ProcessCameraProvider`, sin
 * reconstruir la vista.
 */
@Composable
fun CameraPreview(modifier: Modifier = Modifier, useFrontCamera: Boolean = false) {
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            PreviewView(ctx)
        },
        update = { previewView ->
            val ctx = previewView.context
            val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
            cameraProviderFuture.addListener({
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also {
                    it.setSurfaceProvider(previewView.surfaceProvider)
                }
                val selector = if (useFrontCamera) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
                try {
                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(lifecycleOwner, selector, preview)
                } catch (e: Exception) {
                    // Sin esa cámara disponible (poco común, pero posible en
                    // emuladores mal configurados): la pantalla sigue funcionando
                    // sin vista previa, los marcadores UWB no dependen de esto.
                }
            }, ContextCompat.getMainExecutor(ctx))
        }
    )
}
