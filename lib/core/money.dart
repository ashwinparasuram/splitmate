/// Currency metadata and integer minor-unit money helpers.
///
/// All money in SplitMate is an `int` count of the currency's minor unit
/// (paise, cents, fils...). Floating point never touches an amount.
class Currency {
  const Currency(this.code, this.exponent, this.symbol, this.name);

  final String code;

  /// ISO-4217 minor-unit exponent: 2 means 1 unit = 100 minor units.
  final int exponent;
  final String symbol;
  final String name;

  int get minorPerMajor => _pow10(exponent);

  static const _known = <Currency>[
    Currency('INR', 2, '₹', 'Indian Rupee'),
    Currency('USD', 2, '\$', 'US Dollar'),
    Currency('EUR', 2, '€', 'Euro'),
    Currency('GBP', 2, '£', 'British Pound'),
    Currency('AUD', 2, 'A\$', 'Australian Dollar'),
    Currency('CAD', 2, 'C\$', 'Canadian Dollar'),
    Currency('SGD', 2, 'S\$', 'Singapore Dollar'),
    Currency('AED', 2, 'AED ', 'UAE Dirham'),
    Currency('CHF', 2, 'CHF ', 'Swiss Franc'),
    Currency('CNY', 2, 'CN¥', 'Chinese Yuan'),
    Currency('THB', 2, '฿', 'Thai Baht'),
    Currency('JPY', 0, '¥', 'Japanese Yen'),
    Currency('KRW', 0, '₩', 'South Korean Won'),
    Currency('VND', 0, '₫', 'Vietnamese Dong'),
    Currency('IDR', 2, 'Rp ', 'Indonesian Rupiah'),
    Currency('KWD', 3, 'KD ', 'Kuwaiti Dinar'),
    Currency('BHD', 3, 'BD ', 'Bahraini Dinar'),
    Currency('OMR', 3, 'OMR ', 'Omani Rial'),
  ];

  static final Map<String, Currency> _byCode = {
    for (final c in _known) c.code: c,
  };

  static List<Currency> get all => List.unmodifiable(_known);

  static bool isSupported(String code) => _byCode.containsKey(code);

  static Currency of(String code) {
    final c = _byCode[code];
    if (c == null) throw ArgumentError.value(code, 'code', 'Unsupported currency');
    return c;
  }

  @override
  bool operator ==(Object other) => other is Currency && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

int _pow10(int e) {
  var r = 1;
  for (var i = 0; i < e; i++) {
    r *= 10;
  }
  return r;
}

class MoneyFormatException implements Exception {
  MoneyFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses user-entered text such as "1,200.50" into minor units.
///
/// Rejects more fractional digits than the currency supports rather than
/// silently rounding.
int parseMinor(String input, Currency currency) {
  final text = input.trim().replaceAll(',', '').replaceAll('_', '');
  if (text.isEmpty) throw MoneyFormatException('Enter an amount');
  final match = RegExp(r'^(\d+)(?:\.(\d*))?$').firstMatch(text);
  if (match == null) throw MoneyFormatException('Enter a valid amount');
  final whole = match.group(1)!;
  final frac = match.group(2) ?? '';
  if (frac.length > currency.exponent) {
    throw MoneyFormatException(currency.exponent == 0
        ? '${currency.code} has no fractional units'
        : '${currency.code} allows at most ${currency.exponent} decimal places');
  }
  if (whole.length > 13) throw MoneyFormatException('Amount is too large');
  final padded = frac.padRight(currency.exponent, '0');
  return int.parse(whole) * currency.minorPerMajor +
      (padded.isEmpty ? 0 : int.parse(padded));
}

/// Formats minor units as a plain decimal string with the currency's precision.
String formatDecimal(int minor, Currency currency) {
  final negative = minor < 0;
  final abs = minor.abs();
  final whole = abs ~/ currency.minorPerMajor;
  final frac = abs % currency.minorPerMajor;
  final wholeStr = _group(whole.toString());
  final body = currency.exponent == 0
      ? wholeStr
      : '$wholeStr.${frac.toString().padLeft(currency.exponent, '0')}';
  return negative ? '-$body' : body;
}

/// Formats minor units with the currency symbol, e.g. `₹1,200.00`.
String formatMoney(int minor, String currencyCode) {
  final c = Currency.of(currencyCode);
  final body = formatDecimal(minor.abs(), c);
  return '${minor < 0 ? '-' : ''}${c.symbol}$body';
}

String _group(String digits) {
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return buf.toString();
}

/// Parses a percentage like "33.33" into basis points (3333).
int parseBasisPoints(String input) {
  final text = input.trim();
  final match = RegExp(r'^(\d{1,3})(?:\.(\d{0,2}))?$').firstMatch(text);
  if (match == null) throw MoneyFormatException('Enter a percentage like 33.33');
  final whole = int.parse(match.group(1)!);
  final frac = (match.group(2) ?? '').padRight(2, '0');
  final bp = whole * 100 + int.parse(frac);
  if (bp > 10000) throw MoneyFormatException('Percentage cannot exceed 100');
  return bp;
}

String formatBasisPoints(int bp) =>
    '${bp ~/ 100}.${(bp % 100).toString().padLeft(2, '0')}';
