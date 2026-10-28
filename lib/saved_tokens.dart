import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

class SavedReceiptsScreen extends StatefulWidget {
  final List<File> receipts;

  const SavedReceiptsScreen({super.key, required this.receipts});

  @override
  State<SavedReceiptsScreen> createState() => _SavedReceiptsScreenState();
}

class _SavedReceiptsScreenState extends State<SavedReceiptsScreen> {
  late List<File> _receipts;
  final Set<String> _selectedPaths = {};

  bool get _isSelecting => _selectedPaths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _receipts = List<File>.from(widget.receipts);
    _sortReceipts();
  }

  void _sortReceipts() {
    _receipts.sort(
      (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
    );
  }

  // Show only the time below each saved receipt image.
  String _formatReceiptTime(File file) {
    final date = file.lastModifiedSync();

    final hour12 = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final period = date.hour >= 12 ? 'PM' : 'AM';

    String two(int n) => n.toString().padLeft(2, '0');

    return '${two(hour12)}:${two(date.minute)} $period';
  }

  DateTime _dateOnly(DateTime date) {
    return DateTime(date.year, date.month, date.day);
  }

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

    for (final file in _receipts) {
      final title = _sectionTitle(file);
      groups.putIfAbsent(title, () => []).add(file);
    }

    return groups;
  }

  void _toggleSelection(File file) {
    setState(() {
      if (_selectedPaths.contains(file.path)) {
        _selectedPaths.remove(file.path);
      } else {
        _selectedPaths.add(file.path);
      }
    });
  }

  void _openReceipt(File file, List<File> dayFiles) {
    final initialIndex = dayFiles.indexWhere((item) => item.path == file.path);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => ReceiptViewerScreen(
              files: dayFiles,
              initialIndex: initialIndex < 0 ? 0 : initialIndex,
              onShare: (file) => _shareFiles([file]),
            ),
      ),
    );
  }

  Future<void> _shareFiles(List<File> files) async {
    final existingFiles = <File>[];

    for (final file in files) {
      if (await file.exists()) {
        existingFiles.add(file);
      }
    }

    if (!mounted) return;

    if (existingFiles.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No receipt images found.')));
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(
          files:
              existingFiles
                  .map((file) => XFile(file.path, mimeType: 'image/jpeg'))
                  .toList(),
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );

      if (mounted && _isSelecting) {
        setState(() => _selectedPaths.clear());
      }
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to share receipts: $e')));
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedPaths.isEmpty) return;

    final count = _selectedPaths.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Delete receipts?'),
            content: Text(
              'Are you sure you want to delete $count selected '
              '${count == 1 ? 'receipt' : 'receipts'}? '
              'This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    final pathsToDelete = Set<String>.from(_selectedPaths);
    final failedPaths = <String>[];

    for (final path in pathsToDelete) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        failedPaths.add(path);
      }
    }

    if (!mounted) return;

    setState(() {
      _receipts.removeWhere(
        (file) =>
            pathsToDelete.contains(file.path) &&
            !failedPaths.contains(file.path),
      );
      _selectedPaths.clear();
      _sortReceipts();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failedPaths.isEmpty
              ? '$count ${count == 1 ? 'receipt' : 'receipts'} deleted.'
              : '${count - failedPaths.length} deleted. '
                  '${failedPaths.length} could not be deleted.',
        ),
      ),
    );
  }

  Widget _buildReceiptGrid(List<File> files) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.72,
      ),
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final selected = _selectedPaths.contains(file.path);

        return InkWell(
          onLongPress: () => _toggleSelection(file),
          onTap: () {
            if (_isSelecting) {
              _toggleSelection(file);
            } else {
              _openReceipt(file, files);
            }
          },
          child: Card(
            color: Colors.white,
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    Expanded(
                      child: Image.file(
                        file,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        errorBuilder:
                            (_, _, _) => const Icon(Icons.broken_image),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        _formatReceiptTime(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
                if (selected)
                  Container(color: Colors.blue.withValues(alpha: 0.22)),
                Positioned(
                  top: 6,
                  right: 6,
                  child: AnimatedOpacity(
                    opacity: _isSelecting ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child:
                        _isSelecting
                            ? Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: selected ? Colors.blue : Colors.grey,
                              size: 28,
                            )
                            : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDateSection(String title, List<File> files) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        _buildReceiptGrid(files),
      ],
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

    return Scaffold(
      appBar: AppBar(
        leading:
            _isSelecting
                ? IconButton(
                  onPressed: () {
                    setState(() => _selectedPaths.clear());
                  },
                  icon: const Icon(Icons.close),
                )
                : null,
        title: Text(
          _isSelecting
              ? '${_selectedPaths.length} selected'
              : 'Saved Tokens (${_receipts.length})',
        ),
      ),
      body:
          _receipts.isEmpty
              ? const Center(child: Text('No saved receipts yet.'))
              : ListView(
                children: [
                  for (final title in orderedTitles)
                    _buildDateSection(title, groups[title]!),
                  const SizedBox(height: 8),
                ],
              ),
      bottomNavigationBar:
          _isSelecting
              ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            final selectedFiles =
                                _receipts
                                    .where(
                                      (file) =>
                                          _selectedPaths.contains(file.path),
                                    )
                                    .toList();

                            _shareFiles(selectedFiles);
                          },
                          icon: const Icon(Icons.share),
                          label: const Text('Share'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _deleteSelected,
                          icon: const Icon(Icons.delete),
                          label: const Text('Delete'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              : null,
    );
  }
}

class ReceiptViewerScreen extends StatefulWidget {
  final List<File> files;
  final int initialIndex;
  final Future<void> Function(File file) onShare;

  const ReceiptViewerScreen({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.onShare,
  });

  @override
  State<ReceiptViewerScreen> createState() => _ReceiptViewerScreenState();
}

class _ReceiptViewerScreenState extends State<ReceiptViewerScreen> {
  late final PageController _pageController;
  late final List<PhotoViewScaleStateController> _scaleControllers;

  late int _currentIndex;

  @override
  void initState() {
    super.initState();

    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);

    _scaleControllers = List.generate(
      widget.files.length,
      (_) => PhotoViewScaleStateController(),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();

    for (final controller in _scaleControllers) {
      controller.dispose();
    }

    super.dispose();
  }

  void _toggleZoom() {
    final controller = _scaleControllers[_currentIndex];

    setState(() {
      if (controller.scaleState.isScaleStateZooming) {
        controller.scaleState = PhotoViewScaleState.initial;
      } else {
        controller.scaleState = PhotoViewScaleState.zoomedIn;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Token ${_currentIndex + 1}/${widget.files.length}'),
        actions: [
          IconButton(
            tooltip: 'Toggle zoom',
            icon: const Icon(Icons.zoom_in),
            onPressed: _toggleZoom,
          ),
        ],
      ),
      body: PhotoViewGallery.builder(
        itemCount: widget.files.length,
        pageController: _pageController,
        gaplessPlayback: true,
        backgroundDecoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        scrollPhysics: const PageScrollPhysics(),
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        builder: (context, index) {
          return PhotoViewGalleryPageOptions(
            imageProvider: FileImage(widget.files[index]),
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 5,
            scaleStateController: _scaleControllers[index],
            errorBuilder: (context, error, stackTrace) {
              return const Center(child: Icon(Icons.broken_image, size: 60));
            },
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () {
                widget.onShare(widget.files[_currentIndex]);
              },
              icon: const Icon(Icons.share),
              label: const Text('Share to WhatsApp'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF25D366),
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
