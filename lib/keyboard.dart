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
    int flex = 3,
  }) {
    return Expanded(
      flex: flex,
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
              height: 44,
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

  // Digits: wider and bigger text.
  Widget _digit(String k) => _key(k, () => onKey(k), fontSize: 21, flex: 3);

  // Side letters: narrower and smaller text.
  Widget _letter(String k) => _key(
    k,
    () => onKey(k),
    color: _letterColor,
    textColor: primaryColor,
    fontSize: 15,
    flex: 2,
  );

  Widget _spacer() => const Expanded(flex: 2, child: SizedBox());

  Widget _backspace() => _key(
    '',
    onBackspace,
    icon: Icons.backspace_outlined,
    color: _actionColor,
    flex: 2,
  );

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
            // Row 1
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        _digit('1'),
                        _digit('2'),
                        _digit('3'),
                        _letter('i'),
                      ]
                      : [
                        _spacer(),
                        _digit('1'),
                        _digit('2'),
                        _digit('3'),
                        _spacer(),
                      ],
            ),

            // Row 2
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

            // Row 3
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

            // Row 4: zero spans the 3 digit columns (3+3+3 = 9)
            Row(
              children:
                  amountMode
                      ? [
                        _spacer(),
                        _key('0', () => onKey('0'), fontSize: 21, flex: 9),
                        _backspace(),
                      ]
                      : [
                        _letter('HP'),
                        _key('0', () => onKey('0'), fontSize: 21, flex: 9),
                        _backspace(),
                      ],
            ),

            // Bottom row: SPACE = left column + zero width (2+9 = 11)
            Row(
              children: [
                _key(
                  'SPACE',
                  onSpace,
                  color: _letterColor,
                  textColor: primaryColor,
                  fontSize: 15,
                  flex: 11,
                ),
                _key(
                  '',
                  onEnter,
                  icon: Icons.keyboard_return,
                  color: primaryColor,
                  textColor: Colors.white,
                  flex: 3,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
