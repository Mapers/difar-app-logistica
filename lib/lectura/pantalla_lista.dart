import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'sesion_lectura.dart';

final _hora = DateFormat('dd/MM HH:mm:ss');

Future<void> compartirCsv(SesionLectura sesion) async {
  final nombre = 'lectura_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';
  await SharePlus.instance.share(ShareParams(
    files: [XFile.fromData(utf8.encode(sesion.aCsv()), mimeType: 'text/csv', name: nombre)],
    fileNameOverrides: [nombre],
    subject: 'Lectura de codigos DIFAR',
  ));
}

Future<void> compartirArchivo(File archivo, String asunto) async {
  await SharePlus.instance.share(ShareParams(files: [XFile(archivo.path, mimeType: 'text/plain')], subject: asunto));
}

Future<void> confirmarVaciar(BuildContext context, SesionLectura sesion) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Vaciar la lista'),
      content: const Text('Se borran todos los codigos leidos. No se puede deshacer.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Vaciar')),
      ],
    ),
  );
  if (ok == true) sesion.vaciar();
}

/// Codigos leidos: el ultimo arriba (resaltado un momento), sumar/restar,
/// tocar para escribir la cantidad, deslizar para borrar.
class ListaLecturas extends StatelessWidget {
  const ListaLecturas({
    super.key,
    required this.sesion,
    this.resaltado,
    this.relleno = EdgeInsets.zero,
  });

  final SesionLectura sesion;

  /// Codigo recien leido, se pinta de otro color.
  final String? resaltado;

  final EdgeInsets relleno;

  Future<void> _editarCantidad(BuildContext context, ItemLeido item) async {
    final texto = TextEditingController(text: '${item.cantidad}');
    final nueva = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.codigo, style: const TextStyle(fontFamily: 'monospace')),
        content: TextField(
          controller: texto,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Cantidad'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(texto.text)),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    texto.dispose();
    if (nueva != null && nueva >= 0) sesion.cambiarCantidad(item.codigo, nueva);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sesion,
      builder: (context, _) {
        final items = sesion.items;
        if (items.isEmpty) {
          return Padding(
            padding: relleno,
            child: const Center(
              child: Text('Toca el boton para escanear.\nManten presionado para leer seguido.',
                  textAlign: TextAlign.center),
            ),
          );
        }
        final colores = Theme.of(context).colorScheme;
        return ListView.separated(
          padding: relleno,
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final item = items[i];
            return Dismissible(
              key: ValueKey(item.codigo),
              direction: DismissDirection.endToStart,
              background: Container(
                color: colores.error,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              onDismissed: (_) => sesion.eliminar(item.codigo),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                color: item.codigo == resaltado ? colores.primaryContainer : Colors.transparent,
                child: ListTile(
                  title: Text(item.codigo,
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
                  subtitle: Text('${item.formato} · ${_hora.format(item.ultimaLectura)}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Restar',
                        onPressed: () => sesion.cambiarCantidad(item.codigo, item.cantidad - 1),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('${item.cantidad}', style: Theme.of(context).textTheme.titleMedium),
                      IconButton(
                        tooltip: 'Sumar',
                        onPressed: () => sesion.cambiarCantidad(item.codigo, item.cantidad + 1),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                  onTap: () => _editarCantidad(context, item),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
