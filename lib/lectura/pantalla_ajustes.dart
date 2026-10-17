import 'package:flutter/material.dart';

import '../core/codigos.dart';
import 'ajustes.dart';

class PantallaAjustes extends StatelessWidget {
  const PantallaAjustes({super.key, required this.ajustes});

  final Ajustes ajustes;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ajustes,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Ajustes del escaner')),
        body: ListView(
          children: [
            const _Titulo('Que codigos leer'),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Automatico reconoce cualquier tipo de codigo. Limitar formatos solo si hace falta mas velocidad.'),
            ),
            RadioGroup<GrupoFormatos>(
              groupValue: ajustes.grupo,
              onChanged: (v) {
                if (v != null) ajustes.grupo = v;
              },
              child: Column(
                children: [
                  for (final g in GrupoFormatos.values)
                    RadioListTile<GrupoFormatos>(value: g, title: Text(g.etiqueta)),
                ],
              ),
            ),
            const _Titulo('Lectura'),
            SwitchListTile(
              title: const Text('Sumar repetidos'),
              subtitle: const Text('Si un codigo vuelve a pasar, suma 1 a su cantidad.'),
              value: ajustes.sumarRepetidos,
              onChanged: (v) => ajustes.sumarRepetidos = v,
            ),
            ListTile(
              title: const Text('Espera para volver a contar el mismo codigo'),
              subtitle: Slider(
                value: ajustes.esperaMs.toDouble(),
                min: 300,
                max: 5000,
                divisions: 47,
                label: '${(ajustes.esperaMs / 1000).toStringAsFixed(1)} s',
                onChanged: (v) => ajustes.esperaMs = v.round(),
              ),
              trailing: Text('${(ajustes.esperaMs / 1000).toStringAsFixed(1)} s'),
            ),
            const _Titulo('Camara y avisos'),
            SwitchListTile(
              title: const Text('Alta resolucion (1080p)'),
              subtitle: const Text('Lee codigos chicos o lejanos al primer intento. Apagado (720p) procesa mas cuadros por segundo.'),
              value: ajustes.altaResolucion,
              onChanged: (v) => ajustes.altaResolucion = v,
            ),
            SwitchListTile(
              title: const Text('Exposicion rapida (anti movimiento)'),
              subtitle: const Text('Disparo corto (1/250 s) con sensibilidad automatica: las barras no se borronean al mover el telefono.'),
              value: ajustes.exposicionPropia,
              onChanged: (v) => ajustes.exposicionPropia = v,
            ),
            SwitchListTile(
              title: const Text('Linterna automatica'),
              subtitle: const Text('Se enciende sola cuando hay poca luz.'),
              value: ajustes.linternaAuto,
              onChanged: (v) => ajustes.linternaAuto = v,
            ),
            SwitchListTile(
              title: const Text('Pitido'),
              value: ajustes.sonido,
              onChanged: (v) => ajustes.sonido = v,
            ),
            SwitchListTile(
              title: const Text('Vibrar'),
              value: ajustes.vibrar,
              onChanged: (v) => ajustes.vibrar = v,
            ),
          ],
        ),
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(texto,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}
