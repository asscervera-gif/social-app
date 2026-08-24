package com.social.app.avatar3d

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import io.github.sceneview.node.ModelNode
import io.github.sceneview.rememberCameraNode
import io.github.sceneview.rememberEngine
import io.github.sceneview.rememberMainLightNode
import io.github.sceneview.rememberModelLoader
import io.github.sceneview.rememberNode
import io.github.sceneview.Scene

/**
 * Visor 3D real de avatares — reemplaza el círculo con gradiente de
 * PlaceholderAvatarProvider (que solo dibujaba un color, nunca un avatar
 * real) y el busto SVG plano del prototipo HTML. Usa SceneView (envoltorio
 * Compose-nativo open source sobre Google Filament, sin ningún SDK de
 * terceros de pago como Ready Player Me).
 *
 * `modelPath` es una ruta dentro de assets/models/ — apunta por defecto al
 * cuerpo base real "Superhero_Female_FullBody.gltf" de Quaternius
 * Universal Base Characters (CC0, licencia comprobada: uso comercial
 * permitido, sin atribución obligatoria). Solo hay 2 cuerpos base + 8
 * piezas de pelo/cejas/barba en `assets/models/` por ahora — el pack
 * ITHappy de ropa (20.736 combinaciones) no se ha integrado todavía, así
 * que el avatar actual va sin ropa encima del cuerpo base. Documentado
 * así en vez de fingir un catálogo de ropa que no existe aún.
 */
@Composable
fun Avatar3DViewer(modelPath: String = "models/hair_origin/Hair_Buzzed.gltf", modifier: Modifier = Modifier) {
    val engine = rememberEngine()
    val modelLoader = rememberModelLoader(engine)
    val cameraNode = rememberCameraNode(engine) {
        position = io.github.sceneview.math.Position(z = 4.0f)
    }
    // Sin luz, Filament renderiza negro puro (comprobado en el emulador:
    // el modelo cargaba de verdad, sin ningún error, pero no se veía nada
    // — la escena no tenía ninguna fuente de luz configurada).
    val mainLightNode = rememberMainLightNode(engine)

    Box(modifier = modifier.fillMaxSize()) {
        Scene(
            modifier = Modifier.fillMaxSize(),
            engine = engine,
            modelLoader = modelLoader,
            cameraNode = cameraNode,
            mainLightNode = mainLightNode,
            childNodes = listOf(
                rememberNode(engine) {
                    ModelNode(
                        modelInstance = modelLoader.createModelInstance(modelPath),
                        scaleToUnits = 2.0f
                    )
                }
            ),
            onFrame = { cameraNode.lookAt(io.github.sceneview.math.Position(0f, 0f, 0f)) }
        )
    }
}
