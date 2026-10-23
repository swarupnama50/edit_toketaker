import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

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

  void _openReceipt(File file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (context) => Scaffold(
              appBar: AppBar(title: const Text('Receipt')),
              body: SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 5,
                          child: Image.file(
                            file,
                            fit: BoxFit.contain,
                            errorBuilder:
                                (_, _, _) =>
                                    const Icon(Icons.broken_image, size: 60),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton.icon(
                          onPressed: () => _shareFiles([file]),
                          icon: const Icon(Icons.share),
                          label: const Text('Share to WhatsApp'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
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

  @override
  Widget build(BuildContext context) {
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
              : GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.72,
                ),
                itemCount: _receipts.length,
                itemBuilder: (context, index) {
                  final file = _receipts[index];
                  final selected = _selectedPaths.contains(file.path);

                  return InkWell(
                    onLongPress: () => _toggleSelection(file),
                    onTap: () {
                      if (_isSelecting) {
                        _toggleSelection(file);
                      } else {
                        _openReceipt(file);
                      }
                    },
                    child: Card(
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
                                      (_, _, _) =>
                                          const Icon(Icons.broken_image),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(6),
                                child: Text(
                                  file.path.split(Platform.pathSeparator).last,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (selected)
                            Container(
                              color: Colors.blue.withValues(alpha: 0.22),
                            ),
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
                                        color:
                                            selected
                                                ? Colors.blue
                                                : Colors.grey,
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
