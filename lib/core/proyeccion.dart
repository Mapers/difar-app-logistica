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
