import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/services.dart';
import 'package:token_taker/receipt_viewer_screen.dart';
import 'package:token_taker/receipttotal_calculate_sharehelper.dart';

/// Smooth fade when opening the viewer.
Route<T> _fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (context, animation, secondary) => page,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

/// Folders for saved and trashed receipts.
class ReceiptStorage {
  static Future<Directory> _folder(String name) async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$name');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> receiptsDir() => _folder('saved_receipts');
  static Future<Directory> trashDir() => _folder('trash_receipts');

  static Future<List<File>> listJpgs(Directory dir) async {
    if (!await dir.exists()) return [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .toList();
  }

  /// Moves a file and keeps its original date and time.
  static Future<void> move(File file, Directory target) async {
    final newPath = '${target.path}/${ReceiptTotals.nameOf(file)}';
    try {
      await file.rename(newPath);
    } on FileSystemException {
      final modified = await file.lastModified();
      final copy = await file.copy(newPath);
      await copy.setLastModified(modified);
      await file.delete();
    }
  }

  static Future<void> moveToTrash(File file) async =>
      move(file, await trashDir());

  static Future<void> restore(File file) async =>
      move(file, await receiptsDir());

  static Future<void> deleteForever(File file) async {
    if (await file.exists()) await file.delete();
    await ReceiptTotals.removeAll([ReceiptTotals.nameOf(file)]);
  }
}

class SavedReceiptsScreen extends StatefulWidget {
  final List<File> receipts;

  const SavedReceiptsScreen({super.key, required this.receipts});

  @override
  State<SavedReceiptsScreen> createState() => _SavedReceiptsScreenState();
}

class _SavedReceiptsScreenState extends State<SavedReceiptsScreen> {
  late List<File> _receipts;
  List<File> _trash = [];
  final Set<String> _selectedPaths = {};
  Map<String, int> _totals = {};
  bool _inTrash = false;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final Map<String, GlobalKey> _cellKeys = {};

  // Hold-and-slide selection state.
  int? _anchorIndex;
  Set<String> _baseSelection = {};
  Offset? _dragPos;
  Timer? _autoScrollTimer;

  List<File> get _current => _inTrash ? _trash : _receipts;
  bool get _isSelecting => _selectedPaths.isNotEmpty;
  int get _todayCount {
    final today = _dateOnly(DateTime.now());
    return _receipts
        .where((f) => _dateOnly(f.lastModifiedSync()) == today)
        .length;
  }

  @override
  void initState() {
    super.initState();
    _receipts = List<File>.from(widget.receipts);
    _sort(_receipts);
    _loadTotals();
    _loadTrash();
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _sort(List<File> files) {
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<void> _loadTotals() async {
    final totals = await ReceiptTotals.loadAll();
    if (mounted) setState(() => _totals = totals);
  }

  Future<void> _deleteSelectedForever() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    final ok = await _confirm(
      title: 'Delete permanently?',
      message:
          'Delete ${_countText(files.length)} forever? '
          'This action cannot be undone.',
      action: 'Delete forever',
    );

    if (!ok || !mounted) return;

    var deleted = 0;
    var failed = 0;

    for (final file in files) {
      try {
        await ReceiptStorage.deleteForever(file);
        deleted++;
      } catch (_) {
        failed++;
      }
    }

    if (!mounted) return;

    await _loadTrash();

    if (!mounted) return;

    setState(() {
      _selectedPaths.clear();
    });

    _showSnack(
      failed == 0
          ? '${_countText(deleted)} deleted permanently.'
          : '$deleted deleted permanently. $failed could not be deleted.',
    );
  }

  Future<void> _loadTrash() async {
    final files = await ReceiptStorage.listJpgs(
      await ReceiptStorage.trashDir(),
    );
    _sort(files);
    if (!mounted) return;
    setState(() {
      _trash = files;
      if (_trash.isEmpty) _inTrash = false;
    });
  }

  Future<void> _reloadSaved() async {
    final files = await ReceiptStorage.listJpgs(
      await ReceiptStorage.receiptsDir(),
    );
    _sort(files);
    if (mounted) setState(() => _receipts = files);
  }

  String _formatReceiptTime(File file) {
    final date = file.lastModifiedSync();
    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final period = date.hour >= 12 ? 'PM' : 'AM';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(hour12)}:${two(date.minute)} $period';
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _sectionTitle(File file) {
    final today = _dateOnly(DateTime.now());
    final fileDate = _dateOnly(file.lastModifiedSync());
    final difference = today.difference(fileDate).inDays;

    if (difference == 0) return 'Today';
    if (difference == 1) return 'Yesterday';

    return '${fileDate.day.toString().padLeft(2, '0')}/'
        '${fileDate.month.toString().padLeft(2, '0')}/'
        '${fileDate.year}';
  }

  Map<String, List<File>> _groupReceipts() {
    final groups = <String, List<File>>{};
    for (final file in _current) {
      groups.putIfAbsent(_sectionTitle(file), () => []).add(file);
    }
    return groups;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- SELECTION ----------

  void _toggleSelection(File file) {
    setState(() {
      if (!_selectedPaths.remove(file.path)) {
        _selectedPaths.add(file.path);
      }
    });
  }

  bool _isSectionAllSelected(List<File> files) =>
      files.isNotEmpty && files.every((f) => _selectedPaths.contains(f.path));

  void _toggleSectionSelection(List<File> files) {
    setState(() {
      if (_isSectionAllSelected(files)) {
        _selectedPaths.removeAll(files.map((f) => f.path));
      } else {
        _selectedPaths.addAll(files.map((f) => f.path));
      }
    });
  }

  bool get _isEverythingSelected =>
      _current.isNotEmpty && _selectedPaths.length == _current.length;

  void _toggleSelectEverything() {
    setState(() {
      if (_isEverythingSelected) {
        _selectedPaths.clear();
      } else {
        _selectedPaths
          ..clear()
          ..addAll(_current.map((f) => f.path));
      }
    });
  }

  List<File> get _selectedFiles =>
      _current.where((f) => _selectedPaths.contains(f.path)).toList();

  // ---------- HOLD AND SLIDE TO SELECT ----------
  // Selects every image from where you held down to where your finger is now,
  // in reading order. Slide back up and the extra images are unselected.

  void _startDrag(File file, Offset global) {
    final i = _current.indexWhere((f) => f.path == file.path);
    if (i < 0) return;

    HapticFeedback.mediumImpact();

    _anchorIndex = i;
    _baseSelection = Set<String>.from(_selectedPaths);
    _dragPos = global;

    setState(() => _selectedPaths.add(file.path));
    _startAutoScroll();
  }

  void _dragMove(Offset global) {
    _dragPos = global;
    final index = _indexAt(global);
    if (index != null) _applyRange(index);
  }

  void _endDrag() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPos = null;
    _anchorIndex = null;
  }

  void _applyRange(int currentIndex) {
    final anchor = _anchorIndex;
    if (anchor == null) return;

    final lo = math.min(anchor, currentIndex);
    final hi = math.max(anchor, currentIndex);

    final next = Set<String>.from(_baseSelection);
    for (int i = lo; i <= hi && i < _current.length; i++) {
      next.add(_current[i].path);
    }

    if (next.length == _selectedPaths.length &&
        next.containsAll(_selectedPaths)) {
      return;
    }

    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(next);
    });
  }

  int? _indexAt(Offset global) {
    for (int i = 0; i < _current.length; i++) {
      final box =
          _cellKeys[_current[i].path]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;

      final local = box.globalToLocal(global);
      if ((Offset.zero & box.size).inflate(3).contains(local)) return i;
    }
    return null;
  }

  void _startAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final pos = _dragPos;
      if (pos == null || !_scroll.hasClients) return;

      final box = _listKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) return;

      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      const zone = 110.0;

      double delta = 0;
      if (pos.dy < top + zone) {
        delta = -((top + zone - pos.dy) / zone) * 18;
      } else if (pos.dy > bottom - zone) {
        delta = ((pos.dy - (bottom - zone)) / zone) * 18;
      }

      if (delta == 0) return;

      final target = (_scroll.offset + delta).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(target);

      final index = _indexAt(pos);
      if (index != null) _applyRange(index);
    });
  }

  // ---------- CALCULATE ----------

  void _showCalculationDialog() {
    final selected = _selectedFiles;

    int total = 0;
    int missing = 0;

    final rows = <Widget>[];

    for (final file in selected) {
      final amount = _totals[ReceiptTotals.nameOf(file)];
      if (amount == null) {
        missing++;
      } else {
        total += amount;
      }

      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_sectionTitle(file)}, ${_formatReceiptTime(file)}',
                ),
              ),
              Text(
                amount == null ? 'N/A' : '₹ $amount',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    showDialog<void>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(
              'Selected total (${selected.length} '
              '${selected.length == 1 ? 'receipt' : 'receipts'})',
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(child: ListView(shrinkWrap: true, children: rows)),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Text(
                        '₹ $total',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  if (missing > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '$missing older ${missing == 1 ? 'receipt has' : 'receipts have'} '
                        'no saved amount and ${missing == 1 ? 'was' : 'were'} not counted.',
                        style: const TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  // ---------- OPEN / SHARE ----------

  Future<void> _openReceipt(File file, List<File> dayFiles) async {
    final initialIndex = dayFiles.indexWhere((item) => item.path == file.path);

    await Navigator.push(
      context,
      _fadeRoute(
        ReceiptViewerScreen(
          files: dayFiles,
          initialIndex: initialIndex < 0 ? 0 : initialIndex,
          isTrash: _inTrash,
          onShare: _inTrash ? null : (file) => _shareFiles([file]),
        ),
      ),
    );

    // The viewer may have deleted or restored images.
    if (!mounted) return;
    await _reloadSaved();
    await _loadTrash();
  }

  Future<void> _shareFiles(List<File> files) async {
    final existingFiles = <File>[];

    for (final file in files) {
      if (await file.exists()) existingFiles.add(file);
    }

    if (!mounted) return;

    if (existingFiles.isEmpty) {
      _showSnack('No receipt images found.');
      return;
    }

    try {
      await ShareHelper.shareFiles(existingFiles, onNotice: _showSnack);

      if (mounted && _isSelecting) {
        setState(() => _selectedPaths.clear());
      }
    } catch (e) {
      _showSnack('Unable to share receipts: $e');
    }
  }

  // ---------- TRASH ACTIONS ----------

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool danger = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(
                  foregroundColor: danger ? Colors.red : null,
                ),
                child: Text(action),
              ),
            ],
          ),
    );
    return result == true;
  }

  String _countText(int n) => '$n ${n == 1 ? 'receipt' : 'receipts'}';

  Future<void> _moveSelectedToTrash() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    final ok = await _confirm(
      title: 'Move to Trash?',
      message:
          'Move ${_countText(files.length)} to Trash? '
          'You can restore them from Trash.',
      action: 'Move',
    );
    if (!ok || !mounted) return;

    var failed = 0;
    for (final file in files) {
      try {
        await ReceiptStorage.moveToTrash(file);
      } catch (_) {
        failed++;
      }
    }

    _selectedPaths.clear();
    await _reloadSaved();
    await _loadTrash();

    _showSnack(
      failed == 0
          ? '${_countText(files.length)} moved to Trash.'
          : '${files.length - failed} moved. $failed could not be moved.',
    );
  }

  Future<void> _restoreSelected() async {
    final files = _selectedFiles;
    if (files.isEmpty) return;

    var failed = 0;
    for (final file in files) {
      try {
        await ReceiptStorage.restore(file);
      } catch (_) {
        failed++;
      }
    }

    _selectedPaths.clear();
    await _reloadSaved();
    await _loadTrash();

    _showSnack(
      failed == 0
          ? '${_countText(files.length)} restored.'
          : '${files.length - failed} restored. $failed could not be restored.',
    );
  }

  // ---------- UI ----------

  Widget _buildReceiptGrid(List<File> files) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 8),
      // 3 per row. Change to 2 for even bigger images.
      // childAspectRatio 1 = width and height are the same (square).
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 0,
        mainAxisSpacing: 0,
        childAspectRatio: 1,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final selected = _selectedPaths.contains(file.path);
        final cellKey = _cellKeys.putIfAbsent(file.path, () => GlobalKey());

        return GestureDetector(
          onTap: () {
            if (_isSelecting) {
              _toggleSelection(file);
            } else {
              _openReceipt(file, files);
            }
          },
          // Hold to start selecting, then slide down or up.
          onLongPressStart: (d) => _startDrag(file, d.globalPosition),
          onLongPressMoveUpdate: (d) => _dragMove(d.globalPosition),
          onLongPressEnd: (_) => _endDrag(),
          onLongPressCancel: _endDrag,
          child: Container(
            key: cellKey,
            child: AnimatedScale(
              scale: selected ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  color: Colors.white,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Full width from the top, so Num / FR / SR are visible.
                      Image.file(
                        file,
                        fit: BoxFit.fitWidth,
                        alignment: Alignment.topCenter,
                        cacheWidth: 600,
                        errorBuilder:
                            (_, _, _) => const Icon(Icons.broken_image),
                      ),
                      Positioned(
                        top: 2,
                        left: 2,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${files.length - index}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          color: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            _formatReceiptTime(file),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),

                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: selected ? 1 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: Container(
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                      ),

                      Positioned(
                        top: 4,
                        right: 4,
                        child: AnimatedOpacity(
                          opacity: _isSelecting ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: selected ? Colors.blue : Colors.white,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateSection(String title, List<File> files) {
    final allSelected = _isSectionAllSelected(files);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed height, so the layout does not jump when selecting starts.
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_isSelecting)
                  TextButton.icon(
                    onPressed: () => _toggleSectionSelection(files),
                    icon: Icon(
                      allSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 20,
                    ),
                    label: Text(allSelected ? 'Deselect all' : 'Select all'),
                  ),
              ],
            ),
          ),
        ),
        _buildReceiptGrid(files),
      ],
    );
  }

  Widget _actionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
    );
  }

  Widget _buildSelectionBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children:
              _inTrash
                  ? [
                    Expanded(
                      child: _actionButton(
                        onPressed: _restoreSelected,
                        icon: Icons.restore,
                        label: 'Restore',
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        onPressed: _deleteSelectedForever,
                        icon: Icons.delete_forever,
                        label: 'Delete forever',
                        color: Colors.red,
                      ),
                    ),
                  ]
                  : [
                    Expanded(
                      child: _actionButton(
                        onPressed: _moveSelectedToTrash,
                        icon: Icons.delete,
                        label: 'Delete',
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        onPressed: _showCalculationDialog,
                        icon: Icons.calculate,
                        label: 'Calculate',
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        onPressed: () => _shareFiles(_selectedFiles),
                        icon: Icons.share,
                        label: 'Share',
                        color: const Color(0xFF25D366),
                      ),
                    ),
                  ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupReceipts();

    final orderedTitles = <String>[];
    if (groups.containsKey('Today')) orderedTitles.add('Today');
    if (groups.containsKey('Yesterday')) orderedTitles.add('Yesterday');

    final olderTitles =
        groups.keys
            .where((title) => title != 'Today' && title != 'Yesterday')
            .toList()
          ..sort((a, b) {
            final dateA = groups[a]!.first.lastModifiedSync();
            final dateB = groups[b]!.first.lastModifiedSync();
            return dateB.compareTo(dateA);
          });

    orderedTitles.addAll(olderTitles);

    Widget title;
    if (_isSelecting) {
      title = Text('${_selectedPaths.length} selected');
    } else if (_inTrash) {
      title = Text('Trash (${_trash.length})');
    } else {
      title = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Tokens ($_todayCount)'),
          if (_trash.isNotEmpty)
            IconButton(
              tooltip: 'Trash',
              icon: Icon(Icons.delete, color: Colors.red.shade700),
              onPressed:
                  () => setState(() {
                    _inTrash = true;
                    _selectedPaths.clear();
                  }),
            ),
        ],
      );
    }

    Widget? leading;
    if (_isSelecting) {
      leading = IconButton(
        onPressed: () => setState(() => _selectedPaths.clear()),
        icon: const Icon(Icons.close),
      );
    } else if (_inTrash) {
      leading = IconButton(
        tooltip: 'Back to tokens',
        onPressed: () => setState(() => _inTrash = false),
        icon: const Icon(Icons.arrow_back),
      );
    }

    return PopScope(
      canPop: !_inTrash,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _inTrash) {
          setState(() {
            _inTrash = false;
            _selectedPaths.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: _inTrash ? const Color(0xFFFDECEC) : null,
        appBar: AppBar(
          backgroundColor: _inTrash ? Colors.red.shade700 : null,
          foregroundColor: _inTrash ? Colors.white : null,
          leading: leading,
          title: title,
          actions: [
            if (_isSelecting)
              IconButton(
                tooltip:
                    _isEverythingSelected
                        ? 'Deselect all'
                        : 'Select everything',
                icon: Icon(
                  _isEverythingSelected ? Icons.deselect : Icons.select_all,
                ),
                onPressed: _toggleSelectEverything,
              ),
          ],
        ),
        body:
            _current.isEmpty
                ? Center(
                  child: Text(
                    _inTrash ? 'Trash is empty' : 'No images saved yet',
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
                : ListView(
                  key: _listKey,
                  controller: _scroll,
                  children: [
                    for (final t in orderedTitles)
                      _buildDateSection(t, groups[t]!),
                    const SizedBox(height: 8),
                  ],
                ),
        // The bar slides in and out smoothly.
        bottomNavigationBar: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _isSelecting ? _buildSelectionBar() : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
