# Datos para la red de restauracion 1D: perfil degradado (1024 muestras) ->
# barras nitidas en las mismas muestras. Codigos reales de varios formatos
# (codigos/codigos.tsv, generados con el escritor de zxing).
import numpy as np
from gen import corridas, relleno

L = 1024


def cargar_codigos(ruta):
    out = []
    for linea in open(ruta):
        f, t, b = linea.rstrip('\n').split('\t')
        out.append((f, t, np.frombuffer(b.encode(), np.uint8) - 48))
    return out


def muestra(rng, bits):
    F = rng.uniform(0, 1.1)
    N = len(bits)
    # Ancho en el recorte: la red ve el recorte entero llevado a 1024 muestras.
    m = float(np.exp(rng.uniform(np.log(1.6), np.log(8.0))))
    largo = N * m
    margen = largo * 0.18 + 12
    error = rng.uniform(-0.1, 0.1) * largo
    ancho = int(largo * rng.uniform(0.92, 1.12) + 2 * margen)
    inicio = (ancho - largo) / 2 + error

    k = np.arange(N + 1, dtype=np.float64)
    p = rng.uniform(-0.12, 0.12) * F
    curva = rng.uniform(-0.6, 0.6) * F * m * np.sin(np.pi * k / N)
    bordes = inicio + k * m * (1 + p * (k / N - 0.5) * 2) + curva
    ganancia = rng.uniform(-0.3, 0.3) * F * m

    paso = 0.25
    fino_x = np.arange(0, ancho, paso) + paso / 2
    valor = np.zeros_like(fino_x)
    for a, b in corridas(bits, bordes):
        valor[(fino_x >= a - ganancia / 2) & (fino_x < b + ganancia / 2)] = 1.0
    zona = m * rng.uniform(6, 14)
    relleno(rng, 0, bordes[0] - zona, m, fino_x, valor, 0, 0)
    relleno(rng, bordes[-1] + zona, ancho, m, fino_x, valor, 0, 0)

    claro = rng.uniform(110, 255)
    oscuro = rng.uniform(0, claro - 35)
    fondo_abs = valor < 0
    img = claro - (claro - oscuro) * np.clip(valor, 0, 1)
    img[fondo_abs] = -valor[fondo_abs] * 255
    if rng.random() < 0.85:
        s = rng.uniform(0, 1.6) * F * m / paso
        if s > 0.3:
            r = int(3 * s) + 1
            t = np.arange(-r, r + 1)
            g = np.exp(-0.5 * (t / s) ** 2)
            img = np.convolve(np.pad(img, r, mode="edge"), g / g.sum(), mode="valid")
    if rng.random() < 0.5:
        n = int(rng.uniform(0, 3.0) * F * m / paso)
        if n > 1:
            img = np.convolve(np.pad(img, (n // 2, n - n // 2 - 1), mode="edge"), np.ones(n) / n, mode="valid")
    n_px = len(img) // 4
    img = img[: n_px * 4].reshape(n_px, 4).mean(axis=1)
    x = np.arange(n_px)
    img *= 1 + rng.uniform(-0.25, 0.25) * (x / n_px - 0.5) + rng.uniform(0, 0.1) * np.sin(x / n_px * rng.uniform(1, 6))
    if rng.random() < 0.1:
        c = rng.uniform(0, n_px)
        img += rng.uniform(20, 80) * np.exp(-0.5 * ((x - c) / (rng.uniform(0.02, 0.08) * n_px)) ** 2)
    img += rng.normal(0, rng.uniform(0.5, 10) * max(F, 0.1), n_px)
    img = np.clip(np.round(img), 0, 255)

    # Muestras de salida (en pixeles del recorte) y el objetivo nitido en ellas.
    pos = np.linspace(0, n_px - 1, L) + 0.5
    X = np.interp(pos - 0.5, x, img).astype(np.uint8)
    idx = np.searchsorted(bordes, pos) - 1
    dentro = (idx >= 0) & (idx < N)
    T = np.zeros(L, np.uint8)
    T[dentro] = bits[idx[dentro]]
    # Se aprende el codigo y su zona blanca; lo de mas afuera no cuenta.
    M = ((pos >= bordes[0] - zona * 0.8) & (pos <= bordes[-1] + zona * 0.8)).astype(np.uint8)
    return X, T, M


def lote(semilla, n, ruta):
    rng = np.random.default_rng(semilla)
    codigos = cargar_codigos(ruta)
    X = np.zeros((n, L), np.uint8); T = np.zeros((n, L), np.uint8); M = np.zeros((n, L), np.uint8)
    for i in range(n):
        _, _, bits = codigos[rng.integers(len(codigos))]
        X[i], T[i], M[i] = muestra(rng, bits)
    return X, T, M


if __name__ == "__main__":
    import sys, time
    from multiprocessing import Pool
    total, salida, semilla, ruta = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
    t = time.time()
    with Pool(int(sys.argv[5]) if len(sys.argv) > 5 else 2) as pool:
        res = pool.starmap(lote, [(semilla * 1000 + i, total // 32, ruta) for i in range(32)])
    np.savez(salida, X=np.concatenate([r[0] for r in res]), T=np.concatenate([r[1] for r in res]),
             M=np.concatenate([r[2] for r in res]))
    print("listo", total, round(time.time() - t, 1), "s")
