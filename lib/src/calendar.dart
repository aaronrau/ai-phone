import 'dart:convert';

/// Hours the owner is available on one weekday (1 = Monday … 7 = Sunday).
class DayHours {
  DayHours(this.weekday, {this.enabled = true, this.start = '09:00', this.end = '17:00'});
  final int weekday;
  bool enabled;
  String start; // HH:mm
  String end; // HH:mm

  Map<String, dynamic> toJson() => {'weekday': weekday, 'enabled': enabled, 'start': start, 'end': end};
  factory DayHours.fromJson(Map<String, dynamic> json) => DayHours(
        (json['weekday'] as num).toInt(),
        enabled: json['enabled'] != false,
        start: (json['start'] ?? '09:00').toString(),
        end: (json['end'] ?? '17:00').toString(),
      );

  static List<DayHours> defaults() => [
        for (var d = 1; d <= 7; d++) DayHours(d, enabled: d <= 5),
      ];
}

/// An appointment kept in the app. When [shareDetails] is false the assistant
/// only ever says the owner is busy at that time.
class CalendarItem {
  CalendarItem({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.notes = '',
    this.allDay = false,
    this.shareDetails = false,
  });

  final String id;
  String title;
  String notes;
  DateTime start;
  DateTime end;
  bool allDay;
  bool shareDetails;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'notes': notes,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'all_day': allDay,
        'share_details': shareDetails,
      };

  factory CalendarItem.fromJson(Map<String, dynamic> json) => CalendarItem(
        id: json['id'].toString(),
        title: (json['title'] ?? '').toString(),
        notes: (json['notes'] ?? '').toString(),
        start: DateTime.parse(json['start'].toString()),
        end: DateTime.parse(json['end'].toString()),
        allDay: json['all_day'] == true,
        shareDetails: json['share_details'] == true,
      );
}

/// The receptionist's own calendar: weekly availability plus appointments.
class CalendarData {
  CalendarData({required this.week, required this.items, this.usePhoneCalendar = true});

  final List<DayHours> week;
  final List<CalendarItem> items;

  /// Also treat events from the phone's calendars as busy (never shared).
  bool usePhoneCalendar;

  factory CalendarData.defaults() => CalendarData(week: DayHours.defaults(), items: []);

  factory CalendarData.fromJson(Map<String, dynamic> json) {
    final week = [
      for (final d in (json['week'] as List? ?? const [])) DayHours.fromJson((d as Map).cast<String, dynamic>()),
    ];
    final byDay = {for (final d in week) d.weekday: d};
    return CalendarData(
      week: [for (final d in DayHours.defaults()) byDay[d.weekday] ?? d],
      items: [
        for (final i in (json['items'] as List? ?? const []))
          CalendarItem.fromJson((i as Map).cast<String, dynamic>()),
      ],
      usePhoneCalendar: json['use_phone_calendar'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'week': [for (final d in week) d.toJson()],
        'items': [for (final i in items) i.toJson()],
        'use_phone_calendar': usePhoneCalendar,
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Working window for [day], or null when the owner is off that day.
  (DateTime, DateTime)? hoursFor(DateTime day) {
    final rule = week.firstWhere((d) => d.weekday == day.weekday);
    if (!rule.enabled) return null;
    DateTime at(String hm) {
      final parts = hm.split(':');
      return DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts.length > 1 ? parts[1] : '0'));
    }

    final start = at(rule.start), end = at(rule.end);
    return end.isAfter(start) ? (start, end) : null;
  }

  List<CalendarItem> itemsBetween(DateTime start, DateTime end) => items
      .where((i) => i.start.isBefore(end) && i.end.isAfter(start))
      .toList()
    ..sort((a, b) => a.start.compareTo(b.start));
}
