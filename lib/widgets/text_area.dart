import 'package:flutter/material.dart';

class TextArea extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int lines;

  const TextArea({
    super.key,
    required this.controller,
    this.hint = '',
    this.lines = 6,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: lines,
      style: const TextStyle(fontSize: 15, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFFC7C7CC)),
        filled: true,
        fillColor: const Color(0xFFF2F2F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.all(12),
      ),
    );
  }
}
