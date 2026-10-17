import 'dart:math';
import 'dart:ui';

/// Lleva puntos de la imagen de la camara ([imagen], en pixeles) a la vista
/// que la muestra con `BoxFit.cover` ([vista]): se escala hasta cubrir y se
/// recorta lo que sobra por igual a cada lado. La app esta fija en vertical,
/// asi que no hay que girar el tamano de la imagen.
List<Offset> proyectarACubrir(List<Offset> puntos, Size imagen, Size vista) {
  if (imagen.isEmpty || vista.isEmpty) return const [];
  final escala = max(vista.width / imagen.width, vista.height / imagen.height);
  final sobraX = (imagen.width * escala - vista.width) / 2;
  final sobraY = (imagen.height * escala - vista.height) / 2;
  return [for (final p in puntos) Offset(p.dx * escala - sobraX, p.dy * escala - sobraY)];
}

Offset centroDe(List<Offset> puntos) {
  var x = 0.0;
  var y = 0.0;
  for (final p in puntos) {
    x += p.dx;
    y += p.dy;
  }
  return Offset(x / puntos.length, y / puntos.length);
}

/// "Intended scan": de varios codigos en el cuadro, el que se esta apuntando
/// es el mas cercano al centro de lo que se ve en pantalla. Los que caen fuera
/// de la vista (la imagen se recorta con `cover`) no cuentan.
/// Devuelve el indice en [esquinas], o null si ninguno se ve.
int? indiceApuntado(List<List<Offset>> esquinas, Size imagen, Size vista) {
  final medio = vista.center(Offset.zero);
  final visible = Offset.zero & vista;
  int? mejor;
  var mejorDist = double.infinity;
  for (var i = 0; i < esquinas.length; i++) {
    if (esquinas[i].isEmpty) continue;
    final puntos = proyectarACubrir(esquinas[i], imagen, vista);
    if (puntos.isEmpty) continue;
    final c = centroDe(puntos);
    if (!visible.contains(c)) continue;
    final d = (c - medio).distanceSquared;
    if (d < mejorDist) {
      mejorDist = d;
      mejor = i;
    }
  }
  return mejor;
}
