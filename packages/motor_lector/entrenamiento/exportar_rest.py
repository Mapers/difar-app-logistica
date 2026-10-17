# Exporta la red de restauracion a un encabezado C++ (float16, BN fundida).
import sys, numpy as np, torch
from entrenar_rest import RedRestaurar

red = RedRestaurar(); red.load_state_dict(torch.load(sys.argv[1])); red.eval()
partes = []
for b in red.bloques:
    conv, bn = b[0], b[1]
    f = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().numpy()
    w = conv.weight.detach().numpy() * f[:, None, None]
    bb = (conv.bias.detach().numpy() - bn.running_mean.detach().numpy()) * f + bn.bias.detach().numpy()
    partes += [w, bb]
partes += [red.salida.weight.detach().numpy(), red.salida.bias.detach().numpy()]
todo = np.concatenate([p.astype(np.float32).ravel() for p in partes]).astype(np.float16).view(np.uint16)
l = ['// Generado por exportar_rest.py: red de restauracion 1D propia. No editar a mano.',
     '#pragma once', '#include <cstdint>', f'constexpr int kRedRestaurarTotal = {len(todo)};',
     'static const uint16_t kRedRestaurarPesos[] = {']
for i in range(0, len(todo), 24):
    l.append('  ' + ','.join(str(int(v)) for v in todo[i:i + 24]) + ',')
l.append('};')
open(sys.argv[2], 'w').write('\n'.join(l) + '\n')
print('pesos', len(todo))
