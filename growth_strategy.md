# Estrategia de adopción — SOCIAL

Documento de producto, no de marketing genérico. Parte de una restricción real
que cualquier estrategia honesta tiene que asumir antes de diseñar nada:
**la función diferencial (UWB) solo funciona entre dos personas físicamente
cerca, con un teléfono con chip UWB, con la app abierta.** Eso descarta de
raíz cualquier plan tipo "crecimiento viral genérico" — el producto no tiene
valor para un usuario aislado, así que la estrategia tiene que resolver el
problema de la masa crítica local antes que el de escala global.

## 1. El problema real: efecto de red con umbral físico

A diferencia de Instagram/TikTok (valor desde el primer usuario, consumiendo
contenido ajeno), SOCIAL no da nada útil hasta que **hay una segunda persona
cerca con la app instalada**. Es el mismo problema que tuvieron Tinder
(resuelto con campus universitarios) o Yo/Snapchat en sus inicios (resuelto
con institutos). La solución no es "conseguir muchos usuarios", es
**conseguir densidad en espacios físicos concretos, uno detrás de otro.**

## 2. Cuña de entrada: Modo Evento, no la app general

`EventModeViewModel`/`EventModeView` ya existen en el código — esa es la
cuña real, no una función secundaria. Un evento (concierto, festival,
congreso, fiesta universitaria) resuelve los tres requisitos de golpe:
cientos de personas en el mismo sitio, a la vez, motivadas a conocer gente
nueva. Se propone:

- **Partnership con organizadores de eventos concretos** (no "eventos" en
  abstracto): universidades, festivales de música medianos, congresos de
  tecnología — organizadores que ya buscan una "app oficial del evento" y
  para quienes SOCIAL es gratis de integrar (un QR con código de evento).
- Instalar SOCIAL se convierte en **la forma de conocer gente en ESE evento
  concreto**, no en una app social genérica más. Reduce la fricción de
  "¿por qué instalar una app social nueva?" a algo con retorno inmediato esa
  misma noche.
- Cada evento exitoso dejar una base de usuarios locales que ya se conocen
  y pueden seguir usando la app fuera del evento — de ahí sale la retención
  post-evento, no al revés.

## 3. Degradación honesta para quien no tiene chip UWB

No todos los Android/iPhone tienen chip UWB (ver `Android/README.md` y
`legal/uwb_reliability_notes.md`). Una estrategia de adopción que ignore esto
excluye a una parte real del mercado. Ya está resuelto a nivel de código
(minSdk 26 en Android, resto de la app funcional sin UWB), pero a nivel de
producto/marketing hay que ser igual de honestos: comunicar claramente "la
detección física necesita X modelos de teléfono" en vez de prometer algo que
una parte de los usuarios no podrá vivir — evita reseñas negativas de gente
frustrada por "no me detecta a nadie" cuando el problema es su hardware.

## 4. Por qué NO competir de entrada contra Instagram/TikTok/Snapchat

Competir de entrada por *tiempo de pantalla general* contra apps con equipos
de cientos de ingenieros y años de datos de recomendación no es una
estrategia realista para un producto en fase de prototipo. La ventaja real
de SOCIAL no es "otro feed", es la capa física — así que la estrategia debe
evitar posicionarse como sustituto de esas apps y posicionarse como
**complemento en el momento físico que ninguna de ellas cubre**: el "quién es
esa persona que tengo delante ahora mismo", no el consumo pasivo de
contenido. Competir ahí es jugar donde el incumbente no tiene ventaja de
datos históricos.

## 5. Requisitos de producto que la estrategia exige del código

Estos ya están parcialmente resueltos en este repo, y son condición
necesaria (no suficiente) para que la estrategia funcione — sin ellos,
cualquier campaña de adopción se estrella:

- **Fiabilidad del UWB por encima de todo** (ver el refactor de rol
  controller/controlee y sessionId compartido en `SocialProximity.kt` — un
  usuario que prueba la función estrella y no funciona no vuelve a abrir la
  app).
- **Seguridad percibida** (bloqueo real, denuncia, modo invisible real): en
  un producto que revela quién tienes físicamente cerca, la confianza es el
  requisito de adopción más alto, no una función secundaria.
- **Cero fricción en el primer uso**: abrir la app, ver gente cerca, sin
  registro largo — el valor tiene que sentirse en los primeros 30 segundos
  o el usuario se va antes de dar una segunda oportunidad.

## 6. Métrica que de verdad importa (no "usuarios totales")

Para un producto con umbral físico, la métrica de éxito temprano no es MAU
global sino **densidad efectiva por evento/campus**: porcentaje de asistentes
a un evento concreto que tienen la app abierta simultáneamente. Un evento con
200 personas y 60% de densidad genera más valor y más retención que 100.000
usuarios repartidos por el mundo sin nadie cerca de nadie — eso segundo no
sirve para nada con esta arquitectura de producto.

## Lo que este documento no puede resolver

Ninguna estrategia de producto sustituye lo que sigue pendiente y depende de
decisiones humanas: presupuesto de marketing, negociación real con
organizadores de eventos, cumplimiento legal por país (protección de datos
de ubicación/proximidad), y — para iOS — una cuenta de Apple Developer y un
Mac para poder publicar nada en absoluto (ver
`legal/app_store_submission_checklist.md`). Esto es una propuesta de
mecánica de producto, no una promesa de resultado.
