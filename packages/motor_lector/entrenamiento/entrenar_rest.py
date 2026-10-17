# Red de restauracion 1D: perfil borroso (1024) -> probabilidad de barra en
# cada muestra (las barras nitidas). Convolucional con dilatacion.
import sys, time, numpy as np, torch, torch.nn as nn

CAPAS = [(1, 24, 9, 1), (24, 32, 7, 1), (32, 32, 5, 2), (32, 32, 5, 4), (32, 32, 5, 8), (32, 24, 5, 1)]


class RedRestaurar(nn.Module):
    def __init__(s):
        super().__init__()
        s.bloques = nn.ModuleList([nn.Sequential(nn.Conv1d(a, b, k, padding=d * (k // 2), dilation=d),
                                                 nn.BatchNorm1d(b), nn.ReLU()) for a, b, k, d in CAPAS])
        s.salida = nn.Conv1d(24, 1, 3, padding=1)

    def forward(s, x):
        for b in s.bloques:
            x = b(x)
        return s.salida(x)[:, 0]


def normalizar(X):
    X = X.astype(np.float32)
    m = X.mean(1, keepdims=True); d = X.std(1, keepdims=True) + 4.0
    return (X - m) / d


if __name__ == '__main__':
    d = np.load(sys.argv[1])
    n_val = 4000
    X = torch.tensor(normalizar(d['X']))[:, None]; T = torch.tensor(d['T']).float(); M = torch.tensor(d['M']).float()
    Xv, Tv, Mv = X[-n_val:], T[-n_val:], M[-n_val:]
    X, T, M = X[:-n_val], T[:-n_val], M[:-n_val]
    epocas, salida = int(sys.argv[2]), sys.argv[3]
    torch.set_num_threads(int(sys.argv[4]) if len(sys.argv) > 4 else 4)
    red = RedRestaurar()
    if len(sys.argv) > 5:  # seguir desde pesos guardados
        red.load_state_dict(torch.load(sys.argv[5]))
    opt = torch.optim.AdamW(red.parameters(), 2e-3, weight_decay=1e-4)
    pasos = epocas * (len(X) // 128)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 3e-3, total_steps=pasos)
    bce = nn.BCEWithLogitsLoss(reduction='none')
    t0 = time.time()
    for ep in range(epocas):
        red.train(); orden = torch.randperm(len(X))
        for i in range(0, len(X) - 127, 128):
            idx = orden[i:i + 128]
            x = X[idx] * (1 + 0.1 * torch.randn(len(idx), 1, 1)) + 0.03 * torch.randn(len(idx), 1, 1024)
            l = (bce(red(x), T[idx]) * M[idx]).sum() / M[idx].sum()
            opt.zero_grad(); l.backward(); opt.step(); sched.step()
        red.eval()
        with torch.no_grad():
            pr = torch.cat([red(Xv[j:j + 500]) for j in range(0, n_val, 500)]) > 0
            bien = ((pr == (Tv > 0.5)).float() * Mv).sum() / Mv.sum()
            # Perfiles enteros sin ningun error dentro de la zona del codigo.
            perfectos = (((pr != (Tv > 0.5)) & (Mv > 0)).sum(1) == 0).float().mean()
        print(f'epoca {ep+1} loss {l.item():.4f} muestras_bien {bien:.4f} perfiles_perfectos {perfectos:.3f} {time.time()-t0:.0f}s', flush=True)
        torch.save(red.state_dict(), salida)
