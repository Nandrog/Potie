import 'package:intl/intl.dart';

final _money = NumberFormat.decimalPattern();
final _time = DateFormat('HH:mm');
final _dateTime = DateFormat('d MMM, HH:mm');
final _date = DateFormat('EEE d MMM yyyy');

String money(num v) => _money.format(v);
String hm(DateTime d) => _time.format(d);
String dateTime(DateTime d) => _dateTime.format(d);
String dateOnly(DateTime d) => _date.format(d);

String percent(double fraction) => '${(fraction * 100).round()}%';

String minutesLabel(int m) {
  final h = m ~/ 60, r = m % 60;
  if (h == 0) return '$r min';
  if (r == 0) return '${h}h';
  return '${h}h ${r}m';
}

String countdown(Duration d) {
  final neg = d.isNegative;
  final a = d.abs();
  final h = a.inHours;
  final m = (a.inMinutes % 60).toString().padLeft(2, '0');
  final s = (a.inSeconds % 60).toString().padLeft(2, '0');
  final body = h > 0 ? '$h:$m:$s' : '$m:$s';
  return neg ? '-$body' : body;
}
