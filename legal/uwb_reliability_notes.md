# Notas de fiabilidad del UWB — SOCIAL

Esta es la función que diferencia a SOCIAL de cualquier app basada en feed
o en geolocalización aproximada (GPS/Wi-Fi). Su credibilidad depende de que
la medición se sienta precisa y estable, no de cuántas funciones sociales
tenga alrededor. Notas técnicas para no perder eso de vista.

## Qué garantiza Apple, y qué no

- **Alcance efectivo de NearbyInteraction**: Apple documenta un rango útil
  de hasta ~9 metros en espacio abierto, con precisión de distancia del
  orden de centímetros. En interiores con paredes/obstáculos, el rango y la
  precisión caen — esto no es un bug de SOCIAL, es una limitación física del
  UWB que hay que comunicar en la UI (por eso el radio del radar en el
  prototipo se fija a 8 m, no a una cifra optimista).
- **Dirección (`object.direction`) no siempre está disponible.** Requiere
  que ambos dispositivos tengan una antena bien orientada entre sí — un
  móvil en el bolsillo o en una mochila puede dar distancia sin dirección.
  El código ya distingue esto (`isInFrame`), pero la UI debe explicarlo
  ("cerca, pero no te está apuntando con la cámara") en vez de fallar en
  silencio.
- **El chip importa más que el modelo exacto de iPhone.** No es "iPhone 11
  o superior" de forma absoluta: es "tiene chip U1 (iPhone 11-14) o U2
  (iPhone 15+)". Verificar con `NISession.deviceCapabilities` en tiempo de
  ejecución (ya implementado), nunca inferir por `UIDevice.model`.

## Qué se ha reforzado en el código de esta sesión

- **Filtro de paso bajo** (`smoothed(previous:new:)` en
  `SocialProximity.swift`) sobre distancia y ángulo — sin él, el marcador
  tiembla de forma visible por el ruido normal de la medición UWB cruda.
- **Vigilancia de datos obsoletos** (`checkForStalePeers`, cada 1s): si
  `NISession` deja de emitir actualizaciones sin invalidar la sesión
  explícitamente (ocurre en la práctica cuando el peer sale de rango sin
  perder la conexión Multipeer), el peer se marca inactivo igualmente en
  como mucho 3 segundos, en vez de quedarse "congelado" en la última
  posición conocida.
- **Filtrado de bloqueados a nivel de motor**, no solo de UI — ver
  `security_checklist.md`.

## Lo que falta validar y que SOLO se puede hacer con hardware real

Nada de lo anterior sustituye la prueba de campo. Antes de confiar en estas
cifras:

1. **Prueba de rango real** entre dos iPhone físicos, en exterior despejado
   y en interior con muebles/paredes, anotando a qué distancia deja de
   llegar la señal de forma fiable.
2. **Prueba de "bolsillo"**: confirmar que `isInFrame` se comporta como se
   espera cuando el otro teléfono está guardado, y que la guía de apuntado
   ("gira a la izquierda/derecha") sigue siendo útil en ese caso.
3. **Prueba de batería**: NearbyInteraction + Bluetooth + cámara activos a
   la vez consumen batería de forma notable; medir el drenaje real en una
   sesión de 30 minutos antes de fijar expectativas de uso continuo.
4. **Interferencia con más de 2 personas**: mitigado a nivel de código con
   `maxActiveNISessions = 8` en `SocialProximity.swift` — por encima de ese
   número, los peers nuevos entran en cola (`pendingTokens`) y se activan al
   liberarse un hueco, en vez de arrancar una `NISession` por cada persona
   detectada sin límite. El contador de densidad (`discoveredCount`) sigue
   contando a todo el mundo, medido o no. **Sigue pendiente de validar**: si
   8 es el número correcto para el hardware real, o si hace falta bajarlo
   tras medir consumo de batería en un evento con gente de verdad.

Estas cuatro pruebas son el verdadero hito de "Semana 2" mencionado en la
estimación de tiempos original — no hay forma de acortarlas con más código.
