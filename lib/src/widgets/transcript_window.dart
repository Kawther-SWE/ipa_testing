import 'package:flutter/material.dart';

import 'package:my_project/src/core/app_constants.dart';

class TranscriptWindow extends StatefulWidget {
  const TranscriptWindow({
    super.key,
    required this.text,
    required this.fontSize,
    required this.textColor,
    required this.collapsed,
    required this.onCopy,
    required this.onClear,
  });

  final String text;
  final double fontSize;
  final Color textColor;
  final bool collapsed;
  final VoidCallback onCopy;
  final VoidCallback onClear;

  @override
  State<TranscriptWindow> createState() => _TranscriptWindowState();
}

class _TranscriptWindowState extends State<TranscriptWindow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TranscriptWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _maybeAutoScroll();
    }
  }

  void _maybeAutoScroll() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    if (max - current < 40) {
      _scrollController.jumpTo(max);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.collapsed
        ? const Size(kBubbleSize, kBubbleSize)
        : const Size(kOverlayWidth, kOverlayHeight);

    if (widget.collapsed) {
      return SizedBox(
        width: size.width,
        height: size.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.teal.shade700.withValues(alpha: 0.9),
            shape: BoxShape.circle,
          ),
          child: const Center(
            child: Icon(Icons.hearing, color: Colors.white),
          ),
        ),
      );
    }

    final textDirection = _directionForText(widget.text);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Material(
        color: Colors.black.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    primary: false,
                    controller: _scrollController,
                    child: Text(
                      widget.text.isEmpty ? '...' : widget.text,
                      textDirection: textDirection,
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: widget.fontSize,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white12)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  const Text(
                    'Actions',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onClear,
                    icon: const Icon(Icons.clear_all, color: Colors.white),
                    tooltip: 'Clear text',
                  ),
                  IconButton(
                    onPressed: widget.onCopy,
                    icon: const Icon(Icons.copy, color: Colors.white),
                    tooltip: 'Copy text',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextDirection _directionForText(String text) {
    final hasArabic = RegExp(r'[\u0600-\u06FF]').hasMatch(text);
    return hasArabic ? TextDirection.rtl : TextDirection.ltr;
  }
}
