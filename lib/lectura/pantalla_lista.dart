import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'sesion_lectura.dart';

/// Codigos leidos en la sesion: editar cantidades, borrar y compartir en CSV.
class PantallaLista extends StatelessWidget {
  const PantallaLista({super.key, required this.sesion});

  final SesionLectura sesion;

  static final _hora = DateFormat('dd/MM HH:mm:ss');

  Future<void> _compartir(BuildContext context) async {
    final nombre = 'lectura_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.csv';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(
        utf8.encode(sesion.aCsv()),
        mimeType: 'text/csv',
        name: nombre,
      )],
      fileNameOverrides: [nombre],
      subject: 'Lectura de codigos DIFAR',
    ));
  }

  Future<void> _vaciar(BuildContext context) async {
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
        return Scaffold(
          appBar: AppBar(
            title: Text('${items.length} codigos · ${sesion.totalUnidades} u.'),
            actions: [
              IconButton(
                tooltip: 'Compartir CSV',
                onPressed: items.isEmpty ? null : () => _compartir(context),
                icon: const Icon(Icons.ios_share),
              ),
              IconButton(
                tooltip: 'Vaciar',
                onPressed: items.isEmpty ? null : () => _vaciar(context),
                icon: const Icon(Icons.delete_sweep),
              ),
            ],
          ),
          body: items.isEmpty
              ? const Center(child: Text('Todavia no hay codigos leidos.'))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return Dismissible(
                      key: ValueKey(item.codigo),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Theme.of(context).colorScheme.error,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) => sesion.eliminar(item.codigo),
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
                    );
                  },
                ),
        );
      },
    );
  }
}
