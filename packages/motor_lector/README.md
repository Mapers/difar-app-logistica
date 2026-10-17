# motor_lector

Motor de lectura de codigos de barras de DIFAR Logistica, en C++, llamado
desde Flutter por FFI (`lib/motor_lector.dart`, en un isolate propio).

Usa **zxing-cpp v3.1.1** (Apache 2.0, `src/zxing-cpp/`, solo el nucleo
lector) y le agrega preparacion de imagen por pasos para codigos dificiles
(`src/motor_lector.cpp`, `src/preparar.cpp`):

| Paso | Para que |
|---|---|
| rapido | zona central sin preparar (lo normal sale en ~1 ms) |
| invertido | impresion clara sobre fondo oscuro: zxing no lo prueba en 1D |
| reflejos/sombras | promedio a lo largo de las barras + normalizacion local (bolsas, botellas, sombras) |
| rotado | giro de 45 grados: zxing lee 1D solo cada 90 |
| poca luz | ecualizacion por zonas (CLAHE) |
| completo | mas esfuerzo, 2D invertido |
| ampliado | centro ampliado 2x y enfocado (chico o lejos) |

Primero el paso rapido; si no alcanza, los dificiles **en paralelo** (un
hilo por paso, segun los nucleos): el cuadro devuelve apenas uno lee y los
demas terminan solos sobre su copia de la imagen. Con `ml_configurar(1)` corren
uno tras otro, repartidos entre cuadros con un tope (`presupuesto_us`,
`ronda`). Se ordenan segun la luz medida.
Formatos sin digito de control (ITF, Code 39/93, Codabar) exigen largo minimo.

## Pruebas

```bash
# Banco con escenas sinteticas (sin luz, reflejo, invertido, bolsa, chico,
# rotado, botella curva) contra zxing solo. Necesita el repo de zxing-cpp
# completo (con escritura) para generar los codigos:
cmake -S test_nativo -B /tmp/banco -DZXING_DIR=/ruta/zxing-cpp && cmake --build /tmp/banco && /tmp/banco/banco

# Enlace FFI (Dart):
cmake -S src -B /tmp/motor -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/motor
MOTOR_LECTOR_SO=/tmp/motor/libmotor_lector.so flutter test
```

Lecturas falsas: en el telefono, pasos sobre imagen preparada devolvieron
EAN-13 equivocados que igual pasaban el digito verificador. Esos pasos exigen
3 lineas de barrido iguales (`minLineCount`) y la app pide verlos en 2
cuadros; el banco cuenta las lecturas falsas y falla si hay alguna.

Resultado del banco (PC de 4 nucleos): zxing solo 17/40, motor 35/40, 0
lecturas falsas. `BANCO_HILOS=1` para medir uno tras otro.
No leidos: 1D con ~2 px por barra y desenfocados (acercarse o zoom) y un
Code 128 largo sobre una botella muy curva (girar la botella).

iOS: `ios/Classes` enlaza a las mismas fuentes; sin compilar todavia (falta Mac).

## Validacion de OpenCV (detector de codigos 1D)

`src/detector.cpp`: `cv::barcode::BarcodeDetector` ubica cada codigo 1D del
cuadro con su angulo; cada uno se recorta, se endereza y se decodifica con
zxing por separado, en paralelo. Solo se compila con `-DML_OPENCV_DIR=...`
(define `ML_CON_OPENCV`); sin eso el motor queda como antes.

Banco en PC (4 nucleos), mismas imagenes con y sin detector:

| Escena | Sin OpenCV | Con OpenCV |
|---|---|---|
| 20 codigos EAN-13 en un cuadro 1920x1080 (girados +-10 grados) | 17/20 tras 10 cuadros (1531 ms) | **20/20 en el 1er cuadro (53 ms)** |
| 40 escenas dificiles (un codigo) | 35/40, 816 ms en total | 36/40, 816 ms en total |
| Texto y rayas sin codigos (20 cuadros) | 0 lecturas falsas | 0 lecturas falsas |

Peso del motor para Android arm64: 1,3 MB sin OpenCV; 9,6 MB con el SDK
oficial (arrastra dnn y protobuf); **4,9 MB con OpenCV compilado solo con
core, imgproc y objdetect** (sin dnn, sin codecs de imagen): +3,6 MB al APK.
