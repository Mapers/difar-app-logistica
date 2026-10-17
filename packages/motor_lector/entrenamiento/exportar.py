# Exporta la red entrenada a un encabezado C++ (pesos en float16, con la
# normalizacion por lotes ya fundida en cada convolucion).
import sys, numpy as np, torch
from entrenar import RedEan

red = RedEan()
red.load_state_dict(torch.load(sys.argv[1]))
red.eval()
tensores = []
for nombre in ['c1', 'c2', 'c3', 'c4', 'c5']:
    conv, bn = getattr(red, nombre)[0], getattr(red, nombre)[1]
    w = conv.weight.detach().numpy()  # [out][in][k]
    b = conv.bias.detach().numpy()
    f = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().numpy()
    w = w * f[:, None, None]
    b = (b - bn.running_mean.detach().numpy()) * f + bn.bias.detach().numpy()
    tensores += [(nombre + '_w', w), (nombre + '_b', b)]
tensores += [('fc1_w', red.fc1.weight.detach().numpy()), ('fc1_b', red.fc1.bias.detach().numpy()),
             ('fc2_w', red.fc2.weight.detach().numpy()), ('fc2_b', red.fc2.bias.detach().numpy())]
todo = np.concatenate([t.astype(np.float32).ravel() for _, t in tensores]).astype(np.float16)
lineas = ['// Generado por exportar.py: red EAN-13 propia (entrenada con datos sinteticos).',
          '// No editar a mano. Pesos en float16 (bits), en este orden:']
pos = 0
for n, t in tensores:
    lineas.append(f'//   {n} {list(t.shape)} desde {pos}')
    pos += t.size
lineas.append('#pragma once')
lineas.append('#include <cstdint>')
lineas.append(f'constexpr int kRedEanTotal = {pos};')
lineas.append('static const uint16_t kRedEanPesos[] = {')
bits = todo.view(np.uint16)
for i in range(0, len(bits), 24):
    lineas.append('  ' + ','.join(str(int(v)) for v in bits[i:i + 24]) + ',')
lineas.append('};')
open(sys.argv[2], 'w').write('\n'.join(lineas) + '\n')
print('pesos', pos, 'bytes', pos * 2)
