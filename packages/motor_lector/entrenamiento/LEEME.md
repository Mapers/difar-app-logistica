# Entrenamiento de las redes propias del motor

Redes chicas, entrenadas solo con datos sinteticos generados aqui (no se usa
ningun modelo de terceros). La inferencia esta escrita en C++ en `../src/`.

| Red | Datos | Entrenar | Exportar a C++ |
|---|---|---|---|
| EAN-13/UPC-A (`red_ean`) | `python gen.py 640000 ent.npz 21` | `python entrenar.py ent.npz val.npz 12 red_ean.pt` | `python exportar.py red_ean.pt ../src/red_ean_pesos.h` |
| Restauracion 1D (`red_restaurar`) | `generar_codigos 60000 1 > codigos.tsv` (escritor de zxing) y `python gen_rest.py 200000 rest.npz 31 codigos.tsv 4` | `python entrenar_rest.py rest.npz 8 red_rest.pt 4` | `python exportar_rest.py red_rest.pt ../src/red_restaurar_pesos.h` |

Requisitos: Python 3 con `torch` (CPU) y `numpy`. `calibrar.py` mide los
umbrales de confianza de la red EAN (deben dar 0 lecturas equivocadas).
