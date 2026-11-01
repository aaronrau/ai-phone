import 'config.dart';
import 'contacts.dart';

enum Workflow { known, screen, block }

/// Who is calling/texting and how the receptionist should treat them.
class Disposition {
  const Disposition(this.workflow,
      {required this.number, this.name, this.contact, this.tracked, required this.reason});

  final Workflow workflow;
  final String number;

  /// Display name from the configured list or the phone's address book.
  final String? name;
  final ContactEntry? contact;

  /// What the contact book knows about this number, if anything.
  final TrackedContact? tracked;
  final String reason;

  bool get handled => workflow != Workflow.block;

  @override
  String toString() => 'Disposition(${workflow.name}, $reason)';
}

/// Digits only, keeping a leading `+`.
String normalizeNumber(String number) {
  final trimmed = number.trim();
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  return trimmed.startsWith('+') ? '+$digits' : digits;
}

/// Matches numbers that differ only by country code / trunk prefix by
/// comparing the last ten digits (or the whole number when shorter).
bool sameNumber(String a, String b) {
  final x = normalizeNumber(a).replaceAll('+', '');
  final y = normalizeNumber(b).replaceAll('+', '');
  if (x.isEmpty || y.isEmpty) return false;
  if (x == y) return true;
  final n = 10;
  if (x.length < 7 || y.length < 7) return false;
  final tx = x.length > n ? x.substring(x.length - n) : x;
  final ty = y.length > n ? y.substring(y.length - n) : y;
  return tx == ty;
}

bool isWithheld(String number) {
  final n = normalizeNumber(number);
  return n.isEmpty || n.replaceAll('+', '').length < 3;
}

/// Short codes (bank OTPs, carriers, marketing) are never conversed with.
bool isShortCode(String number) {
  final digits = normalizeNumber(number).replaceAll('+', '');
  return digits.isNotEmpty && digits.length < 7;
}

class CallerPolicy {
  CallerPolicy(this.config, [ContactBook? book]) : book = book ?? ContactBook.empty();
  final ReceptionistConfig config;
  final ContactBook book;

  /// [phoneContactName] is the address-book name for [number], if any.
  /// Texts are only handled for known contacts; everyone else is ignored.
  Disposition classify(String number, {String? phoneContactName, bool sms = false}) {
    final tracked = book.find(number);
    final trackedName = tracked != null && tracked.name.isNotEmpty ? tracked.name : null;
    if (tracked?.status == ContactStatus.blocked) {
      return Disposition(Workflow.block, number: number, name: trackedName, tracked: tracked,
          reason: tracked!.blockReason.isEmpty ? 'blocked contact' : tracked.blockReason);
    }
    for (final blocked in config.blockedNumbers) {
      if (sameNumber(blocked, number)) {
        return Disposition(Workflow.block, number: number, tracked: tracked, reason: 'blocked list');
      }
    }
    for (final contact in config.contacts) {
      if (contact.numbers.any((n) => sameNumber(n, number))) {
        if (contact.workflow == 'block') {
          return Disposition(Workflow.block, number: number, name: contact.name, contact: contact,
              tracked: tracked, reason: 'contact marked block');
        }
        return Disposition(Workflow.known, number: number, name: contact.name, contact: contact,
            tracked: tracked, reason: 'configured contact');
      }
    }
    if (tracked?.status == ContactStatus.known) {
      return Disposition(Workflow.known, number: number, name: tracked!.label, tracked: tracked,
          reason: 'known contact');
    }
    if (config.usePhoneContacts && phoneContactName != null && phoneContactName.trim().isNotEmpty) {
      return Disposition(Workflow.known, number: number, name: phoneContactName.trim(), tracked: tracked,
          reason: 'phone contact');
    }
    if (sms) {
      return Disposition(Workflow.block, number: number, name: trackedName, tracked: tracked,
          reason: isShortCode(number) ? 'short code' : 'texts are only answered for known contacts');
    }
    if (tracked?.status == ContactStatus.screened) {
      return Disposition(Workflow.screen, number: number, name: trackedName, tracked: tracked,
          reason: 'previously screened');
    }
    final withheld = isWithheld(number);
    for (final rule in config.screeningRules) {
      final matched = switch (rule.type) {
        'any' => !withheld,
        'withheld' => withheld,
        'prefix' => !withheld && normalizeNumber(number).startsWith(normalizeNumber(rule.value)),
        'regex' => !withheld && _regex(rule.value)?.hasMatch(normalizeNumber(number)) == true,
        _ => false,
      };
      if (matched) {
        return Disposition(Workflow.screen, number: number, name: trackedName, tracked: tracked,
            reason: 'screening rule ${rule.type}${rule.value.isEmpty ? '' : ' ${rule.value}'}');
      }
    }
    return Disposition(Workflow.block, number: number, tracked: tracked,
        reason: withheld ? 'withheld number' : 'no rule matched');
  }

  static RegExp? _regex(String pattern) {
    try {
      return RegExp(pattern);
    } on FormatException {
      return null;
    }
  }
}
