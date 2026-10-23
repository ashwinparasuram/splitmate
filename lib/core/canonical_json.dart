import 'dart:convert';

/// Deterministic JSON: object keys sorted, no whitespace, integers only.
///
/// Used wherever bytes are hashed or signed, so that every device derives
/// the same change id for the same content.
String canonicalJson(Object? value) {
  final buf = StringBuffer();
  _write(buf, value);
  return buf.toString();
}

List<int> canonicalBytes(Object? value) => utf8.encode(canonicalJson(value));

void _write(StringBuffer buf, Object? v) {
  if (v == null || v is bool || v is String) {
    buf.write(jsonEncode(v));
  } else if (v is int) {
    buf.write(v);
  } else if (v is double) {
    throw ArgumentError('Floating point values are not allowed in canonical JSON');
  } else if (v is List) {
    buf.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) buf.write(',');
      _write(buf, v[i]);
    }
    buf.write(']');
  } else if (v is Map) {
    final keys = v.keys.map((k) => k as String).toList()..sort();
    buf.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(',');
      buf.write(jsonEncode(keys[i]));
      buf.write(':');
      _write(buf, v[keys[i]]);
    }
    buf.write('}');
  } else {
    throw ArgumentError('Unsupported canonical JSON value: ${v.runtimeType}');
  }
}

/// Deep structural equality via canonical form.
bool jsonEquals(Object? a, Object? b) => canonicalJson(a) == canonicalJson(b);
