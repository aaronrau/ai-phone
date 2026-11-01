import 'package:flutter/material.dart';

import '../calendar.dart';
import '../runtime.dart';
import 'common.dart';

const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay _parse(String hm) {
  final parts = hm.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts.length > 1 ? parts[1] : '0'));
}

String _clock(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$hour:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

String _date(DateTime t) => '${_dayNames[t.weekday - 1].substring(0, 3)} ${t.month}/${t.day}';

/// Weekly availability and the receptionist's own appointments. Items are
/// "busy" to callers unless marked as shareable.
class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key, required this.runtime});
  final ReceptionistRuntime runtime;

  Future<void> _pickTime(BuildContext context, DayHours day, bool start) async {
    final picked = await showTimePicker(context: context, initialTime: _parse(start ? day.start : day.end));
    if (picked == null) return;
    if (start) {
      day.start = _hm(picked);
    } else {
      day.end = _hm(picked);
    }
    await runtime.saveCalendar();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final data = runtime.calendar;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final upcoming = data.items.where((i) => !i.end.isBefore(today)).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
      children: [
        Row(
          children: [
            Expanded(child: Text('Upcoming', style: text.titleMedium)),
            TextButton.icon(
              onPressed: () => _edit(context, null),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ],
        ),
        if (upcoming.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Nothing planned.', style: text.bodyMedium)),
        for (final item in upcoming)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(item.title.isEmpty ? '(untitled)' : item.title, style: text.titleSmall),
            subtitle: Muted('${_date(item.start)} · ${item.allDay ? 'All day' : '${_clock(item.start)}–${_clock(item.end)}'}'
                ' · ${item.shareDetails ? 'Shared with callers' : 'Callers hear "busy"'}'),
            onTap: () => _edit(context, item),
          ),
        const SizedBox(height: 12),
        Text('Working hours', style: text.titleMedium),
        const Muted('When the assistant can say you are free.'),
        const SizedBox(height: 4),
        for (final day in data.week)
          SizedBox(
            height: 48,
            child: Row(
              children: [
                SizedBox(width: 56, child: Text(_dayNames[day.weekday - 1].substring(0, 3), style: text.bodyMedium)),
                Expanded(
                  child: day.enabled
                      ? Row(
                          children: [
                            TextButton(
                                onPressed: () => _pickTime(context, day, true), child: Text(_friendly(day.start))),
                            const Text('–'),
                            TextButton(
                                onPressed: () => _pickTime(context, day, false), child: Text(_friendly(day.end))),
                          ],
                        )
                      : const Padding(padding: EdgeInsets.only(left: 12), child: Muted('Off')),
                ),
                Switch(
                  value: day.enabled,
                  onChanged: (value) {
                    day.enabled = value;
                    runtime.saveCalendar();
                  },
                ),
              ],
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('Use phone calendar', style: text.bodyMedium),
          subtitle: const Muted('Its events count as busy; details stay private.'),
          value: data.usePhoneCalendar,
          onChanged: (value) {
            data.usePhoneCalendar = value;
            runtime.saveCalendar();
          },
        ),
      ],
    );
  }

  /// "09:00" → "9 AM", "13:30" → "1:30 PM".
  static String _friendly(String hhmm) {
    final parts = hhmm.split(':');
    final hour = int.tryParse(parts.first) ?? 0;
    final minute = parts.length > 1 ? parts[1] : '00';
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12${minute == '00' ? '' : ':$minute'} ${hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _edit(BuildContext context, CalendarItem? existing) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _ItemDialog(existing: existing),
    );
    if (result == null) return;
    if (result.delete) {
      runtime.calendar.items.removeWhere((i) => i.id == existing?.id);
    } else if (existing == null) {
      runtime.calendar.items.add(result.item!);
    }
    await runtime.saveCalendar();
  }
}

class _EditResult {
  _EditResult(this.item, {this.delete = false});
  final CalendarItem? item;
  final bool delete;
}

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({this.existing});
  final CalendarItem? existing;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final _title = TextEditingController(text: widget.existing?.title ?? '');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late DateTime _day = widget.existing?.start ?? DateTime.now();
  late TimeOfDay _start = TimeOfDay.fromDateTime(widget.existing?.start ?? DateTime.now().add(const Duration(hours: 1)));
  late TimeOfDay _end = TimeOfDay.fromDateTime(widget.existing?.end ?? DateTime.now().add(const Duration(hours: 2)));
  late bool _allDay = widget.existing?.allDay ?? false;
  late bool _share = widget.existing?.shareDetails ?? false;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  DateTime _at(TimeOfDay t) => DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);

  void _save() {
    final start = _allDay ? DateTime(_day.year, _day.month, _day.day) : _at(_start);
    var end = _allDay ? start.add(const Duration(days: 1)) : _at(_end);
    if (!end.isAfter(start)) end = start.add(const Duration(minutes: 30));
    final item = widget.existing ??
        CalendarItem(id: DateTime.now().microsecondsSinceEpoch.toString(), title: '', start: start, end: end);
    item
      ..title = _title.text.trim()
      ..notes = _notes.text.trim()
      ..start = start
      ..end = end
      ..allDay = _allDay
      ..shareDetails = _share;
    Navigator.pop(context, _EditResult(item));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New calendar item' : 'Edit calendar item'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Date'),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _day,
                      firstDate: DateTime.now().subtract(const Duration(days: 1)),
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                    );
                    if (picked != null) setState(() => _day = picked);
                  },
                  child: Text(_date(_day)),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('All day'),
              value: _allDay,
              onChanged: (v) => setState(() => _allDay = v),
            ),
            if (!_allDay)
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: _start);
                      if (t != null) setState(() => _start = t);
                    },
                    child: Text('From ${_hm(_start)}'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final t = await showTimePicker(context: context, initialTime: _end);
                      if (t != null) setState(() => _end = t);
                    },
                    child: Text('To ${_hm(_end)}'),
                  ),
                ],
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Let the assistant share details'),
              subtitle: const Text('Off: callers only hear that you are busy.'),
              value: _share,
              onChanged: (v) => setState(() => _share = v),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(onPressed: () => Navigator.pop(context, _EditResult(null, delete: true)), child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
