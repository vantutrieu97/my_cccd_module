import 'package:cccd_vietnam/dmrtd.dart';
import 'package:intl/intl.dart';

import 'mrtd_data.dart';

final DateFormat kDisplayDateFormat = DateFormat('dd/MM/yyyy');

DateTime? tryParseDisplayDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    return kDisplayDateFormat.parseStrict(raw.trim());
  } catch (_) {
    return null;
  }
}

/// Chuỗi đưa vào `DBAKey` cho BAC: chỉ lấy chữ số; nếu dài hơn 9 thì **9 chữ số cuối**
/// (người dùng có thể nhập cả 12 số CCCD — BAC vẫn dùng đúng 9 số cuối).
String normalizeDocNumberForRead(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '';
  if (digits.length <= 9) return digits;
  return digits.substring(digits.length - 9);
}

String formatMRZ(MRZ mrz) =>
    'MRZ\n'
    '  version: ${mrz.version}\n'
    '  doc code: ${mrz.documentCode}\n'
    '  doc No.: ${mrz.documentNumber}\n'
    '  country: ${mrz.country}\n'
    '  nationality: ${mrz.nationality}\n'
    '  name: ${mrz.firstName}\n'
    '  surname: ${mrz.lastName}\n'
    '  gender: ${mrz.gender}\n'
    '  date of birth: ${kDisplayDateFormat.format(mrz.dateOfBirth)}\n'
    '  date of expiry: ${kDisplayDateFormat.format(mrz.dateOfExpiry)}\n'
    '  add. data: ${mrz.optionalData}\n'
    '  add. data: ${mrz.optionalData2}';

String genderNormalizedFromMrz(String raw) {
  final t = raw.trim().toUpperCase();
  if (t.startsWith('M')) return 'MALE';
  if (t.startsWith('F')) return 'FEMALE';
  return raw.trim();
}

String mrzVersionToString(Object? version) => version.toString();

int? ageYearsFromBirth(DateTime birth) {
  final now = DateTime.now();
  var age = now.year - birth.year;
  if (now.month < birth.month || (now.month == birth.month && now.day < birth.day)) {
    age--;
  }
  if (age < 0 || age > 130) return null;
  return age;
}

/// JSON trả về Android host (key đồng bộ [CccdFlutterModule] / dialog preview).
Map<String, dynamic> buildCccdScanResultMapSync({
  required MrtdData data,
  required double readDurationSeconds,
  required String fallbackDoc,
  required String fallbackDob,
  required String fallbackDoe,
  String? dg2ImagePath,
}) {
  final m = data.dg1?.mrz;
  final age = m != null ? ageYearsFromBirth(m.dateOfBirth) : null;
  final fullFromMrz = m != null ? '${m.lastName} ${m.firstName}'.trim() : '';

  Map<String, dynamic>? dg1;
  if (m != null) {
    dg1 = {
      'mrzFormatted': formatMRZ(m),
      'version': mrzVersionToString(m.version),
      'documentCode': m.documentCode,
      'documentNumber': m.documentNumber,
      'country': m.country,
      'nationality': m.nationality,
      'firstName': m.firstName,
      'lastName': m.lastName,
      'fullName': fullFromMrz,
      'gender': m.gender,
      'genderNormalized': genderNormalizedFromMrz(m.gender),
      'dateOfBirth': kDisplayDateFormat.format(m.dateOfBirth),
      'dateOfExpiry': kDisplayDateFormat.format(m.dateOfExpiry),
      if (age != null) 'age': age,
      'optionalData': m.optionalData,
      'optionalData2': m.optionalData2,
    };
  }

  final map = <String, dynamic>{
    'readDurationSeconds': readDurationSeconds,
    /// Host dùng để biết chip có EF.DG1/MRZ đầy đủ hay không (hai loại chip).
    'dg1Present': m != null,
    'cccd': (m?.documentNumber ?? fallbackDoc).trim(),
    'dob': m != null ? kDisplayDateFormat.format(m.dateOfBirth) : fallbackDob.trim(),
    'doe': m != null ? kDisplayDateFormat.format(m.dateOfExpiry) : fallbackDoe.trim(),
    if (m != null) ...{
      'firstName': m.firstName,
      'lastName': m.lastName,
      'fullName': fullFromMrz,
      'gender': m.gender,
      'genderNormalized': genderNormalizedFromMrz(m.gender),
      'nationality': m.nationality,
      'country': m.country,
      'documentCode': m.documentCode,
      'mrzVersion': mrzVersionToString(m.version),
      if (age != null) 'age': age,
    },
    'hasDg2Photo': data.dg2 != null,
    if (dg1 != null) 'dg1': dg1,
  };
  if (dg2ImagePath != null) map['dg2ImagePath'] = dg2ImagePath;
  return map;
}
