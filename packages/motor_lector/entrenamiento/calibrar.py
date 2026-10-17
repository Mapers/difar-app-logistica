# Mide la red con perfiles de validacion y busca umbrales (es EAN, digito
# minimo, margen) que no dejen pasar lecturas equivocadas, en los dos
# sentidos de lectura (como la app).
import sys, numpy as np, torch
from entrenar import RedEan, normalizar

PESO = np.array([1, 3] * 6 + [1])


def mejor_valida(logp, prohibida=None, digito=None):
    """logp: (N,13,10). Devuelve (puntaje, digitos) de la mejor combinacion con verificador valido."""
    N = len(logp)
    costo = np.full((N, 10), -1e30); costo[:, 0] = 0
    atras = np.zeros((N, 13, 10), np.int64)
    for i in range(13):
        lp = logp[:, i, :].copy()
        if prohibida is not None:
            mask = prohibida == i
            lp[mask, digito[mask]] = -1e30
        # nuevo[m'] = max_{m,d: (m + w d)%10 = m'} costo[m] + lp[d]
        cand = costo[:, :, None] + lp[:, None, :]  # (N, m, d)
        nm = (np.arange(10)[:, None] + PESO[i] * np.arange(10)[None, :]) % 10  # (m, d)
        nuevo = np.full((N, 10), -1e30)
        arg = np.zeros((N, 10), np.int64)
        for m2 in range(10):
            sel = nm == m2
            v = np.where(sel[None], cand, -1e30).reshape(N, -1)
            j = v.argmax(1)
            nuevo[:, m2] = v[np.arange(N), j]
            arg[:, m2] = j  # m*10 + d
        atras[:, i] = arg
        costo = nuevo
    puntaje = costo[:, 0]
    dig = np.zeros((N, 13), np.int64)
    m = np.zeros(N, np.int64)
    for i in range(12, -1, -1):
        a = atras[np.arange(N), i, m]
        dig[:, i] = a % 10
        m = a // 10
    return puntaje, dig


def evaluar(red, X):
    with torch.no_grad():
        x = torch.tensor(normalizar(X))[:, None]
        out = torch.cat([red(x[j:j + 2048]) for j in range(0, len(x), 2048)]).numpy()
    p = torch.softmax(torch.tensor(out[:, :130]).view(-1, 13, 10), 2).numpy()
    es = 1 / (1 + np.exp(-out[:, 130]))
    logp = np.log(np.maximum(p, 1e-9))
    s1, dig = mejor_valida(logp)
    minima = p[np.arange(len(p))[:, None], np.arange(13)[None], dig].min(1)
    segunda = np.full(len(p), -1e30)
    for i in range(13):
        s2, _ = mejor_valida(logp, np.full(len(p), i), dig[:, i])
        segunda = np.maximum(segunda, s2)
    return dig, es, minima, s1 - segunda


if __name__ == '__main__':
    red = RedEan(); red.load_state_dict(torch.load(sys.argv[1])); red.eval()
    filas = []
    for f in sys.argv[2:]:
        d = np.load(f)
        X, Y, P = d['X'], d['Y'], d['P']
        for sentido in (0, 1):
            Xs = X if sentido == 0 else X[:, ::-1].copy()
            dig, es, mi, mg = evaluar(red, Xs)
            ok = (dig == Y).all(1) & (P == 1)
            filas.append((ok, es, mi, mg, P, sentido))
    ok = np.concatenate([f[0] for f in filas]); es = np.concatenate([f[1] for f in filas])
    mi = np.concatenate([f[2] for f in filas]); mg = np.concatenate([f[3] for f in filas])
    P = np.concatenate([f[4] for f in filas]); sentido = np.concatenate([f[5] for f in filas])
    n_pos = int((P[sentido == 0] == 1).sum())
    print('positivos', n_pos)
    for te in (0.5, 0.8, 0.9, 0.95):
        for tm in (0.3, 0.5, 0.6, 0.8):
            for tg in (0.5, 1.0, 2.0, 3.0, 4.0):
                acepta = (es >= te) & (mi >= tm) & (mg >= tg)
                bien = (acepta & ok)
                mal = (acepta & ~ok).sum()
                # leido = algun sentido acepta y es correcto
                n_bien = len(set(np.where(bien)[0] % (len(ok) // 2)))
                if mal == 0 or (te, tm, tg) == (0.9, 0.6, 2.0):
                    print(f'es>={te} digito>={tm} margen>={tg}: correctos {bien.sum()} ({100*bien.sum()/n_pos:.1f}%) equivocados {mal}')
