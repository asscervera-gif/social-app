# Ficha de App Store — SOCIAL

Borrador listo para pegar en App Store Connect cuando exista una cuenta de
Apple Developer y el build esté compilado. No sustituye la revisión legal
final, pero deja el trabajo de copywriting/ASO hecho.

## Nombre y subtítulo

- **Nombre** (30 car. máx): `SOCIAL`
- **Subtítulo** (30 car. máx): `Conoce gente real, cerca de ti`

## Categoría

- Principal: **Social Networking**
- Secundaria: **Lifestyle**

## Clasificación de edad

- **17+** (contenido de encuentros entre desconocidos, ubicación de terceros).
  Apple exige declarar esto explícitamente en el cuestionario de edad de
  App Store Connect — "Unrestricted Web Access" y "User-Generated Content" van
  marcados que sí.

## Descripción (4000 car. máx) — borrador

```
SOCIAL es la forma más directa de conocer gente real que tienes cerca.

Levanta el móvil, enfoca a tu alrededor, y verás el avatar 3D de las
personas cercanas — generado desde su propia selfie, no una caricatura
genérica. Toca un avatar, mira su perfil, y envíale un "social".

Si ambos aceptáis, se abre un chat con una barra de compatibilidad que
sube y baja en vivo con vuestras interacciones, un duelo de preguntas de
menos de 60 segundos generado por IA, y una actividad sugerida cuando
conectáis de verdad.

POR QUÉ SOCIAL ES DISTINTO
· No es un feed infinito: la app abre en la cámara, no en un scroll.
· No es solo geolocalización aproximada: usamos banda ultraancha (UWB)
  para saber exactamente a qué distancia y en qué dirección está alguien.
· Tu compatibilidad con otra persona no es un algoritmo oculto: la
  construís juntos, mensaje a mensaje.

SEGURIDAD PRIMERO
· Modo invisible a un toque, desde la cámara.
· Bloqueo y denuncia siempre accesibles.
· Nunca compartimos tu ubicación exacta en tiempo real con desconocidos.

Requiere iPhone 11 o superior (chip U1/U2) para la detección de
proximidad. Cámara, Bluetooth y ubicación se usan solo mientras la app
está abierta.
```

## Palabras clave (100 car., separadas por comas, sin espacios tras coma)

```
social,conocer gente,uwb,proximidad,avatar,chat,compatibilidad,cerca de ti,red social,citas
```

## Capturas de pantalla necesarias (por dispositivo: 6.7", 6.5", 5.5")

1. Cámara con marcadores flotantes + contador de densidad ("37 personas cerca de ti").
2. Ficha de perfil con avatar y botón "Enviar social".
3. Chat con la barra de compatibilidad en vivo.
4. Pantalla de duelo con una pregunta.
5. Perfil propio con las 6 subsecciones.

No se pueden generar capturas reales sin la app compilada corriendo en un
simulador o dispositivo — pendiente hasta tener acceso a Mac.

## Texto de promoción (170 car., editable sin nueva versión)

```
Enfoca, descubre, conecta. SOCIAL te muestra quién está cerca de verdad — sin scroll infinito, sin algoritmos ocultos. Prueba el radar de proximidad.
```

## Nota de privacidad para el cuestionario "App Privacy" de Apple

Basado en `privacy_policy_es.md`: declarar recogida de **Ubicación precisa**
(solo si el usuario activa ubicación pública), **Fotos** (selfie, procesada
y descartada, no almacenada), **Datos de uso** (mensajes, interacciones) y
**Identificadores** (cuenta de usuario). Ninguno se usa para publicidad de
terceros ni se vende — marcar "No se usa para rastrear".
