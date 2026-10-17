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

Resultado del banco (PC de 4 nucleos): zxing solo 17/40, motor 36/40; tiempo
total hasta leer los 36: 1090 ms uno tras otro, 503 ms en paralelo (todos en
el primer cuadro). `BANCO_HILOS=1` para medir uno tras otro.
No leidos: 1D con ~2 px por barra y desenfocados (acercarse o zoom) y un
Code 128 largo sobre una botella muy curva (girar la botella).

iOS: `ios/Classes` enlaza a las mismas fuentes; sin compilar todavia (falta Mac).
