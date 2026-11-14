import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ValuesScreen extends StatefulWidget {
  const ValuesScreen({super.key});

  @override
  State<ValuesScreen> createState() => _ValuesScreenState();
}

class _ValuesScreenState extends State<ValuesScreen> {
  static const Color _primaryColor = Color(0xFF2878D0);

  final TextEditingController _controller = TextEditingController();

  String _input = '';
  String _type = '';
  List<String> _values = [];

  // Same V-generation logic used in FirstScreen.
  List<String> generateVNumbers(String value) {
    value = value.trim().toUpperCase();

    if (value.length != 3 || !RegExp(r'^\d{2}V$').hasMatch(value)) {
      return [];
    }

    final base = value.substring(0, 2);

    final int a = int.parse(base[0]);
    final int b = int.parse(base[1]);

    final int cA = (a >= 5) ? a - 5 : a + 5;
    final int cB = (b >= 5) ? b - 5 : b + 5;

    final Set<String> numbers = {};

    numbers.add('$a$b');
    numbers.add('$b$a');
    numbers.add('$cA$cB');
    numbers.add('$cB$cA');
    numbers.add('$a$cB');
    numbers.add('$cB$a');
    numbers.add('$cA$b');
    numbers.add('$b$cA');

    return numbers.toList();
  }

  void _calculate(String value) {
    final input = value.trim().toUpperCase();

    String type = '';
    List<String> values = [];

    if (input == 'AP') {
      type = 'AP';
      values = List.generate(10, (i) => '$i$i');
    } else if (input == 'HP') {
      type = 'HP';
      values =
          List.generate(5, (i) {
            final first = i;
            final second = i + 5;
            return ['$first$second', '$second$first'];
          }).expand((pair) => pair).toList();
    } else if (RegExp(r'^\dE$').hasMatch(input)) {
      type = 'E';
      final digit = input[0];
      values = List.generate(10, (i) => '$i$digit');
    } else if (RegExp(r'^\dH$').hasMatch(input)) {
      type = 'H';
      final digit = input[0];
      values = List.generate(10, (i) => '$digit$i');
    } else if (RegExp(r'^\d{2}V?$').hasMatch(input)) {
      final base = input.length == 2 ? '${input}V' : input;
      type = 'V';
      values = generateVNumbers(base);
    }

    setState(() {
      _input = input;
      _type = type;
      _values = values;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isValid = _type.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        title: const Text('Values'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter Number to know its Values',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),

              TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.characters,
                keyboardType: TextInputType.text,
                maxLength: 3,
                inputFormatters: [
                  TextInputFormatter.withFunction((oldValue, newValue) {
                    final text = newValue.text.toUpperCase();

                    if (text.isEmpty ||
                        RegExp(r'^\d{0,2}V?$').hasMatch(text) ||
                        RegExp(r'^\d?[HE]?$').hasMatch(text) ||
                        RegExp(r'^[AH]P?$').hasMatch(text)) {
                      return newValue.copyWith(text: text);
                    }

                    return oldValue;
                  }),
                ],
                decoration: InputDecoration(
                  hintText: 'Example: 25, 5H, 5E, AP, HP, 25V',
                  counterText: '',
                  filled: true,
                  fillColor: Colors.white,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      setState(() {
                        _input = '';
                        _type = '';
                        _values = [];
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFD5D9E0)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: _primaryColor,
                      width: 1.5,
                    ),
                  ),
                ),
                onChanged: _calculate,
              ),

              const SizedBox(height: 20),

              if (_input.isNotEmpty)
                if (isValid)
                  _buildResult()
                else
                  const Text(
                    'Enter a valid number or type.',
                    style: TextStyle(color: Colors.red),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResult() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD5D9E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Result',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4FF),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _type,
                  style: const TextStyle(
                    color: _primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Text(
            '${_values.length} Values',
            style: const TextStyle(color: Colors.black54, fontSize: 13),
          ),

          const SizedBox(height: 12),

          Wrap(
            spacing: 10,
            runSpacing: 10,
            children:
                _values.map((value) {
                  return Container(
                    width: 65,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6F4FF),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      value,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: _primaryColor,
                      ),
                    ),
                  );
                }).toList(),
          ),

          const SizedBox(height: 16),

          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _values.join('\n')));

                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Values copied')));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy Values'),
            ),
          ),
        ],
      ),
    );
  }
}
