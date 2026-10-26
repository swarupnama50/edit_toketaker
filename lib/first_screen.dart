import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:token_taker/saved_tokens.dart';
import 'package:token_taker/second_screen.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class FirstScreen extends StatefulWidget {
  const FirstScreen({super.key});

  @override
  State<FirstScreen> createState() => _FirstScreenState();
}

class _FirstScreenState extends State<FirstScreen> {
  bool isTRMode = false;
  final List<int> allowedValues = List.generate(20, (i) => (i + 1) * 5);

  final List<TextEditingController> numControllers = [];
  final List<TextEditingController> frControllers = [];
  final List<TextEditingController> srControllers = [];
  final List<FocusNode> numFocusNodes = [];
  final List<FocusNode> frFocusNodes = [];
  final List<FocusNode> srFocusNodes = [];
  final Set<int> warnedDuplicateRows = {};
  final Map<TextEditingController, bool> _numberWasEmpty = {};
  final ValueNotifier<int> amountRevision = ValueNotifier<int>(0);

  final TextEditingController nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    addNewRow();
  }

  void handleBackspace(
    TextEditingController controller,
    int rowIndex,
    String fieldType,
  ) {
    if (controller.text.isNotEmpty) return;

    FocusNode? previousFocus;
    TextEditingController? previousController;

    if (fieldType == 'num') {
      // Num -> previous row's amount box, skipping blank rows.
      for (int i = rowIndex - 1; i >= 0; i--) {
        if (!isFirstFilled(i)) continue;

        if (isTRMode) {
          if (srControllers[i].text.trim().isNotEmpty) {
            previousController = srControllers[i];
            previousFocus = srFocusNodes[i];
            break;
          }
        } else {
          if (srControllers[i].text.trim().isNotEmpty) {
            previousController = srControllers[i];
            previousFocus = srFocusNodes[i];
            break;
          }

          if (frControllers[i].text.trim().isNotEmpty) {
            previousController = frControllers[i];
            previousFocus = frFocusNodes[i];
            break;
          }
        }

        previousController = numControllers[i];
        previousFocus = numFocusNodes[i];
        break;
      }
    } else if (fieldType == 'sr') {
      if (isTRMode) {
        // TR -> same row's Num.
        previousController = numControllers[rowIndex];
        previousFocus = numFocusNodes[rowIndex];
      } else {
        // SR -> FR if filled; otherwise Num.
        if (frControllers[rowIndex].text.trim().isNotEmpty) {
          previousController = frControllers[rowIndex];
          previousFocus = frFocusNodes[rowIndex];
        } else {
          previousController = numControllers[rowIndex];
          previousFocus = numFocusNodes[rowIndex];
        }
      }
    } else if (fieldType == 'fr') {
      // FR -> same row's Num.
      previousController = numControllers[rowIndex];
      previousFocus = numFocusNodes[rowIndex];
    }

    if (previousController != null && previousFocus != null) {
      FocusScope.of(context).requestFocus(previousFocus);

      previousController.selection = TextSelection.collapsed(
        offset: previousController.text.length,
      );
    }
  }

  void hideKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }

  // ================= SPACE NAVIGATION =================

  bool isValidCompletedNumber(String value) {
    return RegExp(r'^\d{2}$').hasMatch(value) ||
        RegExp(r'^\d[HE]$').hasMatch(value) ||
        RegExp(r'^\d{2}V$').hasMatch(value) ||
        value == 'AP' ||
        value == 'HP';
  }

  void moveToNextField(int rowIndex, String currentField) {
    if (currentField == 'num') {
      if (isTRMode) {
        FocusScope.of(context).requestFocus(srFocusNodes[rowIndex]);
      } else {
        FocusScope.of(context).requestFocus(frFocusNodes[rowIndex]);
      }
      return;
    }

    if (currentField == 'fr') {
      FocusScope.of(context).requestFocus(srFocusNodes[rowIndex]);
      return;
    }

    // After SR/TR, move to the next visible row's Num field.
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (isNumEnabled(nextIndex)) {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }
    }

    // If there is no next enabled row, leave the current field focused.
  }

  void moveToNextNum(int rowIndex) {
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (isNumEnabled(nextIndex)) {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }
    }
  }

  void moveToNextAmount(int rowIndex, String fieldType) {
    final sortedIndexes = getSortedRowIndexes();
    final position = sortedIndexes.indexOf(rowIndex);

    for (int i = position + 1; i < sortedIndexes.length; i++) {
      final nextIndex = sortedIndexes[i];

      if (fieldType == 'num') {
        FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        return;
      }

      if (fieldType == 'fr') {
        if (!isTRMode && isFirstFilled(nextIndex)) {
          FocusScope.of(context).requestFocus(frFocusNodes[nextIndex]);
        } else {
          FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        }
        return;
      }

      if (fieldType == 'sr' || fieldType == 'tr') {
        if (isFirstFilled(nextIndex)) {
          FocusScope.of(context).requestFocus(srFocusNodes[nextIndex]);
        } else {
          FocusScope.of(context).requestFocus(numFocusNodes[nextIndex]);
        }
        return;
      }
    }
  }

  void checkDuplicateNumber(String value, int currentIndex) {
    value = value.trim().toUpperCase();

    if (!isValidCompletedNumber(value)) {
      warnedDuplicateRows.remove(currentIndex);
      return;
    }

    final exists = numControllers.asMap().entries.any(
      (entry) =>
          entry.key != currentIndex &&
          entry.value.text.trim().toUpperCase() == value,
    );

    if (exists && !warnedDuplicateRows.contains(currentIndex) && mounted) {
      warnedDuplicateRows.add(currentIndex);

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Warning: Number $value is already entered!'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(left: 12, right: 12, bottom: 60),
          ),
        );
    } else if (!exists) {
      warnedDuplicateRows.remove(currentIndex);
    }
  }

  void handleSpaceInput(
    TextEditingController controller,
    String value,
    int rowIndex,
    String fieldType,
  ) {
    if (!value.endsWith(' ')) return;

    final text = value.substring(0, value.length - 1);
    final upperText = text.toUpperCase();

    if (fieldType == 'num') {
      if (!isValidCompletedNumber(upperText)) {
        controller.value = TextEditingValue(
          text: upperText,
          selection: TextSelection.collapsed(offset: upperText.length),
        );
        return;
      }

      checkDuplicateNumber(upperText, rowIndex);
    }

    controller.value = TextEditingValue(
      text: upperText,
      selection: TextSelection.collapsed(offset: upperText.length),
    );

    moveToNextField(rowIndex, fieldType);
  }

  Widget spaceAwareField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required int rowIndex,
    required String fieldType,
    required InputDecoration decoration,
    required double width,
    required bool enabled,
    required TextInputType keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextAlign textAlign = TextAlign.center,
    ValueChanged<String>? onChanged,
    VoidCallback? onEditingComplete,
    ValueChanged<String>? onSubmitted,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return SizedBox(
      width: width,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace &&
              controller.text.isEmpty) {
            handleBackspace(controller, rowIndex, fieldType);
            return KeyEventResult.handled;
          }

          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          textAlign: textAlign,
          inputFormatters: inputFormatters,
          onChanged: onChanged,
          onEditingComplete: onEditingComplete,
          onSubmitted: onSubmitted,
          decoration: decoration,
        ),
      ),
    );
  }

  // ================= V GENERATOR =================

  List<String> generateVNumbers(String value) {
    if (value.length != 3 || !value.endsWith('V')) return [];

    String base = value.substring(0, 2);

    int a = int.parse(base[0]);
    int b = int.parse(base[1]);

    int cA = (a >= 5) ? a - 5 : a + 5;
    int cB = (b >= 5) ? b - 5 : b + 5;

    Set<String> numbers = {};

    numbers.add("$a$b");
    numbers.add("$b$a");
    numbers.add("$cA$cB");
    numbers.add("$cB$cA");
    numbers.add("$a$cB");
    numbers.add("$cB$a");
    numbers.add("$cA$b");
    numbers.add("$b$cA");

    return numbers.toList();
  }

  void showVNumbersPopup(String value) {
    List<String> numbers = generateVNumbers(value);

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text("Values"),
            content: Wrap(
              spacing: 10,
              children: numbers.map((e) => Chip(label: Text(e))).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Close"),
              ),
            ],
          ),
    );
  }

  Future<void> _openSavedReceipts() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final directory = Directory('${appDir.path}/saved_receipts');

      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }

      final receipts =
          directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.jpg'))
              .toList();

      receipts.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      if (!mounted) return;

      hideKeyboard();

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SavedReceiptsScreen(receipts: receipts),
        ),
      );

      if (!mounted) return;

      hideKeyboard();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not load saved receipts: $e'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(left: 12, right: 12, bottom: 60),
        ),
      );
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Clear all rows?'),
            content: const Text(
              'Are you sure you want to clear all entered data?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('OK'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      for (final controller in numControllers) {
        _numberWasEmpty.remove(controller);
        controller.clear();
      }

      for (final controller in frControllers) {
        controller.clear();
      }

      for (final controller in srControllers) {
        controller.clear();
      }

      // Keep the existing rows, but clear their contents.
      amountRevision.value++;
    });
  }
  // ================= TOTAL LOGIC =================

  int getTotalAmount() {
    int total = 0;

    for (int i = 0; i < numControllers.length; i++) {
      final numText = numControllers[i].text.trim();
      final fr = isTRMode ? 0 : (int.tryParse(frControllers[i].text) ?? 0);
      final sr = int.tryParse(srControllers[i].text) ?? 0;

      bool isSingleWithHE =
          (numText.length == 2 &&
              int.tryParse(numText[0]) != null &&
              (numText[1] == 'H' || numText[1] == 'E')) ||
          numText == 'AP' ||
          numText == 'HP';

      bool isDoubleWithV =
          numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

      if (isSingleWithHE) {
        total += (fr * 10) + (sr * 10);
      } else if (isDoubleWithV) {
        int count = generateVNumbers(numText).length;
        total += (fr * count) + (sr * count);
      } else {
        total += fr + sr;
      }
    }

    return total;
  }

  // ================= VALIDATION =================

  bool canProceed() {
    bool hasAtLeastOneNumber = false;

    for (int i = 0; i < numControllers.length; i++) {
      final numText = numControllers[i].text.trim();
      final frText = frControllers[i].text.trim();
      final srText = srControllers[i].text.trim();

      if (numText.isNotEmpty) {
        hasAtLeastOneNumber = true;

        bool isNormalTwoDigit =
            numText.length == 2 && int.tryParse(numText) != null;

        bool isSingleWithHE =
            (numText.length == 2 &&
                int.tryParse(numText[0]) != null &&
                (numText[1] == 'H' || numText[1] == 'E')) ||
            (numText == 'AP' || numText == 'HP');

        bool isDoubleWithV =
            numText.length == 3 && RegExp(r'^[0-9]{2}V$').hasMatch(numText);

        if (!isNormalTwoDigit && !isSingleWithHE && !isDoubleWithV) {
          return false;
        }

        if (frText.isEmpty && srText.isEmpty) return false;

        if (frText.isNotEmpty) {
          final value = int.tryParse(frText);
          if (value == null || value < 1 || value > 15000) {
            return false;
          }
        }

        if (srText.isNotEmpty) {
          final value = int.tryParse(srText);
          if (value == null || value < 1 || value > 15000) {
            return false;
          }
        }
      }
    }

    if (!hasAtLeastOneNumber) return false;

    return true;
  }

  // ================= REAL-TIME ARRANGEMENT =================

  int getNumberType(String value) {
    if (RegExp(r'^\d{2}$').hasMatch(value)) return 0;

    if (RegExp(r'^\d[HE]$').hasMatch(value) || value == 'AP' || value == 'HP') {
      return 1;
    }

    if (RegExp(r'^\d{2}V$').hasMatch(value)) return 2;

    return 0;
  }

  List<int> getSortedRowIndexes() {
    return List.generate(numControllers.length, (i) => i);
  }

  // ================= ROW LOGIC =================

  void addNewRow() {
    if (numControllers.length >= 200) return;

    final numController = TextEditingController();
    final frController = TextEditingController();
    final srController = TextEditingController();

    _numberWasEmpty[numController] = true;

    numController.addListener(() {
      final index = numControllers.indexOf(numController);
      if (index == -1) return;

      final isEmpty = numController.text.isEmpty;
      final wasEmpty = _numberWasEmpty[numController] ?? true;

      // Rebuild the row list only when a row becomes empty/non-empty.
      if (isEmpty != wasEmpty) {
        _numberWasEmpty[numController] = isEmpty;

        if (isEmpty) {
          frController.clear();
          srController.clear();
        } else {
          final isLast = index == numControllers.length - 1;
          if (isLast && numControllers.length < 200) {
            addNewRow();
          }
        }

        if (mounted) setState(() {});
      }

      // Refresh only the total/Continue area while text is being edited.
      amountRevision.value++;
    });

    frController.addListener(() {
      amountRevision.value++;
    });

    srController.addListener(() {
      amountRevision.value++;
    });

    numControllers.add(numController);
    frControllers.add(frController);
    srControllers.add(srController);

    numFocusNodes.add(FocusNode());
    frFocusNodes.add(FocusNode());
    srFocusNodes.add(FocusNode());
  }

  // ================= REMOVE ROW =================

  void removeRow(int index) {
    if (numControllers.length <= 1) return;

    numControllers[index].dispose();
    frControllers[index].dispose();
    srControllers[index].dispose();

    numFocusNodes[index].dispose();
    frFocusNodes[index].dispose();
    srFocusNodes[index].dispose();

    _numberWasEmpty.remove(numControllers[index]);
    numControllers.removeAt(index);
    frControllers.removeAt(index);
    srControllers.removeAt(index);

    numFocusNodes.removeAt(index);
    frFocusNodes.removeAt(index);
    srFocusNodes.removeAt(index);

    setState(() {});
  }

  bool isFirstFilled(int index) => numControllers[index].text.isNotEmpty;

  bool isNumEnabled(int index) {
    return true;
  }

  void validateController(TextEditingController controller) {
    final value = int.tryParse(controller.text);

    if (value == null || value < 5 || value > 15000) {
      controller.clear();
    }
  }

  void handleChange(TextEditingController controller, String val) {
    final value = int.tryParse(val);

    if (val.isNotEmpty && (value == null || value < 1 || value > 15000)) {
      controller.clear();
    }
  }

  void compactRowsAfterDelete(int deletedIndex) {
    if (numControllers[deletedIndex].text.isNotEmpty) return;

    int targetIndex = deletedIndex;

    for (
      int sourceIndex = deletedIndex + 1;
      sourceIndex < numControllers.length;
      sourceIndex++
    ) {
      if (numControllers[sourceIndex].text.trim().isEmpty) {
        continue;
      }

      numControllers[targetIndex].text = numControllers[sourceIndex].text;

      frControllers[targetIndex].text = frControllers[sourceIndex].text;

      srControllers[targetIndex].text = srControllers[sourceIndex].text;

      numControllers[sourceIndex].clear();
      frControllers[sourceIndex].clear();
      srControllers[sourceIndex].clear();

      targetIndex++;
    }

    amountRevision.value++;
    if (mounted) setState(() {});
  }

  // ================= K AMOUNT LOGIC =================

  void handleAmountWithK(
    TextEditingController controller,
    String val,
    int rowIndex,
    bool isFr,
  ) {
    final upperVal = val.toUpperCase();

    if (!upperVal.endsWith('K')) return;

    final amountText = upperVal.substring(0, upperVal.length - 1);
    final amount = int.tryParse(amountText);

    if (amount == null || amount < 1 || amount > 15000) {
      controller.clear();

      return;
    }

    controller.value = TextEditingValue(
      text: amountText,
      selection: TextSelection.collapsed(offset: amountText.length),
    );

    final controllers = isFr ? frControllers : srControllers;
    final sortedIndexes = getSortedRowIndexes();
    final currentPosition = sortedIndexes.indexOf(rowIndex);

    if (currentPosition != -1) {
      final numericRowPattern = RegExp(r'^\d{2}$');

      bool isNormalNumericRow(String value) {
        return numericRowPattern.hasMatch(value);
      }

      // Find the last blank numeric row below the current row.
      int lastBlankNumericPosition = -1;

      for (
        int position = currentPosition + 1;
        position < sortedIndexes.length;
        position++
      ) {
        final index = sortedIndexes[position];
        final numberText = numControllers[index].text.trim();

        if (isNormalNumericRow(numberText) &&
            controllers[index].text.trim().isEmpty) {
          lastBlankNumericPosition = position;
        }
      }

      // Fill amounts using the original stopping behavior.
      for (
        int position = currentPosition + 1;
        position < sortedIndexes.length;
        position++
      ) {
        final belowIndex = sortedIndexes[position];
        final numberText = numControllers[belowIndex].text.trim();

        if (!isNormalNumericRow(numberText)) continue;

        if (controllers[belowIndex].text.trim().isEmpty) {
          controllers[belowIndex].text = amountText;
          continue;
        }

        // Stop if a blank numeric row remains below this row.
        if (lastBlankNumericPosition > position) {
          break;
        }
      }
    }
  }

  // ================= NEXT SCREEN =================

  void goToNextScreen() {
    List<Map<String, String>> data = [];

    for (int i = 0; i < numControllers.length; i++) {
      if (numControllers[i].text.isNotEmpty) {
        data.add({
          "num": numControllers[i].text,
          "fr": frControllers[i].text.isEmpty ? "Nil" : frControllers[i].text,
          "sr": srControllers[i].text.isEmpty ? "Nil" : srControllers[i].text,
        });
      }
    }

    hideKeyboard();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => SecondScreen(
              data: data,
              name: nameController.text.trim(),
              isTRMode: isTRMode,
            ),
      ),
    ).then((_) {
      if (!mounted) return;

      hideKeyboard();
    });
  }

  // ================= UI =================

  Widget buildRow(int index) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const numWidth = 60.0;

        const gap = 8.0;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: numWidth,
                child: spaceAwareField(
                  controller: numControllers[index],
                  focusNode: numFocusNodes[index],
                  rowIndex: index,
                  fieldType: 'num',
                  width: numWidth,
                  enabled: isNumEnabled(index),
                  keyboardType: TextInputType.text,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(4),
                    TextInputFormatter.withFunction((oldValue, newValue) {
                      final text = newValue.text.toUpperCase();
                      final value = TextEditingValue(
                        text: text,
                        selection: newValue.selection,
                      );

                      if (text.isEmpty) return value;

                      if (text.endsWith(' ')) {
                        return value;
                      }

                      if (RegExp(r'^[0-9]$').hasMatch(text) ||
                          RegExp(r'^[AH]$').hasMatch(text) ||
                          text == 'AP' ||
                          text == 'HP' ||
                          RegExp(r'^[0-9]{2}$').hasMatch(text) ||
                          RegExp(r'^[0-9][HE]$').hasMatch(text) ||
                          RegExp(r'^[0-9]{2}V$').hasMatch(text)) {
                        return value;
                      }

                      return oldValue;
                    }),
                  ],
                  onChanged: (val) {
                    final value = val.trim().toUpperCase();

                    if (value.length >= 2 && isValidCompletedNumber(value)) {
                      checkDuplicateNumber(value, index);
                    } else {
                      warnedDuplicateRows.remove(index);
                    }

                    if (val.endsWith(' ')) {
                      handleSpaceInput(
                        numControllers[index],
                        val,
                        index,
                        'num',
                      );
                    }

                    if (val.isEmpty) {
                      compactRowsAfterDelete(index);
                    }
                  },
                  onSubmitted: (_) {
                    final value =
                        numControllers[index].text.trim().toUpperCase();

                    if (!isValidCompletedNumber(value)) return;

                    checkDuplicateNumber(value, index);
                    moveToNextAmount(index, 'num');
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                ),
              ),

              const SizedBox(width: gap),

              if (!isTRMode) ...[
                Expanded(
                  child: spaceAwareField(
                    controller: frControllers[index],
                    focusNode: frFocusNodes[index],
                    rowIndex: index,
                    fieldType: 'fr',
                    width: double.infinity,
                    enabled: isFirstFilled(index),
                    keyboardType: TextInputType.text,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9Kk ]')),
                      LengthLimitingTextInputFormatter(5),
                    ],
                    onChanged: (val) {
                      if (val.endsWith(' ')) {
                        handleSpaceInput(
                          frControllers[index],
                          val,
                          index,
                          'fr',
                        );
                      } else {
                        handleAmountWithK(
                          frControllers[index],
                          val,
                          index,
                          true,
                        );
                      }
                    },
                    onSubmitted: (_) {
                      moveToNextAmount(index, 'fr');
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      prefixText: '₹ ',
                    ),
                  ),
                ),
                const SizedBox(width: gap),
              ],

              Expanded(
                child: spaceAwareField(
                  controller: srControllers[index],
                  focusNode: srFocusNodes[index],
                  rowIndex: index,
                  fieldType: 'sr',
                  width: double.infinity,
                  enabled: isFirstFilled(index),
                  keyboardType: TextInputType.text,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9Kk ]')),
                    LengthLimitingTextInputFormatter(5),
                  ],
                  onChanged: (val) {
                    if (val.endsWith(' ')) {
                      handleSpaceInput(srControllers[index], val, index, 'sr');
                    } else {
                      handleAmountWithK(
                        srControllers[index],
                        val,
                        index,
                        false,
                      );
                    }
                  },
                  onSubmitted: (_) {
                    moveToNextAmount(index, isTRMode ? 'tr' : 'sr');
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    prefixText: '₹ ',
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    for (var c in numControllers) {
      c.dispose();
    }

    for (var c in frControllers) {
      c.dispose();
    }

    for (var c in srControllers) {
      c.dispose();
    }

    for (var node in numFocusNodes) {
      node.dispose();
    }

    for (var node in frFocusNodes) {
      node.dispose();
    }

    for (var node in srFocusNodes) {
      node.dispose();
    }

    nameController.dispose();
    amountRevision.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sortedIndexes = getSortedRowIndexes();

    return Scaffold(
      // Explicitly move the footer above the keyboard when it opens.
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: SizedBox(
          width: 150,
          height: 40,
          child: TextField(
            controller: nameController,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              hintText: 'Enter name',
              contentPadding: EdgeInsets.symmetric(horizontal: 10),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),

        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton(
              onPressed: () {
                setState(() {
                  isTRMode = !isTRMode;
                });
              },
              child: Text(
                isTRMode ? 'TR' : 'FR, SR',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 60,
                  child: Center(
                    child: Text(
                      'Num',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                if (!isTRMode) ...[
                  const SizedBox(
                    width: 100,
                    child: Center(
                      child: Text(
                        'FR',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 15),
                ] else
                  const SizedBox(width: 115),
                const SizedBox(width: 15),
                SizedBox(
                  width: 100,
                  child: Center(
                    child: Text(
                      isTRMode ? 'TR' : 'SR',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 50),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: sortedIndexes.length,
              itemBuilder: (context, index) => buildRow(sortedIndexes[index]),
            ),
          ),

          ValueListenableBuilder<int>(
            valueListenable: amountRevision,
            builder: (context, _, child) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.grey)),
                ),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Clear all: far-left
                      IconButton(
                        tooltip: 'Clear all rows',
                        onPressed: _confirmClearAll,
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        iconSize: 26,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 44,
                        ),
                      ),

                      // Saved receipts
                      IconButton(
                        tooltip: 'Saved receipts',
                        onPressed: _openSavedReceipts,
                        icon: const Icon(Icons.photo_library_outlined),
                        iconSize: 28,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 44,
                        ),
                      ),

                      // Total
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            'Total: ₹ ${getTotalAmount()}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),

                      // Next: far-right
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: FloatingActionButton(
                          mini: true,
                          elevation: 1,
                          backgroundColor:
                              canProceed() ? Colors.blue : Colors.grey,
                          foregroundColor: Colors.white,
                          onPressed:
                              canProceed()
                                  ? () {
                                    if (isTRMode) {
                                      for (
                                        int i = 0;
                                        i < numControllers.length;
                                        i++
                                      ) {
                                        if (numControllers[i].text
                                                .trim()
                                                .isNotEmpty &&
                                            srControllers[i].text
                                                .trim()
                                                .isEmpty) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Please fill all TR amount boxes before continuing.',
                                              ),
                                            ),
                                          );
                                          return;
                                        }
                                      }
                                    }

                                    goToNextScreen();
                                  }
                                  : null,
                          child: const Icon(Icons.arrow_forward, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
