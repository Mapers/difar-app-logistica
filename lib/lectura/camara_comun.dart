import 'package:flutter/material.dart';

import '../core/codigos.dart';

class BotonSobreCamara extends StatelessWidget {
  const BotonSobreCamara({super.key, required this.icono, required this.tooltip, required this.onPressed});

  final IconData icono;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icono, size: 20),
      color: Colors.white,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(backgroundColor: Colors.black45),
    );
  }
}

class DialogoManual extends StatefulWidget {
  const DialogoManual({super.key});

  @override
  State<DialogoManual> createState() => _DialogoManualState();
}

class _DialogoManualState extends State<DialogoManual> {
  final _texto = TextEditingController();
  String? _aviso;

  @override
  void dispose() {
    _texto.dispose();
    super.dispose();
  }

  void _aceptar() {
    final codigo = _texto.text.trim();
    if (codigo.isEmpty) return;
    // Si parece un EAN/UPC/GTIN, se avisa una vez si el digito verificador no cuadra.
    final esGtin = RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(codigo);
    if (esGtin && !digitoGs1Valido(codigo) && _aviso == null) {
      setState(() => _aviso = 'El digito verificador no coincide. Revisa el codigo o toca Agregar otra vez.');
      return;
    }
    Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ingresar codigo'),
      content: TextField(
        controller: _texto,
        autofocus: true,
        keyboardType: TextInputType.visiblePassword,
        decoration: InputDecoration(labelText: 'Codigo', errorText: _aviso, errorMaxLines: 3),
        onChanged: (_) {
          if (_aviso != null) setState(() => _aviso = null);
        },
        onSubmitted: (_) => _aceptar(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _aceptar, child: const Text('Agregar')),
      ],
    );
  }
}
