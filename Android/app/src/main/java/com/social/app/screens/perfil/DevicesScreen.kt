package com.social.app.screens.perfil

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.social.app.backend.SupabaseManager
import io.github.jan.supabase.gotrue.auth
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class DeviceTokenRow(
    val id: String,
    val platform: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
    val token: String
)

/**
 * "Dispositivos conectados", comparado con Instagram ("Actividad de
 * inicio de sesión")/Facebook ("Dónde iniciaste sesión")/Snapchat
 * ("Dispositivos vinculados") -- hueco real, confirmado con grep de
 * "login_activity|active_sessions|device_sessions" sin resultados en
 * todo el repo. Sin migración nueva: `device_tokens` (0040) ya registra
 * un token real por dispositivo/plataforma con RLS completa
 * (select/insert/update/delete solo-propio), pero nunca se le mostraba
 * al usuario -- solo se escribía desde PushTokenManager.kt, nadie lo
 * leía. Reutilizado tal cual como registro real de "en qué dispositivos
 * tienes sesión", sin tabla nueva.
 *
 * Aviso de honestidad explícito: "Cerrar sesión aquí" borra el token de
 * push real de esa fila (deja de recibir avisos push en ese
 * dispositivo), pero NO invalida de verdad el JWT de sesión de ese otro
 * dispositivo -- eso necesitaría infraestructura de revocación de
 * sesión server-side que no existe en este proyecto. Para el PROPIO
 * dispositivo actual, además se cierra la sesión real de verdad
 * (`auth.signOut()`).
 */
class DevicesViewModel : ViewModel() {
    private val _devices = MutableStateFlow<List<DeviceTokenRow>>(emptyList())
    val devices: StateFlow<List<DeviceTokenRow>> = _devices.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun load() {
        viewModelScope.launch {
            try {
                _devices.value = SupabaseManager.client.from("device_tokens")
                    .select { order("updated_at", Order.DESCENDING) }
                    .decodeList()
            } catch (e: Exception) {
                _errorMessage.value = "No se pudieron cargar tus dispositivos."
            }
        }
    }

    fun revoke(device: DeviceTokenRow, isCurrentDevice: Boolean) {
        _devices.value = _devices.value.filter { it.id != device.id }
        viewModelScope.launch {
            try {
                SupabaseManager.client.from("device_tokens").delete { filter { eq("id", device.id) } }
                if (isCurrentDevice) {
                    SupabaseManager.client.auth.signOut()
                }
            } catch (e: Exception) {
                _errorMessage.value = "No se pudo cerrar la sesión en ese dispositivo."
            }
        }
    }
}

@Composable
fun DevicesScreen(viewModel: DevicesViewModel = viewModel()) {
    val devices by viewModel.devices.collectAsState()
    val errorMessage by viewModel.errorMessage.collectAsState()
    // El token real registrado en ESTE dispositivo -- ver
    // PushTokenManager.kt.register(). Puede que todavía no exista (sin
    // credenciales de Firebase reales configuradas, ver ese archivo).
    var currentToken by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        viewModel.load()
        // Mismo patrón real ya usado en PushTokenManager.kt
        // (addOnSuccessListener, sin kotlinx-coroutines-play-services en
        // este proyecto): sin credenciales de Firebase reales
        // configuradas, esto simplemente no resuelve ningún token, sin
        // romper el resto de la pantalla (ver ese archivo).
        try {
            com.google.firebase.messaging.FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token -> currentToken = token }
        } catch (e: IllegalStateException) {
            currentToken = null
        }
    }

    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Text("Dispositivos conectados", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Estos son los dispositivos con tu sesión activa registrada.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp)
        )
        errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 12.dp)) }
        if (devices.isEmpty() && errorMessage == null) {
            Text(
                "Ningún dispositivo registrado todavía.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 16.dp)
            )
        }
        LazyColumn(modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
            items(devices, key = { it.id }) { device ->
                val isCurrentDevice = currentToken != null && device.token == currentToken
                Row(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.padding(end = 12.dp)) {
                        Text(
                            (if (device.platform == "android") "🤖 Android" else "🍎 iOS") + if (isCurrentDevice) " (este dispositivo)" else "",
                            style = MaterialTheme.typography.bodyLarge
                        )
                        Text(
                            "Última actividad: ${device.updatedAt}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    OutlinedButton(onClick = { viewModel.revoke(device, isCurrentDevice) }) {
                        Text(if (isCurrentDevice) "Cerrar sesión" else "Quitar")
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
