# Textos de permisos para revisión de App Store

Estos son los textos ya usados en `Info.plist` (Fase 1). Apple revisa que
expliquen con claridad el uso real — están redactados para superar ese
control, evitando lenguaje genérico tipo "esta app necesita tu ubicación".

| Clave | Texto |
|---|---|
| `NSNearbyInteractionUsageDescription` | SOCIAL usa la interacción cercana para medir la distancia y dirección de las personas a tu alrededor y mostrarte su avatar en la cámara. |
| `NSBluetoothAlwaysUsageDescription` | SOCIAL usa Bluetooth para descubrir e intercambiar de forma segura la información inicial con otros dispositivos cercanos antes de medir la distancia. |
| `NSLocationWhenInUseUsageDescription` | SOCIAL usa tu ubicación para detectar si estás dentro de un evento activo (Modo Evento) y, si lo activas, para mostrarte en el mapa de "Find". |
| `NSCameraUsageDescription` | SOCIAL usa la cámara para mostrarte, en tiempo real, el avatar de las personas que tienes cerca cuando enfocas hacia ellas. |
| `NSLocalNetworkUsageDescription` | SOCIAL usa la red local para descubrir a otras personas cercanas con la app abierta, antes de medir la distancia real por UWB. |

Añadidas en una auditoría posterior de este `/loop` (esta tabla se había
quedado desactualizada respecto al `Info.plist` real): `MultipeerConnectivity`
usa Bonjour por debajo para el canal de arranque, y desde iOS 14 eso exige
`NSLocalNetworkUsageDescription` además de declarar `NSBonjourServices` con
el tipo de servicio exacto (`_social-uwb._tcp`/`_social-uwb._udp`, no es un
texto de revisión sino un array de tipos — no aplica a esta tabla de textos,
pero sí forma parte de lo que Apple audita en esta misma pantalla de permiso).
Mismo hallazgo que ya motivó añadir `NEARBY_WIFI_DEVICES` en Android.

**Corregido en una auditoría posterior**: el texto de `NSLocationWhenInUseUsageDescription`
afirmaba que la ubicación/brújula "estabilizaban el apuntado hacia las
personas cercanas" — falso: el marcador y la guía "gira a la izquierda/
derecha" solo usan el ángulo UWB relativo al dispositivo (mismo enfoque que
Android), nunca rumbo de brújula. Se encontró que `HeadingProvider` estaba
instanciado y arrancado en `SocialCameraView.swift` sin que su valor se
leyera en ningún sitio — eliminada esa instanciación inútil (consumía
batería/permiso sin aportar nada), y corregido el texto para reflejar el
uso real de la ubicación: detección de eventos activos (Modo Evento) y,
opcionalmente, el mapa "Find".

## Puntos que Apple probablemente cuestione en revisión

Anótalos para la respuesta de revisión (App Review suele preguntar por esto
en apps de encuentros con desconocidos):

1. **Cómo se modera contenido y usuarios**: describe el flujo de `reports`
   (Fase 7) y quién revisa las denuncias.
2. **Cómo se verifica la edad mínima**: SOCIAL debe pedir fecha de nacimiento
   en el registro y bloquear cuentas de menores de 18.
3. **Por qué se necesita UWB/Bluetooth "Always"**: explica que solo se usa
   mientras la app está en primer plano con la cámara activa, nunca en segundo
   plano para rastreo pasivo.
4. **Cómo funciona el bloqueo**: confirma que un usuario bloqueado deja de
   poder encontrar, enviar socials o escribir al usuario que lo bloqueó.
