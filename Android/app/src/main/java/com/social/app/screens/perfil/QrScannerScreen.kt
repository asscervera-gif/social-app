package com.social.app.screens.perfil

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer

/**
 * Escanear el código QR de otro perfil real, comparado con Snapchat
 * (Snapcode)/Instagram (Nametag)/WhatsApp -- hueco documentado a
 * propósito en la ronda anterior (renderProfileQr(), PerfilScreen.kt):
 * "Solo generación esta ronda, sin escáner todavía". Cierra ese hueco.
 *
 * Reutiliza ZXing core (ya integrado la ronda anterior para GENERAR el
 * QR de perfil, ver renderProfileQr()) ahora en modo LECTOR sobre
 * `ImageAnalysis` de CameraX (mismo patrón de cámara ya usado en
 * CameraPreview.kt) -- cero dependencias nuevas. Solo reconoce el
 * esquema propio "social://user/{id}" generado por este mismo cliente,
 * cualquier otro QR (una URL cualquiera, por ejemplo) se ignora en
 * silencio -- alcance deliberadamente acotado al ecosistema propio, sin
 * intentar ser un lector de QR genérico.
 */
@Composable
fun QrScannerScreen(onScanned: (String) -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasCameraPermission by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED)
    }
    val requestPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasCameraPermission = granted
    }
    LaunchedEffect(Unit) {
        if (!hasCameraPermission) requestPermission.launch(Manifest.permission.CAMERA)
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (hasCameraPermission) {
            var alreadyScanned by remember { mutableStateOf(false) }
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx -> PreviewView(ctx) },
                update = { previewView ->
                    val ctx = previewView.context
                    val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
                    cameraProviderFuture.addListener({
                        val cameraProvider = cameraProviderFuture.get()
                        val preview = androidx.camera.core.Preview.Builder().build().also {
                            it.setSurfaceProvider(previewView.surfaceProvider)
                        }
                        val analysis = ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                        analysis.setAnalyzer(ContextCompat.getMainExecutor(ctx)) { imageProxy ->
                            if (!alreadyScanned) {
                                val content = decodeQr(imageProxy)
                                if (content != null && content.startsWith("social://user/")) {
                                    alreadyScanned = true
                                    onScanned(content.removePrefix("social://user/"))
                                }
                            }
                            imageProxy.close()
                        }
                        try {
                            cameraProvider.unbindAll()
                            cameraProvider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                        } catch (e: Exception) {
                            // Sin cámara disponible real -- se queda en negro, sin crashear.
                        }
                    }, ContextCompat.getMainExecutor(ctx))
                }
            )
            Text(
                "Apunta a un código QR de perfil de SOCIAL",
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.align(Alignment.BottomCenter).padding(32.dp)
            )
        } else {
            Text(
                "Se necesita permiso de cámara para escanear.",
                color = Color.White,
                modifier = Modifier.align(Alignment.Center).padding(24.dp)
            )
        }
        IconButton(onClick = onClose, modifier = Modifier.align(Alignment.TopStart).padding(12.dp)) {
            Text("✕", color = Color.White, style = MaterialTheme.typography.titleLarge)
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            ProcessCameraProvider.getInstance(context).get().unbindAll()
        }
    }
}

private val qrReader = MultiFormatReader()

private fun decodeQr(imageProxy: ImageProxy): String? {
    return try {
        val plane = imageProxy.planes[0]
        val data = ByteArray(plane.buffer.remaining())
        plane.buffer.get(data)
        val source = PlanarYUVLuminanceSource(
            data, imageProxy.width, imageProxy.height,
            0, 0, imageProxy.width, imageProxy.height, false
        )
        val bitmap = BinaryBitmap(HybridBinarizer(source))
        qrReader.decode(bitmap).text
    } catch (e: NotFoundException) {
        null
    } catch (e: Exception) {
        null
    }
}
