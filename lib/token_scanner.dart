import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

// =====================================================================
// DATA
// =====================================================================

/// One token line read from the image: Num + FR + SR (or TR in SR).
class ScannedRow {
  String number;
  String fr;
  String sr;

  ScannedRow({required this.number, this.fr = '', this.sr = ''});
}

// =====================================================================
// PARSER  (same rules as pasteTokenData on the main screen)
// =====================================================================

class TokenTextParser {
  TokenTextParser._();

  // WhatsApp headers such as "[30/10, 1:52 pm] Name:" are removed.
  static final RegExp _whatsappHeader = RegExp(
    r'\[\s*\d{1,2}[/.\-]\d{1,2}(?:[/.\-]\d{2,4})?,?\s*'
    r'\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?\s*\]\s*[^:\n\]]*:'
    r'|'
    r'\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4},?\s*'
    r'\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?\s*[-–]\s*[^:\n]*:',
    caseSensitive: false,
  );

  // Dates / clock times printed on receipts and chat screenshots.
  static final RegExp _dateOrTime = RegExp(
    r'\d{1,2}[/.]\d{1,2}[/.]\d{2,4}'
    r'|\d{1,2}:\d{2}:\d{2}(?:\s*[ap]\.?m\.?)?'
    r'|\d{1,2}:\d{2}\s*[ap]\.?m\.?',
    caseSensitive: false,
  );

  static final RegExp _totalLine = RegExp(
    r'^(?:total|grand\s+total)\b',
    caseSensitive: false,
  );

  // A lone "x" between spaces means "this amount box is blank"
  // (the app's own receipt and copy format use X for that).
  static final RegExp _lonelyX = RegExp(r'(^|\s)[xX](?=\s|$)');

  static final RegExp _tokenPattern = RegExp(r'\d+|[A-Za-z]+');
  static final RegExp _digitsOnly = RegExp(r'^\d+$');
  static final RegExp _allPair = RegExp(r'^A[AL]{0,3}[PF][AEI]{0,2}RS?$');
  static final RegExp _halfPair = RegExp(
    r'^(?=.*[FP])H[AEL]{0,3}F?P?[AEI]{0,2}RS?$',
  );

  /// Fixes common OCR mistakes: O -> 0 and l/I -> 1 next to digits,
  /// and table borders ("|") -> space.
  static String _fixOcr(String s) {
    return s
        .replaceAll(RegExp(r'(?<=\d)[Oo]|[Oo](?=\d)'), '0')
        .replaceAll(RegExp(r'(?<=\d)[lI](?=\d)'), '1')
        .replaceAll('|', ' ');
  }

  static List<ScannedRow> parse(String rawText, {required bool isTRMode}) {
    final text = rawText.replaceAll(_whatsappHeader, '\n');
    final result = <ScannedRow>[];

    for (final line in text.split(RegExp(r'\r?\n'))) {
      var cleaned = _fixOcr(line).replaceAll(_dateOrTime, ' ').trim();
      if (cleaned.isEmpty) continue;
      if (_totalLine.hasMatch(cleaned)) continue;

      cleaned = cleaned.replaceAllMapped(
        _lonelyX,
        (m) => '${m[1]}XBLANK',
      );

      final tokens =
          _tokenPattern
              .allMatches(cleaned)
              .map((m) => m.group(0)!.toUpperCase())
              .toList();

      if (tokens.isEmpty) continue;

      // ---------- 1. Find the Num ----------
      String number = '';
      int next = 0;
      String? compactAmount;

      final first = tokens[0];

      if (_digitsOnly.hasMatch(first)) {
        final hasNextLetters =
            tokens.length > 1 && !_digitsOnly.hasMatch(tokens[1]);

        if (first.length == 2) {
          number = first;
          next = 1;
          if (hasNextLetters && tokens[1].startsWith('V')) {
            number += 'V';
            next = 2;
          }
        } else if (first.length == 1) {
          if (hasNextLetters &&
              (tokens[1].startsWith('H') || tokens[1].startsWith('E'))) {
            number = first + tokens[1][0];
            next = 2;
          } else {
            continue;
          }
        } else {
          // Joined number and amount: 1510 = Num 15, Amount 10
          final possibleAmount = first.substring(2);
          final amount = int.tryParse(possibleAmount);

          if (amount == null || amount < 1 || amount > 15000) continue;

          number = first.substring(0, 2);
          compactAmount = possibleAmount;
          next = 1;
        }
      } else {
        final second =
            tokens.length > 1 && !_digitsOnly.hasMatch(tokens[1])
                ? tokens[1]
                : '';

        if (first.startsWith('AP') || first.startsWith('HP')) {
          number = first.substring(0, 2);
          next = 1;
        } else if ((first == 'A' || first == 'H') &&
            tokens.length > 1 &&
            tokens[1].startsWith('P')) {
          number = '${first}P';
          next = 2;
        } else if (_allPair.hasMatch(first)) {
          number = 'AP';
          next = 1;
        } else if (_halfPair.hasMatch(first)) {
          number = 'HP';
          next = 1;
        } else if (second.isNotEmpty && _allPair.hasMatch(first + second)) {
          number = 'AP';
          next = 2;
        } else if (second.isNotEmpty && _halfPair.hasMatch(first + second)) {
          number = 'HP';
          next = 2;
        } else {
          continue;
        }
      }

      // ---------- 2. Find the amounts ----------
      String? frLabel, srLabel, trLabel;
      final unlabelled = <String>[];

      if (compactAmount != null) unlabelled.add(compactAmount);

      String? pendingLabel;

      for (int i = next; i < tokens.length; i++) {
        final t = tokens[i];

        if (t == 'XBLANK') {
          // Blank amount box (keeps FR / SR position).
          if (pendingLabel == null) unlabelled.add('');
          pendingLabel = null;
          continue;
        }

        if (_digitsOnly.hasMatch(t)) {
          final amount = int.tryParse(t);
          final valid = amount != null && amount >= 1 && amount <= 15000;

          if (valid) {
            if (pendingLabel == 'FR') {
              frLabel = t;
            } else if (pendingLabel == 'SR') {
              srLabel = t;
            } else if (pendingLabel == 'TR') {
              trLabel = t;
            } else {
              unlabelled.add(t);
            }
          }
          pendingLabel = null;
        } else {
          pendingLabel = (t == 'FR' || t == 'SR' || t == 'TR') ? t : null;
        }
      }

      // ---------- 3. Assign FR / SR ----------
      String fr = '';
      String sr = '';

      if (isTRMode) {
        final filled = unlabelled.where((a) => a.isNotEmpty).toList();
        sr =
            trLabel ??
            srLabel ??
            frLabel ??
            (filled.isNotEmpty ? filled.last : '');
      } else {
        fr = frLabel ?? '';
        sr = srLabel ?? '';

        final rest = List<String>.from(unlabelled);
        if (frLabel == null && rest.isNotEmpty) fr = rest.removeAt(0);
        if (srLabel == null && rest.isNotEmpty) sr = rest.removeAt(0);
      }

      result.add(ScannedRow(number: number, fr: fr, sr: sr));

      if (result.length >= 200) break;
    }

    return result;
  }

  // ---------- number helpers (same rules as the main screen) ----------

  static bool isValidNumber(String v) {
    return RegExp(r'^\d{2}$').hasMatch(v) ||
        RegExp(r'^\d[HE]$').hasMatch(v) ||
        RegExp(r'^\d{2}V$').hasMatch(v) ||
        v == 'AP' ||
        v == 'HP';
  }

  static bool _isHE(String n) {
    return (n.length == 2 &&
            int.tryParse(n[0]) != null &&
            (n[1] == 'H' || n[1] == 'E')) ||
        n == 'AP' ||
        n == 'HP';
  }

  static bool _isV(String n) => RegExp(r'^[0-9]{2}V$').hasMatch(n);

  static int _vCount(String value) {
    final base = value.substring(0, 2);
    final a = int.parse(base[0]);
    final b = int.parse(base[1]);
    final cA = a >= 5 ? a - 5 : a + 5;
    final cB = b >= 5 ? b - 5 : b + 5;

    return <String>{
      '$a$b',
      '$b$a',
      '$cA$cB',
      '$cB$cA',
      '$a$cB',
      '$cB$a',
      '$cA$b',
      '$b$cA',
    }.length;
  }

  /// HE / AP / HP count as 10 numbers, V counts its generated numbers.
  static int multiplier(String number) {
    if (_isHE(number)) return 10;
    if (_isV(number)) return _vCount(number);
    return 1;
  }
}

// =====================================================================
// SCREEN
// =====================================================================

class TokenScannerScreen extends StatefulWidget {
  final bool isTRMode;

  const TokenScannerScreen({super.key, this.isTRMode = false});

  @override
  State<TokenScannerScreen> createState() => _TokenScannerScreenState();
}

class _TokenScannerScreenState extends State<TokenScannerScreen> {
  static const Color _primary = Color(0xFF2878D0);
  static const Color _pageColor = Color(0xFFF5F6F8);
  static const Color _border = Color(0xFFD5D9E0);

  final ImagePicker _picker = ImagePicker();

  late bool _isTR;
  File? _image;

  List<String> _ocrRows = []; // text rows rebuilt from the image
  List<ScannedRow> _rows = [];

  bool _busy = false;
  bool _scanned = false;
  bool _edited = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _isTR = widget.isTRMode;
  }

  // ---------------------------------------------------------------
  // PICK + OCR
  // ---------------------------------------------------------------

  Future<void> _pick(ImageSource source) async {
    if (_busy) return;

    try {
      final picked = await _picker.pickImage(source: source, maxWidth: 2600);
      if (picked == null) return;

      final file = File(picked.path);

      setState(() {
        _image = file;
        _busy = true;
        _scanned = false;
        _edited = false;
        _error = null;
        _rows = [];
        _ocrRows = [];
      });

      final lines = await _recognize(file);

      if (!mounted) return;

      setState(() {
        _ocrRows = lines;
        _rows = TokenTextParser.parse(lines.join('\n'), isTRMode: _isTR);
        _busy = false;
        _scanned = true;
      });
    } catch (e) {
      debugPrint('Token scan failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not read the image. Please try again.';
      });
    }
  }

  /// Reads the image and rebuilds table rows: text pieces that sit at the
  /// same height (Num, FR, SR columns) are joined into one line.
  Future<List<String>> _recognize(File file) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final result = await recognizer.processImage(InputImage.fromFile(file));

      final lines = <TextLine>[];
      for (final block in result.blocks) {
        lines.addAll(block.lines);
      }
      if (lines.isEmpty) return [];

      lines.sort(
        (a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy),
      );

      final rows = <List<TextLine>>[];
      double rowCenter = 0;
      double rowHeight = 0;

      for (final line in lines) {
        final center = line.boundingBox.center.dy;
        final height = line.boundingBox.height;

        if (rows.isNotEmpty &&
            (center - rowCenter).abs() <= max(rowHeight, height) * 0.6) {
          rows.last.add(line);
          rowCenter =
              rows.last
                  .map((l) => l.boundingBox.center.dy)
                  .reduce((a, b) => a + b) /
              rows.last.length;
          rowHeight = max(rowHeight, height);
        } else {
          rows.add([line]);
          rowCenter = center;
          rowHeight = height;
        }
      }

      return rows.map((row) {
        row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
        return row.map((l) => l.text).join('  ');
      }).toList();
    } finally {
      recognizer.close();
    }
  }

  // ---------------------------------------------------------------
  // FORMAT (FR, SR / TR)
  // ---------------------------------------------------------------

  Future<void> _setMode(bool tr) async {
    if (tr == _isTR) return;

    if (_edited) {
      final ok = await showDialog<bool>(
        context: context,
        builder:
            (c) => AlertDialog(
              title: const Text('Change format?'),
              content: const Text(
                'The image will be read again and your edits will be lost.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Continue'),
                ),
              ],
            ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _isTR = tr;
      _edited = false;
      if (_ocrRows.isNotEmpty) {
        _rows = TokenTextParser.parse(_ocrRows.join('\n'), isTRMode: tr);
      }
    });
  }

  // ---------------------------------------------------------------
  // TOTALS
  // ---------------------------------------------------------------

  int get _numberCount => _rows.where((r) => r.number.isNotEmpty).length;

  int _sumOf(String Function(ScannedRow r) pick) {
    int total = 0;
    for (final r in _rows) {
      final amount = int.tryParse(pick(r)) ?? 0;
      total += amount * TokenTextParser.multiplier(r.number.toUpperCase());
    }
    return total;
  }

  int get _frTotal => _isTR ? 0 : _sumOf((r) => r.fr);
  int get _srTotal => _sumOf((r) => r.sr);
  int get _grandTotal => _frTotal + _srTotal;

  Set<String> _duplicateNumbers() {
    final seen = <String>{};
    final dupes = <String>{};
    for (final r in _rows) {
      final n = r.number.toUpperCase();
      if (n.isEmpty) continue;
      if (!seen.add(n)) dupes.add(n);
    }
    return dupes;
  }

  // ---------------------------------------------------------------
  // EDIT / ADD / DELETE / COPY
  // ---------------------------------------------------------------

  Future<void> _editRow(int index) async {
    final updated = await showDialog<ScannedRow>(
      context: context,
      builder: (_) => _RowEditDialog(row: _rows[index], isTR: _isTR),
    );

    if (updated == null || !mounted) return;

    setState(() {
      _rows[index] = updated;
      _edited = true;
    });
  }

  Future<void> _addRow() async {
    final added = await showDialog<ScannedRow>(
      context: context,
      builder: (_) => _RowEditDialog(isTR: _isTR),
    );

    if (added == null || !mounted) return;

    setState(() {
      _rows.add(added);
      _edited = true;
    });
  }

  void _deleteRow(int index) {
    setState(() {
      _rows.removeAt(index);
      _edited = true;
    });
  }

  /// Same layout as the main screen's Copy, so it can be pasted back with
  /// the paste icon. A row with only one amount is labelled FR / SR so the
  /// amount goes into the right box.
  String _buildCopyText() {
    final lines = <String>[_isTR ? 'Num      TR' : 'Num      FR      SR'];

    for (final r in _rows) {
      final n = r.number.toUpperCase();
      if (n.isEmpty) continue;

      if (_isTR) {
        lines.add('${n.padRight(9)}${r.sr}');
      } else if (r.fr.isNotEmpty && r.sr.isNotEmpty) {
        lines.add('${n.padRight(9)}${r.fr.padRight(8)}${r.sr}');
      } else if (r.fr.isNotEmpty) {
        lines.add('${n.padRight(9)}FR ${r.fr}');
      } else if (r.sr.isNotEmpty) {
        lines.add('${n.padRight(9)}SR ${r.sr}');
      } else {
        lines.add(n);
      }
    }

    lines.add('');
    lines.add('Total- $_grandTotal');

    return lines.join('\n');
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _buildCopyText()));
    if (!mounted) return;
    _snack('Copied. Use the paste icon on the main screen.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showFullImage() {
    final file = _image;
    if (file == null) return;

    showDialog<void>(
      context: context,
      builder:
          (_) => Dialog(
            insetPadding: const EdgeInsets.all(8),
            child: InteractiveViewer(
              maxScale: 6,
              child: Image.file(file, fit: BoxFit.contain),
            ),
          ),
    );
  }

  // ---------------------------------------------------------------
  // UI PIECES
  // ---------------------------------------------------------------

  Widget _stat(String label, String value, {bool bold = false}) {
    return Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF687282)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: bold ? 18 : 16,
              fontWeight: FontWeight.bold,
              color: bold ? _primary : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard() {
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            _stat('Numbers', '$_numberCount'),
            if (!_isTR) _stat('FR', '₹ $_frTotal'),
            _stat(_isTR ? 'TR' : 'SR', '₹ $_srTotal'),
            _stat('Total', '₹ $_grandTotal', bold: true),
          ],
        ),
      ),
    );
  }

  Widget _amountText(String label, String value) {
    return Text(
      value.isEmpty ? '$label  –' : '$label  ₹ $value',
      style: TextStyle(
        fontSize: 15,
        fontWeight: value.isEmpty ? FontWeight.w400 : FontWeight.w600,
        color: value.isEmpty ? Colors.grey : Colors.black,
      ),
    );
  }

  Widget _rowTile(int index, Set<String> dupes) {
    final r = _rows[index];
    final n = r.number.toUpperCase();

    final invalid = !TokenTextParser.isValidNumber(n);
    final noAmount = r.fr.isEmpty && r.sr.isEmpty;
    final isDup = dupes.contains(n);
    final warn = invalid || noAmount || isDup;
    final mult = TokenTextParser.multiplier(n);

    String? warning;
    if (invalid) {
      warning = 'Number not valid';
    } else if (noAmount) {
      warning = 'No amount found';
    } else if (isDup) {
      warning = 'Same number appears more than once';
    }

    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: warn ? Colors.orange.shade700 : _border,
          width: warn ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _editRow(index),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              Container(
                width: 62,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6F4FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  n.isEmpty ? '?' : n,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    if (_isTR)
                      _amountText('TR', r.sr)
                    else ...[
                      _amountText('FR', r.fr),
                      _amountText('SR', r.sr),
                    ],
                  ],
                ),
              ),
              if (mult > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '×$mult',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              if (warning != null)
                Tooltip(
                  message: warning,
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange.shade700,
                    size: 20,
                  ),
                ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => _deleteRow(index),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final showResults = _scanned && !_busy;
    final dupes = _duplicateNumbers();

    return Scaffold(
      backgroundColor: _pageColor,
      appBar: AppBar(
        title: const Text('Token Scanner'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Scan'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Upload'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _primary,
                    minimumSize: const Size(0, 48),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          Row(
            children: [
              const Text('Format:  '),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('FR, SR'),
                    selected: !_isTR,
                    onSelected: (_) => _setMode(false),
                  ),
                  ChoiceChip(
                    label: const Text('TR'),
                    selected: _isTR,
                    onSelected: (_) => _setMode(true),
                  ),
                ],
              ),
            ],
          ),

          if (_image != null) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _showFullImage,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  _image!,
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Tap the image to view it full size',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],

          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Reading tokens...'),
                  ],
                ),
              ),
            ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),

          if (!_scanned && !_busy && _error == null)
            const Padding(
              padding: EdgeInsets.only(top: 28),
              child: Text(
                'Scan a token with the camera or upload a photo or '
                'screenshot. The app reads each Num and amount and '
                'calculates the total.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF687282)),
              ),
            ),

          if (showResults) ...[
            const SizedBox(height: 14),
            if (_rows.isNotEmpty) _summaryCard(),
            if (_rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No tokens found. Try a clearer, straight photo, or add '
                  'rows by hand.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF687282)),
                ),
              ),
            if (_rows.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(2, 10, 2, 8),
                child: Text(
                  'Check each row. Handwriting can be misread. '
                  'Tap a row to correct it.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF687282)),
                ),
              ),
            for (int i = 0; i < _rows.length; i++) _rowTile(i, dupes),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _addRow,
              icon: const Icon(Icons.add),
              label: const Text('Add row'),
            ),
          ],

          const SizedBox(height: 80),
        ],
      ),
      bottomNavigationBar:
          (showResults && _rows.isNotEmpty)
              ? SafeArea(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFE0E3E8))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$_numberCount numbers  ·  ₹ $_grandTotal',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _copy,
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  ),
                ),
              )
              : null,
    );
  }
}

// =====================================================================
// EDIT DIALOG
// =====================================================================

class _RowEditDialog extends StatefulWidget {
  final ScannedRow? row;
  final bool isTR;

  const _RowEditDialog({this.row, required this.isTR});

  @override
  State<_RowEditDialog> createState() => _RowEditDialogState();
}

class _RowEditDialogState extends State<_RowEditDialog> {
  late final TextEditingController _number;
  late final TextEditingController _fr;
  late final TextEditingController _sr;
  String? _error;

  @override
  void initState() {
    super.initState();
    _number = TextEditingController(text: widget.row?.number ?? '');
    _fr = TextEditingController(text: widget.row?.fr ?? '');
    _sr = TextEditingController(text: widget.row?.sr ?? '');
  }

  @override
  void dispose() {
    _number.dispose();
    _fr.dispose();
    _sr.dispose();
    super.dispose();
  }

  bool _amountOk(String v) {
    if (v.isEmpty) return true;
    final n = int.tryParse(v);
    return n != null && n >= 1 && n <= 15000;
  }

  void _save() {
    final number = _number.text.trim().toUpperCase();
    final fr = widget.isTR ? '' : _fr.text.trim();
    final sr = _sr.text.trim();

    if (!TokenTextParser.isValidNumber(number)) {
      setState(() => _error = 'Number must be like 45, 4H, 4E, 45V, AP or HP');
      return;
    }

    if (!_amountOk(fr) || !_amountOk(sr)) {
      setState(() => _error = 'Amounts must be between 1 and 15000');
      return;
    }

    if (fr.isEmpty && sr.isEmpty) {
      setState(() => _error = 'Enter at least one amount');
      return;
    }

    Navigator.pop(context, ScannedRow(number: number, fr: fr, sr: sr));
  }

  Widget _amountField(TextEditingController c, String label) {
    return TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(5),
      ],
      decoration: InputDecoration(
        labelText: label,
        prefixText: '₹ ',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add row' : 'Edit row'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _number,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [LengthLimitingTextInputFormatter(3)],
              decoration: const InputDecoration(
                labelText: 'Num',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            if (!widget.isTR) ...[
              _amountField(_fr, 'FR'),
              const SizedBox(height: 12),
            ],
            _amountField(_sr, widget.isTR ? 'TR' : 'SR'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
