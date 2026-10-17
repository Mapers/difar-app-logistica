# Handoff — DIFAR Logística (lector propio)

Estado al 2026-10-17. Última versión entregada: **v0.19** (rama `claude/flutter-barcode-scanner-app-kq2z2g`, commits 9f81d3b + 3bee069).

## Qué es
App Flutter solo Android (arm64; pruebas en Samsung A54). Funciona como SparkScan + MatrixScan Count, pero con **motor propio**: zxing-cpp + OpenCV + decodificador en grises + 2 redes neuronales propias. No usa ML Kit, mobile_scanner, ni modelos o SDK de Scandit o Dynamsoft.

## Reglas
- Responder en español y de forma concisa. Proponer los cambios grandes antes de hacerlos.
- No mostrar tokens ni claves. El zip de Dynamsoft trae una clave de prueba: no copiarla, no publicarla y no subir el zip.
- No descompilar Scandit ni Dynamsoft (lo prohíbe el EULA). El material descompilado ya se borró.
- El backend `difar-order-system-backend` es solo lectura. Las pruebas reales se hacen solo en modo lectura con el usuario QA. Nunca escribir en producción.
- Nunca usar `pkill -f`: mata la propia shell.
- Si una prueba falla, no seguir con el build. Encadenar los pasos con `&&`.
- No crear PR salvo que se pida. Sin IDs de modelo en los commits.
- Un cambio por versión hasta llegar a la estable.

## Arquitectura
| Capa | Archivo | Notas |
|---|---|---|
| Cámara | `packages/motor_lector/android/.../CamaraNativaPlugin.java` | CameraX 1.6.0 con textura. El análisis va por JNI; los resultados llegan por EventChannel `difar/camara/resultados`. Guarda cuadros de diagnóstico (máx. 12, en filesDir/diagnostico) |
| Exposición | `Exposicion.java` | Exposición propia de 4 ms con ISO en lazo cerrado. Se re-aplica sola si el sensor se desvía. Fallback: AE con EV negativo |
| Motor C++ | `src/motor_lector.cpp` | Pasadas intercaladas. Aplaza cuadros movidos o borrosos (giroscopio y nitidez). Caché de verificación |
| EAN en gris | `src/ean_gris.cpp` | Ajuste de guardas, DP con checksum y `verificarEan` (-1/0/1) |
| Redes | `src/red_ean.cpp`, `src/red_restaurar.cpp` | Inferencia propia con pesos float16. Entrenamiento en `entrenamiento/` (ver LEEME.md) |
| Fusión | `lib/lectura/fusion.dart` | EAN/UPC: se acepta al instante si está verificado; si no, hace falta verlo 2 veces en 3 s. El rechazo solo se registra, no bloquea |
| Conteo | `lib/conteo/` | El rastreador sigue las cajas por valor, posición y movimiento global. Estados: correcto, sobra, noEsperado, porLeer. Lista esperada simulada |
| UI | `lib/lectura/pantalla_principal.dart` | Botón "Escanear varios" (`PantallaConteo(sinLista: true)`) y botón "Compartir registro" (comparte el log y los diagnósticos) |

## Build y pruebas
```
cd android && ./gradlew assembleRelease -Ptarget-platform=android-arm64 --offline
flutter test                      # app
# motor: MOTOR_LECTOR_SO=<so linux> ; banco: packages/motor_lector/test_nativo/banco.cpp
```
Copiar el APK a `app-version/difar-logistica-arm64.apk` y `difar-logistica-vX.YY.apk` (ignorado por git).

## Banco (escritorio)
| Prueba | Resultado |
|---|---|
| Escenas difíciles | 37/40 |
| 20 cajas en un cuadro | 20/20 |
| EAN movido | 52/120 (zxing solo: 25) |
| 1D movido | 9/15 |
| Lecturas falsas | 0 |

## Pendiente (en orden)
1. Esperar el log de v0.19 con las imágenes de diagnóstico. Prueba pedida: 5 a 10 cajas juntas en "Escanear varios", para comparar con Dynamsoft.
2. Con los recortes reales, corregir `verificarEan` (hoy rechaza códigos reales). Después ajustar el decodificador en grises y las redes. Entregar como v0.20, con un solo cambio.
3. Versión estable v1.0. Criterios:
   - 0 lecturas falsas en 30 minutos;
   - el 90% de los códigos se lee en menos de 1 s;
   - 20 cajas contadas bien 3 veces;
   - exposición de 4 ms;
   - sin cierres.
4. Antes de producción:
   - persistir el conteo en curso;
   - firma de producción;
   - forma de distribución.
5. Después:
   - endpoint real de DIFAR para la lista esperada, con el mapeo EAN↔Codigo_Art (el backend no tiene columna EAN);
   - Code 128 en el decodificador en grises;
   - cuantizar las redes a int8 si van lentas.
6. Preguntas al usuario sin responder:
   - modelos de teléfono;
   - si "automático" significa leer sin pulsar el botón.
