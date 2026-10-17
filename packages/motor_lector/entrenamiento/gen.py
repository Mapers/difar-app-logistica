# Generador sintetico de perfiles de EAN-13 como los ve el motor: recorte de
# OpenCV enderezado -> promedio de las filas del centro -> 400 muestras.
# Positivos: EAN-13 entero con zona blanca; negativos: otros 1D, texto,
# rayas y EAN cortados (para que la red aprenda a decir "no es un EAN").
import numpy as np

L_SALIDA = 400
L_PATRONES = ["0001101", "0011001", "0010011", "0111101", "0100011",
              "0110001", "0101111", "0111011", "0110111", "0001011"]
PARIDAD = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
           "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]


def modulos_ean13(d):
    b = [1, 0, 1]
    for i in range(1, 7):
        l = [int(c) for c in L_PATRONES[d[i]]]
        if PARIDAD[d[0]][i - 1] == "G":
            l = [1 - x for x in l][::-1]
        b += l
    b += [0, 1, 0, 1, 0]
    for i in range(7, 13):
        b += [1 - int(c) for c in L_PATRONES[d[i]]]
    b += [1, 0, 1]
    return np.array(b, dtype=np.int8)


def ean_aleatorio(rng):
    d = list(rng.integers(0, 10, 12))
    if rng.random() < 0.3:
        d[0] = 0  # UPC-A
    if rng.random() < 0.3:
        d[0], d[1], d[2] = 7, 7, int(rng.integers(0, 10))  # Peru (775...)
    s = sum(x * (3 if i % 2 else 1) for i, x in enumerate(d))
    d.append((10 - s % 10) % 10)
    return np.array(d, dtype=np.int64)


def corridas(bits, bordes):
    """Intervalos [ini, fin) de las barras (1) segun los bordes de cada modulo."""
    out = []
    k = 0
    n = len(bits)
    while k < n:
        if bits[k] == 1:
            j = k
            while j < n and bits[j] == 1:
                j += 1
            out.append((bordes[k], bordes[j]))
            k = j
        else:
            k += 1
    return out


def relleno(rng, desde, hasta, m, fino_x, valor, oscuro, claro):
    """Cosas fuera de la zona blanca: otros codigos, texto, borde de etiqueta."""
    tipo = rng.integers(0, 4)
    if tipo == 0:
        return
    if tipo == 3:  # borde de la etiqueta: cambia el fondo
        fondo = rng.uniform(0, 255)
        valor[(fino_x >= desde) & (fino_x < hasta)] = fondo / 255.0 * -1  # marca: fondo absoluto
        return
    x = desde
    while x < hasta:
        ancho = m * (rng.uniform(0.5, 4) if tipo == 1 else rng.uniform(1, 6))
        if rng.random() < 0.5:
            sel = (fino_x >= x) & (fino_x < min(hasta, x + ancho))
            valor[sel] = rng.uniform(0.5, 1.0) if tipo == 2 else 1.0
        x += ancho * rng.uniform(1, 2.5)


FACTOR_DIFICULTAD = 1.0  # 0 = nitido (para probar el generador)


def perfil(rng, positivo=True):
    F = FACTOR_DIFICULTAD if FACTOR_DIFICULTAD >= 0 else rng.uniform(0, 1.1)
    m = float(np.exp(rng.uniform(np.log(1.6), np.log(8.0))))  # px por modulo en el recorte
    largo = 95 * m
    margen = largo * 0.18 + 12
    error = rng.uniform(-0.12, 0.12) * largo  # deteccion corrida
    ancho = int(largo * rng.uniform(0.9, 1.15) + 2 * margen)
    inicio = (ancho - largo) / 2 + error

    d = ean_aleatorio(rng)
    bits = modulos_ean13(d)
    tipo_neg = -1
    if not positivo:
        tipo_neg = int(rng.integers(0, 4))
        if tipo_neg == 0:  # otro 1D: barras de 1-4 modulos
            bits = (np.repeat(rng.integers(0, 2, 60), rng.integers(1, 5, 60))[:95]).astype(np.int8)
            if len(bits) < 95:
                bits = np.pad(bits, (0, 95 - len(bits)))
        elif tipo_neg == 1:  # EAN cortado: falta un pedazo grande
            corte = int(rng.integers(20, 75))
            if rng.random() < 0.5:
                bits[:corte] = rng.integers(0, 2, corte)
            else:
                bits[corte:] = rng.integers(0, 2, 95 - corte)
        elif tipo_neg == 2:  # rayas regulares
            p = int(rng.integers(1, 4))
            bits = (np.arange(95) // p % 2).astype(np.int8)
        else:  # texto / nada
            bits = (rng.random(95) < 0.15).astype(np.int8)

    # Bordes de modulos: perspectiva + curvatura.
    k = np.arange(96, dtype=np.float64)
    p = rng.uniform(-0.12, 0.12) * F
    escala = 1 + p * (k / 95 - 0.5) * 2
    curva = rng.uniform(-0.6, 0.6) * F * m * np.sin(np.pi * k / 95)
    bordes = inicio + np.cumsum(np.concatenate([[0], np.full(95, m)])) * 1.0
    bordes = inicio + (bordes - inicio) * escala + curva
    ganancia = rng.uniform(-0.3, 0.3) * F * m  # tinta corrida (barras mas gruesas o finas)

    paso = 0.25
    fino_x = np.arange(0, ancho, paso) + paso / 2
    valor = np.zeros_like(fino_x)  # 1 = barra
    for a, b in corridas(bits, bordes):
        valor[(fino_x >= a - ganancia / 2) & (fino_x < b + ganancia / 2)] = 1.0
    # Fuera de la zona blanca.
    zona = m * rng.uniform(5, 14)
    relleno(rng, 0, bordes[0] - zona, m, fino_x, valor, 0, 0)
    relleno(rng, bordes[-1] + zona, ancho, m, fino_x, valor, 0, 0)

    # Niveles.
    claro = rng.uniform(110, 255)
    oscuro = rng.uniform(0, claro - 35)
    fondo_abs = valor < 0
    img = claro - (claro - oscuro) * np.clip(valor, 0, 1)
    img[fondo_abs] = -valor[fondo_abs] * 255

    # Desenfoque: foco (gauss) y movimiento (caja), en la grilla fina.
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
    # Pixel: promedio de 4 muestras finas.
    n_px = len(img) // 4
    img = img[: n_px * 4].reshape(n_px, 4).mean(axis=1)
    x = np.arange(n_px)
    # Luz despareja y brillo.
    img *= 1 + rng.uniform(-0.25, 0.25) * (x / n_px - 0.5) + rng.uniform(0, 0.1) * np.sin(x / n_px * rng.uniform(1, 6))
    if rng.random() < 0.15:
        c = rng.uniform(0, n_px)
        img += rng.uniform(20, 120) * np.exp(-0.5 * ((x - c) / (rng.uniform(0.03, 0.15) * n_px)) ** 2)
    img += rng.normal(0, rng.uniform(0.5, 10) * max(F, 0.1), n_px)
    img = np.clip(np.round(img), 0, 255)
    # Al tamano fijo de la red.
    salida = np.interp(np.linspace(0, n_px - 1, L_SALIDA), x, img)
    return salida.astype(np.uint8), d, positivo


def lote(semilla, n, frac_neg=0.2, dificultad=1.0):
    global FACTOR_DIFICULTAD
    FACTOR_DIFICULTAD = dificultad
    rng = np.random.default_rng(semilla)
    X = np.zeros((n, L_SALIDA), np.uint8)
    Y = np.zeros((n, 13), np.int64)
    P = np.zeros(n, np.int64)
    for i in range(n):
        pos = rng.random() >= frac_neg
        X[i], Y[i], P[i] = perfil(rng, pos)
    return X, Y, P


if __name__ == "__main__":
    import sys
    import time
    from multiprocessing import Pool

    total = int(sys.argv[1])
    salida = sys.argv[2]
    semilla = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    t = time.time()
    partes = 32
    with Pool(4) as pool:
        res = pool.starmap(lote, [(semilla * 1000 + i, total // partes, 0.2, -1.0) for i in range(partes)])
    X = np.concatenate([r[0] for r in res])
    Y = np.concatenate([r[1] for r in res])
    P = np.concatenate([r[2] for r in res])
    np.savez(salida, X=X, Y=Y, P=P)
    print("listo", X.shape, round(time.time() - t, 1), "s")
