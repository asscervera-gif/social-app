# Checklist real de subida a App Store — qué está listo y qué no

Este documento existe para responder con precisión a "súbelo a App Store":
qué de eso ya está hecho, y qué requiere pasos que **ningún código puede
sustituir**, para no generar una falsa sensación de "ya casi está".

## Lo que SÍ está listo (código y documentación)

- [x] Proyecto completo en Swift/SwiftUI, las 7 fases del prompt original.
- [x] `project.yml` (XcodeGen) para generar un `.xcodeproj` válido sin
  arrastrar archivos a mano.
- [x] `.github/workflows/build.yml`: compila en un runner macOS de GitHub
  Actions — la única forma de verificar "compila" sin Mac propio.
- [x] Ficha de App Store (`app_store_listing.md`): nombre, descripción,
  palabras clave, categoría, clasificación de edad, texto de promoción.
- [x] Textos de permisos ya en `Info.plist`, redactados para superar la
  revisión de Apple (`app_store_permission_texts.md`).
- [x] Política de privacidad borrador (`privacy_policy_es.md`).
- [x] Checklist de seguridad (`security_checklist.md`) con la mayoría de
  puntos ya resueltos en código: RLS, rate-limiting, bloqueo real, modo
  invisible real, reintento UWB, límite de sesiones.

## Lo que falta y NO se puede resolver con más código

Cada uno de estos pasos requiere una acción humana, en un Mac, con una
cuenta real. No es una cuestión de "escribir más":

1. **Un Mac con Xcode.** Compilar, firmar y ejecutar el `.xcodeproj` en un
   simulador o dispositivo. El CI de GitHub Actions confirma que compila,
   pero no sustituye probarlo en un iPhone real.
2. **Cuenta de Apple Developer Program** (99 USD/año), a nombre tuyo o de
   tu empresa. Sin ella no se puede firmar para dispositivo real ni subir
   nada a App Store Connect.
3. **Capturas de pantalla reales** de la app corriendo — no se pueden
   generar sin la app compilada en un simulador o dispositivo (ya señalado
   en `app_store_listing.md`).
4. **Certificados y perfiles de aprovisionamiento**, gestionados desde
   Xcode con la cuenta de desarrollador ya activa.
5. **TestFlight**: subir un build, invitar testers, recoger feedback —
   requiere los 4 puntos anteriores completados primero.
6. **Revisión de Apple**: tras enviar a revisión, Apple puede tardar de
   horas a días, y puede rechazar el build por motivos que solo se ven
   probando la app real (crashes, permisos mal justificados, contenido).
   Especialmente sensible aquí: cómo se modera el contenido entre
   desconocidos y cómo se verifica la edad — ya señalado en
   `app_store_permission_texts.md`, sección "Puntos que Apple probablemente
   cuestione".
7. **Servicios reales activos**: el proyecto Supabase de producción, la
   Edge Function `duel-ai` desplegada con la clave de Anthropic, y (Fase 3)
   una cuenta real de Avaturn o MetaPerson — sin esto la app compilaría
   pero no funcionaría al usarla.

## El primer paso real, si quieres avanzar de verdad

No es "más código". Es decidir **cómo vas a conseguir acceso a un Mac**:
propio, prestado, alquilado por horas (p. ej. MacInCloud, un Mac mini de
segunda mano), o pedirle a alguien que tenga uno que ejecute
`xcodegen generate && open Social.xcodeproj` por ti la primera vez. Todo lo
que hay en este repositorio está preparado para que ese primer paso sea lo
más rápido posible en cuanto ocurra — pero tiene que ocurrir.
