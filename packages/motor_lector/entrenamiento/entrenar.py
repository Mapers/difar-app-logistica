# Red EAN-13 propia: perfil de 400 muestras -> 13 digitos + "es un EAN".
import sys, time, numpy as np, torch, torch.nn as nn

class RedEan(nn.Module):
    def __init__(s):
        super().__init__()
        def bloque(a, b, k):
            return nn.Sequential(nn.Conv1d(a, b, k, padding=k // 2), nn.BatchNorm1d(b), nn.ReLU())
        s.c1 = bloque(1, 32, 7)
        s.c2 = bloque(32, 32, 5)
        s.c3 = bloque(32, 64, 5)
        s.c4 = bloque(64, 64, 3)
        s.c5 = bloque(64, 64, 3)
        s.pool = nn.MaxPool1d(2)
        s.fc1 = nn.Linear(64 * 25, 256)
        s.fc2 = nn.Linear(256, 13 * 10 + 1)
    def forward(s, x):
        x = s.c1(x)
        x = s.pool(s.c2(x))
        x = s.pool(s.c3(x))
        x = s.pool(s.c4(x))
        x = s.pool(s.c5(x))
        x = torch.relu(s.fc1(x.flatten(1)))
        return s.fc2(x)

def normalizar(X):
    X = X.astype(np.float32)
    m = X.mean(1, keepdims=True); d = X.std(1, keepdims=True) + 4.0
    return (X - m) / d

if __name__ == '__main__':
    datos = [np.load(f) for f in sys.argv[1].split(',')]
    X = np.concatenate([d['X'] for d in datos]); Y = np.concatenate([d['Y'] for d in datos]); P = np.concatenate([d['P'] for d in datos])
    v = np.load(sys.argv[2])
    Xv, Yv, Pv = torch.tensor(normalizar(v['X']))[:, None], torch.tensor(v['Y']), torch.tensor(v['P'])
    X = torch.tensor(normalizar(X))[:, None]; Y = torch.tensor(Y); P = torch.tensor(P)
    epocas = int(sys.argv[3]); salida = sys.argv[4]
    torch.set_num_threads(4)
    red = RedEan()
    opt = torch.optim.AdamW(red.parameters(), 2e-3, weight_decay=1e-4)
    pasos = epocas * (len(X) // 256)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 3e-3, total_steps=pasos)
    ce = nn.CrossEntropyLoss(reduction='none'); bce = nn.BCEWithLogitsLoss()
    t0 = time.time()
    for ep in range(epocas):
        red.train(); orden = torch.randperm(len(X))
        for i in range(0, len(X) - 255, 256):
            idx = orden[i:i + 256]
            x = X[idx]
            # Aumentos: sentido al reves NO (la app prueba los dos); ruido y escala leves.
            x = x * (1 + 0.1 * torch.randn(len(x), 1, 1)) + 0.03 * torch.randn_like(x)
            out = red(x)
            dig = out[:, :130].view(-1, 13, 10)
            es = out[:, 130]
            p = P[idx].float()
            l_dig = (ce(dig.reshape(-1, 10), Y[idx].reshape(-1)).view(-1, 13).mean(1) * p).sum() / p.sum().clamp(min=1)
            loss = l_dig + 0.5 * bce(es, p)
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
        red.eval()
        with torch.no_grad():
            out = torch.cat([red(Xv[j:j + 1024]) for j in range(0, len(Xv), 1024)])
            pred = out[:, :130].view(-1, 13, 10).argmax(2)
            ok = (pred == Yv).all(1) & (Pv == 1)
            es = torch.sigmoid(out[:, 130])
            print(f'epoca {ep+1} loss {loss.item():.3f} exactos {ok.sum().item()}/{(Pv==1).sum().item()} '
                  f'neg>0.5 {((es>0.5)&(Pv==0)).sum().item()}/{(Pv==0).sum().item()} {time.time()-t0:.0f}s', flush=True)
        torch.save(red.state_dict(), salida)
