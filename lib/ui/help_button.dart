import 'package:flutter/material.dart';

class HelpButton extends StatelessWidget {
  const HelpButton({super.key, required this.title, required this.text});
  final String title, text;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '$title说明',
    icon: const Icon(Icons.help_outline, size: 20),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    ),
  );
}
