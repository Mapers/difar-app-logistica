# DIFAR Logistica — lector rapido de codigos de barras (Flutter)

App de escaneo continuo al estilo Scandit, hecha con
[`mobile_scanner`](https://pub.dev/packages/mobile_scanner) (Google ML Kit en
Android, Apple Vision en iOS). Gratis y sin licencia por dispositivo.

## Que hace (como en el video de Scandit)

**Pantalla principal = lista (SparkScan):**
- La lista de codigos ocupa la pantalla; la camara es una **ventanita
  flotante** arriba a la derecha (boton para agrandarla/achicarla, linterna,
  zoom 1x/2x).
- **Boton redondo grande** abajo a la derecha:
  - **tocar** = lee UN codigo (cada toque cuenta, aunque sea el mismo);
  - **mantener presionado** = lee seguido mientras se mantiene.
- **Pitido + vibracion** en cada lectura (pitido nativo, sin demora; si el
  volumen multimedia esta en 0 suena por el de notificaciones).
- Con varios codigos a la vista lee **solo el apuntado** (el mas cercano al
  centro, recuadro blanco -> verde al leer); los demas salen "No escaneado".
- La fila leida se resalta arriba de la lista; sumar/restar/editar cantidad,
  deslizar para borrar. Menu: ingreso manual (valida digito GS1), compartir
  CSV, vaciar, ajustes. La lista se guarda en el telefono.
- La camara queda encendida para que el primer toque lea al instante y se
  apaga sola tras 30 s sin usar el boton.

**Conteo multiple (MatrixScan Count)** — icono de cuadricula arriba:
- Camara a pantalla completa con un **punto sobre cada codigo visible**.
- El **disparador cuenta todos los codigos a la vista de una vez** (pallet,
  estanteria, caja con varias etiquetas): pasan a verde con check y no se
  vuelven a contar. Un pitido por lote y "+N" en pantalla.
- Barra de progreso contados/a la vista, total del conteo y "Auto" para
  contar sin tocar el disparador. Usa 1920x1080 para codigos chicos.

## Por que es rapida

| Tecnica | Donde |
|---|---|
| Solo se decodifican los formatos del grupo elegido (Productos, Logistica 1D, 2D o Todos) | `lib/core/codigos.dart` |
| `DetectionSpeed.unrestricted`: analiza todos los cuadros; los repetidos los filtra la sesion | `lib/lectura/camara_comun.dart` |
| Resolucion 1280x720 (Android usa 640x480 por defecto: no alcanza para codigos chicos o lejanos); 1920x1080 en multiple | `camara_comun.dart` |
| Camara ya encendida al tocar el boton (sin esperar a que arranque) | `lib/lectura/pantalla_principal.dart` |
| Pitido nativo (ToneGenerator / AudioServices) sin demora de carga | `MainActivity.kt`, `AppDelegate.swift` |

## Correrlo

```bash
flutter pub get
flutter run                      # telefono conectado (la camara no funciona en emulador)
flutter build apk --release      # APK en build/app/outputs/flutter-apk/
flutter test
```

Android minimo: 6.0 (API 23). iOS: el permiso de camara ya esta en `Info.plist`.

## Estructura

```
lib/
  main.dart                     arranque, tema, carga de ajustes y sesion
  core/codigos.dart             grupos de formatos, nombres, digito GS1
  core/proyeccion.dart          esquinas imagen -> pantalla, codigo apuntado
  lectura/
    pantalla_principal.dart     lista + camara flotante + boton (SparkScan)
    pantalla_multi.dart         conteo multiple (MatrixScan Count)
    camara_comun.dart           configuracion de camara y widgets comunes
    pantalla_lista.dart         lista de lecturas, CSV, vaciar
    sesion_lectura.dart         lecturas, anti-repetidos, CSV, guardado
    ajustes.dart / pantalla_ajustes.dart
    aviso_lectura.dart          pitido + vibracion (canal nativo difar/pitido)
```

## Siguientes pasos posibles

- Buscar el codigo en el catalogo de DIFAR (`GET /articulos`) y mostrar
  nombre/stock al leer, con el login de la app principal.
- Si hiciera falta lo maximo (etiquetas danadas, muy lejos, muy rapido), el
  SDK comercial de Scandit tiene plugin oficial de Flutter, pero es de pago
  por dispositivo.
