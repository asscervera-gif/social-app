package com.social.app.screens.home

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker

/**
 * "Find" — mapa de ubicaciones públicas, hallazgo real: en iOS era un
 * texto de relleno (ver FindLocationsViewModel.kt para el detalle
 * completo), en Android no existía ni el punto de entrada. OpenStreetMap
 * vía osmdroid en vez de Google Maps — sin API key de pago.
 */
@Composable
fun FindMapScreen(viewModel: FindLocationsViewModel = viewModel()) {
    val locations by viewModel.locations.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        // Requisito de la política de uso de tiles de OSM: identificar la
        // app con un user-agent real, no el valor por defecto.
        Configuration.getInstance().userAgentValue = context.packageName
        viewModel.load()
    }

    var mapViewRef by remember { mutableStateOf<MapView?>(null) }
    DisposableEffect(Unit) {
        onDispose { mapViewRef?.onDetach() }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AndroidView(
            factory = { ctx ->
                MapView(ctx).apply {
                    setTileSource(TileSourceFactory.MAPNIK)
                    setMultiTouchControls(true)
                    controller.setZoom(4.0)
                    controller.setCenter(GeoPoint(40.4168, -3.7038)) // Madrid, centro por defecto sin ubicación propia real.
                    mapViewRef = this
                }
            },
            update = { mapView ->
                mapView.overlays.clear()
                locations.forEach { location ->
                    val marker = Marker(mapView)
                    marker.position = GeoPoint(location.lat, location.lng)
                    marker.title = location.displayName
                    mapView.overlays.add(marker)
                }
                mapView.invalidate()
            },
            modifier = Modifier.fillMaxSize()
        )

        if (locations.isEmpty() && errorMessage == null) {
            Text(
                "Nadie ha compartido su ubicación pública todavía.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.align(Alignment.TopCenter).padding(16.dp)
            )
        }
        errorMessage?.let {
            Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.align(Alignment.TopCenter).padding(16.dp))
        }
    }
}
