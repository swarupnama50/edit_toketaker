import 'package:flutter/material.dart';

class NumKeyboardRules {
  NumKeyboardRules._();

  static bool isAllowed(String t) {
    return t.length <= 4 &&
        (RegExp(r'^[0-9]$').hasMatch(t) ||
            t == 'AP' ||
            t == 'HP' ||
            RegExp(r'^[0-9]{2}$').hasMatch(t) ||
            RegExp(r'^[0-9][HE]$').hasMatch(t) ||
            RegExp(r'^[0-9]{2}V$').hasMatch(t));
  }

  static String? applyKey(String current, String key) {
    final text = current.toUpperCase();

    final String? candidate =
        (key == 'AP' || key == 'HP') ? (text.isEmpty ? key : null) : text + key;

    if (candidate == null || !isAllowed(candidate)) return null;
    return candidate;
  }
}

class AmountKeyboardRules {
  AmountKeyboardRules._();

  // Same rule as AmountInputFormatter (without the trailing space).
  static String? applyKey(String current, String key) {
    final candidate = current + key.toUpperCase();
    if (RegExp(r'^[1-9]\d{0,4}I?$').hasMatch(candidate)) return candidate;
    return null;
  }
}

class AppKeyboard extends StatelessWidget {
  const AppKeyboard({
    super.key,
    required this.onKey,
    required this.onBackspace,
    required this.onSpace,
    required this.onEnter,
    this.amountMode = false,
    this.primaryColor = const Color(0xFF2878D0),
  });

  final bool amountMode;
  final ValueChanged<String> onKey;
  final VoidCallback onBackspace;
  final VoidCallback onSpace;
  final VoidCallback onEnter;
  final Color primaryColor;

  static const Color _background = Color(0xFFD5D9E0);
  static const Color _letterColor = Color(0xFFE6F4FF);
  static const Color _actionColor = Color(0xFFE3E7ED);

  Widget _key(
    String label,
    VoidCallback onTap, {
    IconData? icon,
    Color? color,
    Color? textColor,
    double fontSize = 18,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: color ?? Colors.white,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              height: 40,
              child: Center(
                child:
                    icon != null
                        ? Icon(
                          icon,
                          size: 22,
                          color: textColor ?? Colors.black87,
                        )
                        : Text(
                          label,
                          style: TextStyle(
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                            color: textColor ?? Colors.black87,
                          ),
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _digit(String k) => _key(k, () => onKey(k));

  Widget _letter(String k) =>
      _key(k, () => onKey(k), color: _letterColor, textColor: primaryColor);

  Widget _spacer() => const Expanded(child: SizedBox());

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _background,
      padding: const EdgeInsets.all(4),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Row 1: 1 2 3
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        _digit('1'),
                        _digit('2'),
                        _digit('3'),
                        _key(
                          'i',
                          () => onKey('I'),
                          color: _letterColor,
                          textColor: primaryColor,
                        ),
                      ]
                      : [
                        _spacer(),
                        _digit('1'),
                        _digit('2'),
                        _digit('3'),
                        _spacer(),
                      ],
            ),

            // Row 2: V 4 5 6 H
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        _digit('4'),
                        _digit('5'),
                        _digit('6'),
                        _spacer(),
                      ]
                      : [
                        _letter('V'),
                        _digit('4'),
                        _digit('5'),
                        _digit('6'),
                        _letter('H'),
                      ],
            ),

            // Row 3: AP 7 8 9 E
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        _digit('7'),
                        _digit('8'),
                        _digit('9'),
                        _spacer(),
                      ]
                      : [
                        _letter('AP'),
                        _digit('7'),
                        _digit('8'),
                        _digit('9'),
                        _letter('E'),
                      ],
            ),

            // Row 4: HP 0 Backspace
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        Expanded(flex: 2, child: _key('0', () => onKey('0'))),
                        _spacer(),
                        _key(
                          '',
                          onBackspace,
                          icon: Icons.backspace_outlined,
                          color: _actionColor,
                        ),
                      ]
                      : [
                        _letter('HP'),
                        Expanded(flex: 2, child: _key('0', () => onKey('0'))),
                        _key(
                          '',
                          onBackspace,
                          icon: Icons.backspace_outlined,
                          color: _actionColor,
                        ),
                      ],
            ),

            // Bottom row: SPACE ENTER
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _key(
                    'SPACE',
                    onSpace,
                    color: _letterColor,
                    textColor: primaryColor,
                    fontSize: 15,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: _key(
                    'ENTER',
                    onEnter,
                    color: primaryColor,
                    textColor: Colors.white,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
