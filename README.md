# DIFAR Logistica — lector rapido de codigos de barras (Flutter)

App de lectura de codigos de barras al estilo Scandit, **solo Android de 64
bits (arm64-v8a)**, con **motor de lectura propio** (`packages/motor_lector`,
C++ por FFI): **OpenCV** ubica cada codigo 1D del cuadro (con su angulo), se
recorta, se endereza y **zxing-cpp** lo decodifica, todos en paralelo; mas
preparacion de imagen por pasos para codigos dificiles
(sin luz, reflejos en botellas, bolsas arrugadas, impresion invertida,
girados, chicos). **Los pasos corren en paralelo en varios nucleos**: en cada
cuadro se prueban todos a la vez y se devuelve apenas uno lee. En un banco de
40 escenas dificiles lee 36 contra 17 de zxing solo, la mitad de tiempo que
uno tras otro (ver `packages/motor_lector/README.md`). Sin ML Kit ni otros
motores de terceros.

Los formatos sin digito de control (ITF, Code 39/93, Codabar) deben leerse
igual en 2 cuadros seguidos para contarse (`lib/lectura/fusion.dart`).

## Que hace (como en el video de Scandit)

**Pantalla principal = lista (SparkScan):**
- La lista de codigos ocupa la pantalla; la camara es una **ventanita
  flotante** arriba a la derecha (boton para agrandarla/achicarla, linterna,
  zoom 1x/2x).
- **Boton redondo grande** abajo a la derecha:
  - **tocar** = lee UN codigo, el apuntado (cada toque cuenta, aunque sea el mismo);
  - **mantener presionado** = lee seguido y **todos los codigos visibles a la
    vez** (un pitido por grupo).
- **Pitido + vibracion** en cada lectura (pitido nativo, sin demora; si el
  volumen multimedia esta en 0 suena por el de notificaciones).
- **Si no se pudo leer**, suena un **tono grave doble** (distinto al pitido)
  con **doble vibracion larga**, borde rojo en la camara y un mensaje:
  - tocaste el boton y en 3 s no leyo nada (codigo danado, borroso, lejos o
    de un formato que no esta activado en Ajustes);
  - mantuviste presionado y soltaste sin leer nada;
  - el motor encuentra un codigo pero falla su verificacion (danado).
- Con un toque y varios codigos a la vista lee **solo el apuntado** (el mas
  cercano al centro, recuadro blanco -> verde al leer); los demas salen
  "No escaneado".
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
- Disparador sin ningun codigo a la vista = sonido y vibracion de error.
- Barra de progreso contados/a la vista, total del conteo y "Auto" para
  contar sin tocar el disparador. Usa 1920x1080 para codigos chicos.

## Por que es rapida y lee mas

| Tecnica | Donde |
|---|---|
| Un cuadro a la vez; los que llegan mientras tanto se descartan (la vista nunca se atrasa) | `lib/lectura/camara_lectora.dart` |
| Motor C++ en un isolate propio; dentro, los pasos dificiles en paralelo (un hilo por paso, hasta 8) y se devuelve apenas uno lee | `camara_lectora.dart`, `packages/motor_lector/src/motor_lector.cpp` |
| Paso rapido primero (lo normal sale en ~1 ms); los dificiles ordenados segun la luz medida | `motor_lector.cpp` |
| Solo los formatos del grupo elegido (Productos, Logistica 1D, 2D o Todos) | `lib/core/codigos.dart` |
| Linterna automatica con poca luz; aviso "inclina el telefono" con reflejo fuerte | `camara_lectora.dart`, `pantalla_principal.dart` |
| Pitido nativo (ToneGenerator / AudioServices) sin demora de carga | `MainActivity.kt`, `AppDelegate.swift` |

## Correrlo

```bash
ANDROID_HOME=/ruta/sdk scripts/preparar_opencv.sh   # una vez: OpenCV minimo para arm64 (~10 min)
flutter pub get
flutter run                      # telefono conectado (la camara no funciona en emulador)
flutter build apk --release      # APK en build/app/outputs/flutter-apk/
flutter test
```

Android minimo: 6.0 (API 23), solo 64 bits. Sin `preparar_opencv.sh` el motor
compila igual, sin el detector de OpenCV.

Formatos: por defecto **automatico** (todos: EAN, UPC, Code 128/39/93, ITF,
Codabar, QR, DataMatrix, PDF417, Aztec). Al disparar se enfoca el centro y,
si la imagen sigue borrosa, se vuelve a enfocar y se pide quietud.

## Estructura

```
lib/
  main.dart                     arranque, tema, carga de ajustes y sesion
  core/codigos.dart             simbologias del motor, grupos, digito GS1
  core/proyeccion.dart          esquinas imagen -> pantalla, codigo apuntado
  lectura/
    camara_lectora.dart         camara + motor propio, linterna auto, ciclo de vida
    fusion.dart                 confirma formatos sin digito de control
    pantalla_principal.dart     lista + camara flotante + boton (SparkScan)
    pantalla_multi.dart         conteo multiple (MatrixScan Count)
    pantalla_lista.dart         lista de lecturas, CSV, vaciar
    sesion_lectura.dart         lecturas, anti-repetidos, CSV, guardado
    ajustes.dart / pantalla_ajustes.dart   formatos, resolucion, linterna auto, avisos
    aviso_lectura.dart          pitido + vibracion (canal nativo difar/pitido)
packages/motor_lector/          motor C++ (zxing-cpp + preparacion) por FFI
```

## Siguientes pasos posibles

- Buscar el codigo en el catalogo de DIFAR (`GET /articulos`) y mostrar
  nombre/stock al leer, con el login de la app principal.
- Probar en telefonos reales con etiquetas reales y ajustar los pasos del
  motor con lo que no lea (el registro guarda el paso y el motor que leyo).
- iOS: el motor C++ esta enlazado en `packages/motor_lector/ios` pero falta
  compilarlo en una Mac.
