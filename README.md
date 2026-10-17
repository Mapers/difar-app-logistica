# DIFAR Logistica — lector rapido de codigos de barras (Flutter)

App de escaneo continuo al estilo Scandit, hecha con
[`mobile_scanner`](https://pub.dev/packages/mobile_scanner) (Google ML Kit en
Android, Apple Vision en iOS). Gratis y sin licencia por dispositivo.

## Que hace

- **Tres modos** (selector arriba en la camara):
  - **Uno a uno**: se detiene tras cada lectura ("Leer otro" para seguir).
  - **Continuo**: un codigo a la vez dentro del recuadro, sin tocar nada.
  - **Multi** (como MatrixScan de Scandit): lee **todos los codigos visibles a
    la vez** en el mismo cuadro, los marca encima de la imagen con su cantidad
    (verde = recien contado, ambar = sumado, azul = ya contado) y cuenta cada
    uno una sola vez mientras siga a la vista. Usa 1920x1080 para que los
    codigos chicos de una estanteria o caja se lean.
- **Lectura continua**: apuntas y lee; no hay que tocar la pantalla. Pitido +
  vibracion en cada lectura (verde = nuevo, ambar = repetido sumado).
- **Conteo**: agrupa por codigo y suma cantidades. Mantener la etiqueta frente
  a la camara **no** la cuenta dos veces (espera configurable, 1.5 s por defecto).
- **Lista**: sumar/restar/editar cantidad, deslizar para borrar, vaciar y
  **compartir CSV** (separado por `;`, abre directo en Excel). La lista se
  guarda en el telefono y no se pierde al cerrar la app.
- Linterna, zoom, toque para enfocar, autozoom (Android), ingreso manual con
  validacion del digito verificador GS1 (EAN/UPC/GTIN).

## Por que es rapida

| Tecnica | Donde |
|---|---|
| Solo se decodifican los formatos del grupo elegido (Productos, Logistica 1D, 2D o Todos) | `lib/core/codigos.dart` |
| Solo se analiza la ventana de lectura (`scanWindow`), no todo el cuadro | `lib/lectura/pantalla_escaner.dart` |
| `DetectionSpeed.unrestricted`: analiza todos los cuadros; los repetidos los filtra la sesion | `lib/lectura/sesion_lectura.dart` |
| Resolucion 1280x720 (Android usa 640x480 por defecto: no alcanza para codigos chicos o lejanos) | `pantalla_escaner.dart` |
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
  core/proyeccion.dart          esquinas del codigo (imagen) -> pantalla (BoxFit.cover)
  lectura/
    pantalla_escaner.dart       camara, modos, ventana, laser, marcas Multi, linterna, zoom
    sesion_lectura.dart         lista de lecturas, anti-repetidos, CSV, guardado
    ajustes.dart                preferencias (SharedPreferences)
    pantalla_ajustes.dart       pantalla de ajustes
    pantalla_lista.dart         lista, cantidades, compartir CSV
    aviso_lectura.dart          pitido + vibracion
```

## Siguientes pasos posibles

- Buscar el codigo en el catalogo de DIFAR (`GET /articulos`) y mostrar
  nombre/stock al leer, con el login de la app principal.
- Si hiciera falta lo maximo (etiquetas danadas, muy lejos, muy rapido), el
  SDK comercial de Scandit tiene plugin oficial de Flutter, pero es de pago
  por dispositivo.
