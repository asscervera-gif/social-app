# Política de privacidad de SOCIAL

_Borrador para revisión legal antes de publicar. No es un documento legal definitivo._

## Qué datos recogemos

- **Perfil**: nombre, intereses, secciones de perfil que decidas rellenar.
- **Avatar**: una selfie se envía al motor de generación de avatares (Avaturn o
  MetaPerson) para crear tu avatar 3D. **No almacenamos la imagen de tu cara**:
  solo se guarda el avatar 3D resultante.
- **Proximidad**: mientras usas la cámara de SOCIAL, tu dispositivo mide distancia
  y dirección a otros usuarios cercanos mediante banda ultraancha (UWB) y
  Bluetooth. Esta información es efímera: no se envía a nuestros servidores, se
  usa solo en tu dispositivo para mostrar los marcadores en pantalla.
- **Ubicación**: solo se comparte con otros usuarios si activas explícitamente
  "ubicación pública" en tu perfil. Nunca se comparte tu ubicación exacta en
  tiempo real con desconocidos.
- **Mensajes y compatibilidad**: se almacenan en nuestra base de datos
  (Supabase) para que el chat funcione entre tus dispositivos y persista en el
  tiempo.
- **Compras**: el catálogo de ropa usa StoreKit 2 de Apple; no procesamos
  datos de pago directamente.

## Con quién compartimos datos

- Con el motor de avatares (Avaturn/MetaPerson), únicamente la selfie durante
  la generación del avatar.
- Con Anthropic, las secciones de perfil relevantes para generar preguntas de
  duelo — nunca tu ubicación ni tus mensajes de chat.
- No vendemos datos personales a terceros.

## Tus controles

- **Modo invisible**: te oculta de la detección de otros usuarios en un toque,
  disponible desde la pantalla de cámara (Social) — es donde tiene efecto
  real sobre la detección física, así que es el único sitio donde se activa,
  para no dar una falsa sensación de control sin acción real detrás.
- **Bloqueo y denuncia**: disponibles desde un botón flotante visible en
  todas las pestañas salvo Social (que tiene su propio punto de entrada al
  tocar a una persona detectada), no en cada perfil o conversación
  individualmente.
- **Borrado de cuenta**: puedes solicitar el borrado completo de tu perfil,
  avatar, publicaciones, mensajes, socials y todos los datos asociados
  desde Ajustes (icono de engranaje en la pestaña Perfil). Implementado con
  una Edge Function (`delete-account`) que borra tu usuario de verdad
  (`auth.admin.deleteUser`), lo que cascada automáticamente a `profiles` y
  todo lo que depende de tu perfil — no es un borrado parcial ni solo de
  cara al usuario. Requiere confirmación de dos pasos antes de ejecutarse,
  por ser irreversible. (Corregido: este párrafo afirmaba antes que no
  existía ningún mecanismo — ya se construyó en una pasada posterior de
  esta auditoría, con Android compilado/instalado/verificado visualmente.)

## Menores de edad

**Actualizado: ya existe un flujo de registro real (`AuthScreen.kt`/
`AuthView.swift`, ambas plataformas) con una comprobación de edad dura —
se pide fecha de nacimiento real, se calcula la edad exacta, y si da menos
de 18 la cuenta **nunca se crea** (no se llama a `signUp` en ningún caso,
no es un aviso ignorable). Verificado en el emulador Android: una fecha de
nacimiento de 10 años bloquea la creación de cuenta con el error real
antes de cualquier llamada de red.

**Lo que esto NO es**: una verificación de edad robusta contra suplantación
— es autodeclarada, igual que en la inmensa mayoría de apps sociales, y
alguien podría mentir sobre su fecha de nacimiento. `legal/security_checklist.md`
sección 1 sigue señalando la combinación "localización precisa + desconocidos +
menores" como el riesgo más grave de la app. Verificación real contra
documento de identidad (KYC de un tercero) sigue sin implementar y sigue
siendo la recomendación antes de un lanzamiento público a gran escala —
esto es la comprobación honesta que sí puede hacerse desde el cliente sin
esa infraestructura de terceros, no el sustituto definitivo de ella.
