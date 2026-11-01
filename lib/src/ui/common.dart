import 'package:flutter/material.dart';

/// "+15555550100" → "(555) 555-0100". Short codes and other formats pass through.
String formatPhone(String number) {
  final digits = number.replaceAll(RegExp(r'[^\d]'), '');
  final String national;
  if (digits.length == 11 && digits.startsWith('1')) {
    national = digits.substring(1);
  } else if (digits.length == 10 && !number.trim().startsWith('+')) {
    national = digits;
  } else {
    return number; // short codes and international numbers
  }
  return '(${national.substring(0, 3)}) ${national.substring(3, 6)}-${national.substring(6)}';
}

/// A name, or the formatted number when there is no name.
String displayName(String nameOrNumber) =>
    RegExp(r'^\+?[\d\s()-]{7,}$').hasMatch(nameOrNumber.trim()) ? formatPhone(nameOrNumber) : nameOrNumber;

/// One row of text tabs with counts, e.g. "Important 3 · Spam 1"; scrolls
/// sideways instead of wrapping.
class FilterTabs<T> extends StatelessWidget {
  const FilterTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
    this.count,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final int Function(T value)? count;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in values)
            InkWell(
              onTap: () => onSelected(value),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: value == selected ? colors.onSurface : Colors.transparent,
                    ),
                  ),
                ),
                child: Text(
                  count == null ? label(value) : '${label(value)} ${count!(value)}',
                  style: text.labelLarge?.copyWith(
                    color: value == selected ? colors.onSurface : colors.onSurfaceVariant,
                    fontWeight: value == selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Short secondary text in the theme's muted color.
class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.maxLines});
  final String text;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
}
