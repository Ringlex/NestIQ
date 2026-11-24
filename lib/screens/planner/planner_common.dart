import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../account/account_models.dart';
import '../../household/household_models.dart';

const monthNames = [
  'styczeń',
  'luty',
  'marzec',
  'kwiecień',
  'maj',
  'czerwiec',
  'lipiec',
  'sierpień',
  'wrzesień',
  'październik',
  'listopad',
  'grudzień',
];

const monthGenitive = [
  'stycznia',
  'lutego',
  'marca',
  'kwietnia',
  'maja',
  'czerwca',
  'lipca',
  'sierpnia',
  'września',
  'października',
  'listopada',
  'grudnia',
];

const weekdayShort = ['Pn', 'Wt', 'Śr', 'Cz', 'Pt', 'So', 'Nd'];

String two(int v) => v.toString().padLeft(2, '0');

/// „27 października” albo „27 października 2027”, gdy to nie bieżący rok.
String dayLabel(DateTime d, {DateTime? now}) {
  final year = (now ?? DateTime.now()).year;
  return '${d.day} ${monthGenitive[d.month - 1]}${d.year == year ? '' : ' ${d.year}'}';
}

String timeLabel(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

/// Ile dni dzieli [due] od [today]: „dziś”, „jutro”, „za 5 dni”, „zaległe 3 dni”.
String relativeDay(DateTime due, DateTime today) {
  final days = dateOnly(due).difference(dateOnly(today)).inDays;
  if (days == 0) return 'dziś';
  if (days == 1) return 'jutro';
  if (days > 1) return 'za $days dni';
  if (days == -1) return 'zaległe od wczoraj';
  return 'zaległe ${-days} dni';
}

/// Wyświetlana nazwa profilu na podstawie identyfikatora.
class ProfileNames {
  const ProfileNames(this.profiles);

  factory ProfileNames.of(AccountController account) =>
      ProfileNames(account.profiles);

  final List<Profile> profiles;

  String of(String? id) =>
      profiles.where((p) => p.id == id).firstOrNull?.name ?? 'Ktoś';

  Profile? profile(String? id) => profiles.where((p) => p.id == id).firstOrNull;
}

void showError(BuildContext context, Object error) {
  final text = error is ApiException
      ? error.message
      : 'Coś poszło nie tak. Spróbuj ponownie.';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Wykonuje akcję i pokazuje błąd zamiast wyjątku. Zwraca, czy się udało.
Future<bool> guarded(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

Future<bool> confirmDialog(
    BuildContext context, String title, String body, String action) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anuluj')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// Pusty ekran z ikoną i wyjaśnieniem.
class PlannerEmpty extends StatelessWidget {
  const PlannerEmpty(
      {super.key,
      required this.icon,
      required this.title,
      required this.message});

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle),
              child: Icon(icon,
                  size: 30, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
