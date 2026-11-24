import 'viessmann_models.dart';

/// Opisy usterek po polsku. Znaczenie samego kodu zna instrukcja pieca i ViCare;
/// tu opisujemy rodzaj zdarzenia i co z nim zrobić, bez zgadywania.
String faultTitle(HeatingFault fault) => switch (fault.kind) {
      FaultKind.lock => 'Blokada awaryjna pieca',
      FaultKind.error => 'Usterka pieca ${fault.code}',
      FaultKind.service => 'Komunikat serwisowy ${fault.code}',
      FaultKind.info => 'Komunikat pieca ${fault.code}',
    };

String faultKindLabel(FaultKind kind) => switch (kind) {
      FaultKind.lock => 'Blokada',
      FaultKind.error => 'Usterka',
      FaultKind.service => 'Serwis',
      FaultKind.info => 'Informacja',
    };

/// Co się wydarzyło.
String faultWhat(HeatingFault fault) => switch (fault.kind) {
      FaultKind.lock =>
        'Piec zgłosił blokadę awaryjną. Ogrzewanie i ciepła woda mogą nie działać, '
            'dopóki blokada nie zostanie zdjęta.',
      FaultKind.error => 'Piec zgłosił usterkę o kodzie ${fault.code}.',
      FaultKind.service =>
        'Piec zgłosił komunikat serwisowy o kodzie ${fault.code}. '
            'Zwykle oznacza to, że instalacja wymaga kontroli albo przeglądu.',
      FaultKind.info =>
        'Piec przekazał komunikat informacyjny o kodzie ${fault.code}. '
            'To nie jest usterka.',
    };

/// Co zrobić.
String faultAdvice(HeatingFault fault) => switch (fault.kind) {
      FaultKind.lock =>
        'Sprawdź wyświetlacz pieca i spróbuj go odblokować według instrukcji. '
            'Jeśli blokada wraca, wezwij serwis.',
      FaultKind.error =>
        'Znaczenie kodu znajdziesz w instrukcji pieca albo w aplikacji ViCare. '
            'Przy powtarzającej się usterce skontaktuj się z serwisem i podaj kod.',
      FaultKind.service =>
        'Skontaktuj się z serwisem i podaj kod. Jeśli to przegląd okresowy, umów termin.',
      FaultKind.info => 'Nic nie musisz robić.',
    };
