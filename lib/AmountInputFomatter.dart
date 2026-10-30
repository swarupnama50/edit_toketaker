import 'package:flutter/services.dart';

class AmountInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;

    // Allow up to 5 digits, with optional I only at the end.
    if (RegExp(r'^\d{0,5}[Ii]?$').hasMatch(text)) {
      return newValue;
    }

    return oldValue;
  }
}
