// Created by Crt Vavros, copyright © 2022 ZeroPass. All rights reserved.
// ignore_for_file: prefer_adjacent_string_concatenation, prefer_interpolation_to_compose_strings

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cccd_vietnam/dmrtd.dart';
import 'package:cccd_vietnam/extensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:logging/logging.dart';
import 'package:cccd_vietnam/src/proto/can_key.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:asn1lib/asn1lib.dart';

import 'mrtd_data.dart';
import 'cccd_host_bridge.dart';

final Map<DgTag, String> dgTagToString = {
  EfDG1.TAG: 'EF.DG1',
  EfDG2.TAG: 'EF.DG2',
  EfDG3.TAG: 'EF.DG3',
  EfDG4.TAG: 'EF.DG4',
  EfDG5.TAG: 'EF.DG5',
  EfDG6.TAG: 'EF.DG6',
  EfDG7.TAG: 'EF.DG7',
  EfDG8.TAG: 'EF.DG8',
  EfDG9.TAG: 'EF.DG9',
  EfDG10.TAG: 'EF.DG10',
  EfDG11.TAG: 'EF.DG11',
  EfDG12.TAG: 'EF.DG12',
  EfDG13.TAG: 'EF.DG13',
  EfDG14.TAG: 'EF.DG14',
  EfDG15.TAG: 'EF.DG15',
  EfDG16.TAG: 'EF.DG16',
};

String formatEfCom(final EfCOM efCom) {
  var str =
      "version: ${efCom.version}\n"
      "unicode version: ${efCom.unicodeVersion}\n"
      "DG tags:";

  for (final t in efCom.dgTags) {
    try {
      str += " ${dgTagToString[t]!}";
    } catch (e) {
      str += " 0x${t.value.toRadixString(16)}";
    }
  }
  return str;
}

String formatMRZ(final MRZ mrz) {
  return "MRZ\n"
          "  version: ${mrz.version}\n" +
      "  doc code: ${mrz.documentCode}\n" +
      "  doc No.: ${mrz.documentNumber}\n" +
      "  country: ${mrz.country}\n" +
      "  nationality: ${mrz.nationality}\n" +
      "  name: ${mrz.firstName}\n" +
      "  surname: ${mrz.lastName}\n" +
      "  gender: ${mrz.gender}\n" +
      "  date of birth: ${kDisplayDateFormat.format(mrz.dateOfBirth)}\n" +
      "  date of expiry: ${kDisplayDateFormat.format(mrz.dateOfExpiry)}\n" +
      "  add. data: ${mrz.optionalData}\n" +
      "  add. data: ${mrz.optionalData2}";
}

String formatDG15(final EfDG15 dg15) {
  var str =
      "EF.DG15:\n"
      "  AAPublicKey\n"
      "    type: ";

  final rawSubPubKey = dg15.aaPublicKey.rawSubjectPublicKey();
  if (dg15.aaPublicKey.type == AAPublicKeyType.RSA) {
    final tvSubPubKey = TLV.fromBytes(rawSubPubKey);
    var rawSeq = tvSubPubKey.value;
    if (rawSeq[0] == 0x00) {
      rawSeq = rawSeq.sublist(1);
    }

    final tvKeySeq = TLV.fromBytes(rawSeq);
    final tvModule = TLV.decode(tvKeySeq.value);
    final tvExp = TLV.decode(tvKeySeq.value.sublist(tvModule.encodedLen));

    str +=
        "RSA\n"
        "    exponent: ${tvExp.value.hex()}\n"
        "    modulus: ${tvModule.value.hex()}";
  } else {
    str += "EC\n    SubjectPublicKey: ${rawSubPubKey.hex()}";
  }
  return str;
}

String formatProgressMsg(String message, int percentProgress) {
  final p = (percentProgress / 20).round();
  final full = "🟢 " * p;
  final empty = "⚪️ " * (5 - p);
  return message + "\n\n" + full + empty;
}

/// Giới tính chuẩn cho host (CreateKyc API dùng MALE/FEMALE).
String genderNormalizedFromMrz(String raw) {
  final t = raw.trim().toUpperCase();
  if (t.startsWith('M')) return 'MALE';
  if (t.startsWith('F')) return 'FEMALE';
  return raw.trim();
}

String mrzVersionToString(dynamic version) => version.toString();

/// Tuổi tính tại thời điểm gửi về host (null nếu không hợp lệ).
int? ageYearsFromBirth(DateTime birth) {
  final now = DateTime.now();
  var age = now.year - birth.year;
  if (now.month < birth.month || (now.month == birth.month && now.day < birth.day)) {
    age--;
  }
  if (age < 0 || age > 130) return null;
  return age;
}

/// Chuẩn hóa số định danh dùng cho BAC/DBA: chỉ lấy 9 số cuối.
String normalizeDocNumberForRead(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length <= 9) return digits;
  return digits.substring(digits.length - 9);
}

/// Hiển thị / gửi về host đồng bộ với Create Profile (`dd/MM/yyyy`). BAC nhận `DateTime` từ giá trị đã parse.
final DateFormat kDisplayDateFormat = DateFormat('dd/MM/yyyy');

DateTime? tryParseDisplayDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  try {
    return kDisplayDateFormat.parseStrict(raw.trim());
  } catch (_) {
    return null;
  }
}

/// Tạm tắt: `dg2ImageBase64` làm payload nặng / bridge lỗi. Đặt `true` khi gửi ảnh lại được.
const bool kSendDg2ImageBase64ToHost = false;

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.logSensitiveData = true;
  Logger.root.onRecord.listen((record) {
    print('${record.loggerName} ${record.level.name}: ${record.time}: ${record.message}');
  });
  runApp(MaterialApp(home: MrtdHomePage(), debugShowCheckedModeBanner: false));
}

class MrtdEgApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: MrtdHomePage());
  }
}

class MrtdHomePage extends StatefulWidget {
  @override
  // ignore: library_private_types_in_public_api
  _MrtdHomePageState createState() => _MrtdHomePageState();
}

class _MrtdHomePageState extends State<MrtdHomePage> with TickerProviderStateMixin {
  var _alertMessage = "";
  final _log = Logger("mrtdeg.app");
  var _isNfcAvailable = false;
  var _isReading = false;
  final _mrzData = GlobalKey<FormState>();
  final _canData = GlobalKey<FormState>();

  /// Giá trị mặc định khi host không prefill (hoặc gửi rỗng); user vẫn sửa được trên form.
  final _docNumber = TextEditingController(text: '301005420');
  final _dob = TextEditingController(text: '16/03/2001');
  final _doe = TextEditingController(text: '16/03/2041');
  final _can = TextEditingController(text: '');
  bool _checkBoxPACE = false;

  MrtdData? _mrtdData;

  final NfcProvider _nfc = NfcProvider();

  // ignore: unused_field
  late Timer _timerStateUpdater;
  final _scrollController = ScrollController();
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: 2, vsync: this);
    //_tabController.addListener(_handleTabSelection);

    // Đồng bộ kiosk (app host ngang): module không ép dọc.
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

    _initPlatformState();
    _loadHostPrefillData();

    // Update platform state every 3 sec
    _timerStateUpdater = Timer.periodic(Duration(seconds: 3), (Timer t) {
      _initPlatformState();
    });
  }

  Future<void> _loadHostPrefillData() async {
    try {
      final map = await CccdHostBridge.getLaunchArgs();
      if (map == null) return;
      final cccd = (map['cccd'] ?? '').toString().trim();
      final dob = (map['dob'] ?? '').toString().trim();
      final doe = (map['doe'] ?? '').toString().trim();

      if (!mounted) return;
      setState(() {
        // Chỉ điền từng ô khi host gửi giá trị; để trống → vẫn nhập tay bình thường
        if (cccd.isNotEmpty) _docNumber.text = cccd;
        if (dob.isNotEmpty) _dob.text = dob;
        if (doe.isNotEmpty) _doe.text = doe;
        _tabController.index = 0;
      });
    } catch (e, st) {
      _log.warning('getLaunchArgs failed: $e\n$st');
    }
  }

  /// DG1 đầy đủ cho host (Kotlin hiển thị form / MRZ).
  Map<String, dynamic>? _dg1Payload(MrtdData data) {
    final dg1 = data.dg1;
    if (dg1 == null) return null;
    final m = dg1.mrz;
    final age = ageYearsFromBirth(m.dateOfBirth);
    return <String, dynamic>{
      'mrzFormatted': formatMRZ(m),
      'version': mrzVersionToString(m.version),
      'documentCode': m.documentCode,
      'documentNumber': m.documentNumber,
      'country': m.country,
      'nationality': m.nationality,
      'firstName': m.firstName,
      'lastName': m.lastName,
      'fullName': '${m.lastName} ${m.firstName}'.trim(),
      'gender': m.gender,
      'genderNormalized': genderNormalizedFromMrz(m.gender),
      'dateOfBirth': kDisplayDateFormat.format(m.dateOfBirth),
      'dateOfExpiry': kDisplayDateFormat.format(m.dateOfExpiry),
      if (age != null) 'age': age,
      'optionalData': m.optionalData,
      'optionalData2': m.optionalData2,
    };
  }



/// Lưu ảnh DG2 ra file cache để host đọc qua đường dẫn (tránh JSON/base64 quá nặng).
Future<String?> _persistDg2ImagePath(MrtdData data) async {
  final dg2 = data.dg2;
  if (dg2 == null) return null;
  try {
    final Uint8List? img = dg2.imageData;
    final bytes = (img != null && img.isNotEmpty) ? img : dg2.toBytes();
    if (bytes.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/dg2_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

  /// Ảnh khuôn mặt DG2 — JPEG bytes base64 cho host [BitmapFactory.decodeByteArray].
  String? _dg2ImageBase64(MrtdData data) {
    final dg2 = data.dg2;
    if (dg2 == null) return null;
    try {
      final Uint8List? img = dg2.imageData;
      if (img != null && img.isNotEmpty) return base64Encode(img);
      return base64Encode(dg2.toBytes());
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _buildScanResultMap(MrtdData data) async {
    final m = data.dg1?.mrz;
    final int? ageFromMrz = m != null ? ageYearsFromBirth(m.dateOfBirth) : null;
    final fullFromMrz = m != null ? '${m.lastName} ${m.firstName}'.trim() : '';
    final map = <String, dynamic>{
      'cccd': (m?.documentNumber ?? _docNumber.text).trim(),
      'dob': m != null ? kDisplayDateFormat.format(m.dateOfBirth) : _dob.text.trim(),
      'doe': m != null ? kDisplayDateFormat.format(m.dateOfExpiry) : _doe.text.trim(),
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
        if (ageFromMrz != null) 'age': ageFromMrz,
      },
      'isPACE': data.isPACE,
      'isDBA': data.isDBA,
      'hasDg2Photo': data.dg2 != null,
    };
    final d1 = _dg1Payload(data);
    if (d1 != null) map['dg1'] = d1;
    if (kSendDg2ImageBase64ToHost) {
      final dg2B64 = _dg2ImageBase64(data);
      if (dg2B64 != null) map['dg2ImageBase64'] = dg2B64;
    }
    final dg2Path = await _persistDg2ImagePath(data);
    if (dg2Path != null) map['dg2ImagePath'] = dg2Path;
    return map;
  }

  /// `true` khi host đã nhận lệnh đóng activity (thường là đang quay về app chính).
  Future<bool> _returnScanResultToHost(MrtdData data) async {
    if (!mounted) return false;
    final payload = await _buildScanResultMap(data);
    final ok = await CccdHostBridge.finishWithJson(payload);
    if (!ok) _log.warning('finishWithResult failed or not Android host');
    return ok;
  }

  /// Gửi số liệu đang nhập trên form về host (không cần đọc chip xong).
  Future<void> _sendFormToHost() async {
    if (_isReading) return;
    // Đã đọc chip: gửi đủ DG1 + ảnh DG2 (không dùng manual_form — host mới có dialog / ảnh).
    if (_mrtdData != null) {
      final ok = await _returnScanResultToHost(_mrtdData!);
      if (mounted && !ok) {
        setState(() => _alertMessage = 'Không gửi được về host (standalone / lỗi bridge).');
      }
      return;
    }
    final ok = await CccdHostBridge.finishWithJson({
      'cccd': _docNumber.text.trim(),
      'dob': _dob.text.trim(),
      'doe': _doe.text.trim(),
      'source': 'manual_form',
    });
    if (mounted && !ok) {
      setState(() => _alertMessage = 'Không gửi được về host (standalone / lỗi bridge).');
    }
  }

  /// Đóng module với `RESULT_OK` và JSON hủy — host đọc `cancelled` thay vì `RESULT_CANCELED`.
  Future<void> _cancelToHost() async {
    if (_isReading) return;
    final ok = await CccdHostBridge.finishWithJson({'cancelled': true, 'source': 'user_cancel'});
    if (mounted && !ok) {
      setState(() => _alertMessage = 'Không gửi được về host (standalone / lỗi bridge).');
    }
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> _initPlatformState() async {
    bool isNfcAvailable;
    try {
      NfcStatus status = await NfcProvider.nfcStatus;
      isNfcAvailable = status == NfcStatus.enabled;
    } on PlatformException {
      isNfcAvailable = false;
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _isNfcAvailable = isNfcAvailable;
    });
  }

  DateTime? _getDOBDate() => tryParseDisplayDate(_dob.text);

  DateTime? _getDOEDate() => tryParseDisplayDate(_doe.text);

  Future<String?> _pickDate(BuildContext context, DateTime firstDate, DateTime initDate, DateTime lastDate) async {
    final locale = Localizations.localeOf(context);
    final DateTime? picked = await showDatePicker(
      context: context,
      firstDate: firstDate,
      initialDate: initDate,
      lastDate: lastDate,
      locale: locale,
    );

    if (picked != null) {
      return kDisplayDateFormat.format(picked);
    }
    return null;
  }

  void _buttonPressed() async {
    print("Button pressed");
    //Check on what tab we are
    if (_tabController.index == 0) {
      //DBA tab
      String errorText = "";
      if (_doe.text.isEmpty) {
        errorText += "Please enter date of expiry!\n";
      }
      if (_dob.text.isEmpty) {
        errorText += "Please enter date of birth!\n";
      }
      if (_docNumber.text.isEmpty) {
        errorText += "Please enter passport number!";
      }

      setState(() {
        _alertMessage = errorText;
      });
      //If there is an error, just jump out of the function
      if (errorText.isNotEmpty) return;

      if (_getDOBDate() == null || _getDOEDate() == null) {
        setState(() {
          _alertMessage = 'Ngày sinh / ngày hết hạn: dùng đúng DD/MM/YYYY (vd. 16/03/2001).';
        });
        return;
      }

      final docForBac = normalizeDocNumberForRead(_docNumber.text);
      if (docForBac.isEmpty) {
        setState(() => _alertMessage = 'Please enter passport number!');
        return;
      }
      final bacKeySeed = DBAKey(docForBac, _getDOBDate()!, _getDOEDate()!, paceMode: _checkBoxPACE);
      _readMRTD(accessKey: bacKeySeed, isPace: _checkBoxPACE);
    } else {
      //PACE tab
      String errorText = "";
      if (_can.text.isEmpty) {
        errorText = "Please enter CAN number!";
      } else if (_can.text.length != 6) {
        errorText = "CAN number must be exactly 6 digits long!";
      }

      setState(() {
        _alertMessage = errorText;
      });
      //If there is an error, just jump out of the function
      if (errorText.isNotEmpty) return;

      final canKeySeed = CanKey(_can.text);
      _readMRTD(accessKey: canKeySeed, isPace: true);
    }
  }

  void _readMRTD({required AccessKey accessKey, bool isPace = false}) async {
    try {
      setState(() {
        _mrtdData = null;
        _alertMessage = "Waiting for CCCD tag ...";
        _isReading = true;
      });
      try {
        bool demo = false;
        if (!demo) await _nfc.connect(iosAlertMessage: "Hold your phone near Biometric Passport");

        final passport = Passport(_nfc);

        setState(() {
          _alertMessage = "Reading CCCD ...";
        });

        _nfc.setIosAlertMessage("Trying to read EF.CardAccess ...");
        final mrtdData = MrtdData();

        try {
          mrtdData.cardAccess = await passport.readEfCardAccess();
          print("CardAccess data: ${mrtdData.cardAccess?.toBytes().hex()}");
        } on PassportError catch (e) {
          print("Error reading CardAccess: $e");
          // Fall back to BAC if PACE fails
          isPace = false;
        } catch (e) {
          print("Unexpected error reading CardAccess: $e");
          isPace = false;
        }

        _nfc.setIosAlertMessage("Trying to read EF.CardSecurity ...");

        try {
          //mrtdData.cardSecurity = await passport.readEfCardSecurity();
        } on PassportError {
          //if (e.code != StatusWord.fileNotFound) rethrow;
        }

        _nfc.setIosAlertMessage("Initiating session...");
        //set MrtdData
        mrtdData.isPACE = isPace;
        mrtdData.isDBA = accessKey.PACE_REF_KEY_TAG == 0x01 ? true : false;

        if (isPace && mrtdData.cardAccess != null) {
          try {
            print("Attempting PACE session...");
            //PACE session
            await passport.startSessionPACE(accessKey, mrtdData.cardAccess!);
            print("PACE session successful");
          } catch (e) {
            print("PACE failed, falling back to BAC: $e");
            // Fall back to BAC
            isPace = false;
            mrtdData.isPACE = false;
            await passport.startSession(accessKey as DBAKey);
            print("BAC session successful");
          }
        } else {
          print("Using BAC session...");
          //BAC session

          final docForBac = normalizeDocNumberForRead(_docNumber.text);
          print('docNumber (BAC): $docForBac');
          print('dob: ${_getDOBDate()}');
          print('doe: ${_getDOEDate()}');
          final dbakey = DBAKey(docForBac, _getDOBDate()!, _getDOEDate()!);
          await passport.startSession(dbakey);
          print("BAC session successful");
        }

        _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.COM ...", 0));
        mrtdData.com = await passport.readEfCOM();

        print("COM data: ${mrtdData.com?.toBytes().hex()}");

        _nfc.setIosAlertMessage(formatProgressMsg("Reading Data Groups ...", 20));

        if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
          mrtdData.dg1 = await passport.readEfDG1();
        }

        if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
          mrtdData.dg2 = await passport.readEfDG2();
        }

        // Chỉ DG1 + DG2: không đọc DG5–DG16 / SOD / Active Authenticate → nhanh hơn rõ rệt.
        _nfc.setIosAlertMessage(formatProgressMsg("Xong DG1/DG2", 100));

        setState(() {
          _mrtdData = mrtdData;
        });

        setState(() {
          _alertMessage = "";
        });

        final hostClosed = await _returnScanResultToHost(mrtdData);
        if (mounted && !hostClosed) {
          _scrollController.animateTo(300.0, duration: const Duration(milliseconds: 500), curve: Curves.ease);
        }
      } on Exception catch (e) {
        final se = e.toString().toLowerCase();
        String alertMsg = "An error has occurred while reading Passport!";
        if (e is PassportError) {
          if (se.contains("security status not satisfied")) {
            alertMsg = "Failed to initiate session with passport.\nCheck input data!";
          }
          _log.error("PassportError: ${e.message}");
        } else {
          _log.error("An exception was encountered while trying to read Passport: $e");
        }

        if (se.contains('timeout')) {
          alertMsg = "Timeout while waiting for CCCD tag";
        } else if (se.contains("tag was lost")) {
          alertMsg = "Tag was lost. Please try again!";
        } else if (se.contains("invalidated by user")) {
          alertMsg = "";
        }

        setState(() {
          _alertMessage = alertMsg;
        });
      } finally {
        if (_alertMessage.isNotEmpty) {
          await _nfc.disconnect(iosErrorMessage: _alertMessage);
        } else {
          await _nfc.disconnect(iosAlertMessage: formatProgressMsg("Finished", 100));
        }
        setState(() {
          _isReading = false;
        });
      }
    } on Exception catch (e) {
      _log.error("Read MRTD error: $e");
    }
  }

  void _readMRTDOld() async {
    try {
      setState(() {
        _mrtdData = null;
        _alertMessage = "Waiting for CCCD tag ...";
        _isReading = true;
      });

      await _nfc.connect(iosAlertMessage: "Hold your phone near Biometric Passport");
      final passport = Passport(_nfc);

      setState(() {
        _alertMessage = "Reading CCCD ...";
      });

      _nfc.setIosAlertMessage("Trying to read EF.CardAccess ...");
      final mrtdData = MrtdData();

      try {
        mrtdData.cardAccess = await passport.readEfCardAccess();
      } on PassportError {
        //if (e.code != StatusWord.fileNotFound) rethrow;
      }

      _nfc.setIosAlertMessage("Trying to read EF.CardSecurity ...");

      try {
        mrtdData.cardSecurity = await passport.readEfCardSecurity();
      } on PassportError {
        //if (e.code != StatusWord.fileNotFound) rethrow;
      }

      _nfc.setIosAlertMessage("Initiating session ...");
      final docForBac = normalizeDocNumberForRead(_docNumber.text);
      final bacKeySeed = DBAKey(docForBac, _getDOBDate()!, _getDOEDate()!);
      await passport.startSession(bacKeySeed);

      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.COM ...", 0));
      mrtdData.com = await passport.readEfCOM();

      _nfc.setIosAlertMessage(formatProgressMsg("Reading Data Groups ...", 20));

      if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
        mrtdData.dg1 = await passport.readEfDG1();
      }

      if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
        mrtdData.dg2 = await passport.readEfDG2();
      }

      // To read DG3 and DG4 session has to be established with CVCA certificate (not supported).
      // if(mrtdData.com!.dgTags.contains(EfDG3.TAG)) {
      //   mrtdData.dg3 = await passport.readEfDG3();
      // }

      // if(mrtdData.com!.dgTags.contains(EfDG4.TAG)) {
      //   mrtdData.dg4 = await passport.readEfDG4();
      // }

      if (mrtdData.com!.dgTags.contains(EfDG5.TAG)) {
        mrtdData.dg5 = await passport.readEfDG5();
      }

      if (mrtdData.com!.dgTags.contains(EfDG6.TAG)) {
        mrtdData.dg6 = await passport.readEfDG6();
      }

      if (mrtdData.com!.dgTags.contains(EfDG7.TAG)) {
        mrtdData.dg7 = await passport.readEfDG7();
      }

      if (mrtdData.com!.dgTags.contains(EfDG8.TAG)) {
        mrtdData.dg8 = await passport.readEfDG8();
      }

      if (mrtdData.com!.dgTags.contains(EfDG9.TAG)) {
        mrtdData.dg9 = await passport.readEfDG9();
      }

      if (mrtdData.com!.dgTags.contains(EfDG10.TAG)) {
        mrtdData.dg10 = await passport.readEfDG10();
      }

      if (mrtdData.com!.dgTags.contains(EfDG11.TAG)) {
        mrtdData.dg11 = await passport.readEfDG11();
      }

      if (mrtdData.com!.dgTags.contains(EfDG12.TAG)) {
        mrtdData.dg12 = await passport.readEfDG12();
      }

      if (mrtdData.com!.dgTags.contains(EfDG13.TAG)) {
        mrtdData.dg13 = await passport.readEfDG13();
      }

      if (mrtdData.com!.dgTags.contains(EfDG14.TAG)) {
        mrtdData.dg14 = await passport.readEfDG14();
      }

      if (mrtdData.com!.dgTags.contains(EfDG15.TAG)) {
        mrtdData.dg15 = await passport.readEfDG15();
        _nfc.setIosAlertMessage(formatProgressMsg("Doing AA ...", 60));
        mrtdData.aaSig = await passport.activeAuthenticate(Uint8List(8));
      }

      if (mrtdData.com!.dgTags.contains(EfDG16.TAG)) {
        mrtdData.dg16 = await passport.readEfDG16();
      }

      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.SOD ...", 80));
      mrtdData.sod = await passport.readEfSOD();

      setState(() {
        _mrtdData = mrtdData;
      });

      setState(() {
        _alertMessage = "";
      });

      _scrollController.animateTo(300.0, duration: Duration(milliseconds: 500), curve: Curves.ease);
    } on Exception catch (e) {
      final se = e.toString().toLowerCase();
      String alertMsg = "An error has occurred while reading Passport!";
      if (e is PassportError) {
        if (se.contains("security status not satisfied")) {
          alertMsg = "Failed to initiate session with passport.\nCheck input data!";
        }
        _log.error("PassportError: ${e.message}");
      } else {
        _log.error("An exception was encountered while trying to read Passport: $e");
      }

      if (se.contains('timeout')) {
        alertMsg = "Timeout while waiting for CCCD tag";
      } else if (se.contains("tag was lost")) {
        alertMsg = "Tag was lost. Please try again!";
      } else if (se.contains("invalidated by user")) {
        alertMsg = "";
      }

      setState(() {
        _alertMessage = alertMsg;
      });
    } finally {
      if (_alertMessage.isNotEmpty) {
        await _nfc.disconnect(iosErrorMessage: _alertMessage);
      } else {
        await _nfc.disconnect(iosAlertMessage: formatProgressMsg("Finished", 100));
      }
      setState(() {
        _isReading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlatformProvider(builder: (BuildContext context) => _buildPage(context));
  }

  bool _disabledInput() {
    //return true;
    return _isReading || !_isNfcAvailable;
  }

  /// Chỉ hiển thị DG1 + DG2 (và ảnh) sau khi đọc chip thành công.
  List<Widget> _mrtdDataWidgets() {
    if (_mrtdData == null) return [];
    final d = _mrtdData!;
    final list = <Widget>[];

    if (d.dg1 != null) {
      list.add(Text('DG1 (MRZ)', style: TextStyle(fontSize: 16.0, fontWeight: FontWeight.bold)));
      list.add(SizedBox(height: 8));
      list.add(SelectableText(formatMRZ(d.dg1!.mrz), style: TextStyle(fontFamily: 'monospace', fontSize: 13.0)));
      list.add(SizedBox(height: 16));
    }

    if (d.dg2 != null) {
      list.add(Text('DG2', style: TextStyle(fontSize: 16.0, fontWeight: FontWeight.bold)));
      list.add(SizedBox(height: 4));
      final hex = d.dg2!.toBytes().hex();
      final hexPreview = hex.length > 280 ? '${hex.substring(0, 280)}…' : hex;
      list.add(
        SelectableText(
          'Dữ liệu thô (hex, rút gọn): $hexPreview',
          style: TextStyle(fontSize: 11.0, color: Colors.black54),
        ),
      );
      list.add(SizedBox(height: 8));
      final img = d.dg2!.imageData;
      if (img != null && img.isNotEmpty) {
        list.add(Center(child: Image.memory(img, height: 200, fit: BoxFit.contain)));
      } else {
        list.add(Text('Không có imageData để hiển thị ảnh.', style: TextStyle(fontSize: 13, color: Colors.orange)));
      }
    }

    if (list.isEmpty) {
      list.add(Text('Đã đọc chip nhưng không có DG1/DG2 trên thẻ.', style: TextStyle(color: Colors.orange.shade800)));
    }

    return list;
  }

  PlatformScaffold _buildPage(BuildContext context) => PlatformScaffold(
    appBar: PlatformAppBar(title: Text('Tú test NFC')),
    iosContentPadding: false,
    iosContentBottomPadding: false,
    body: Material(
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(8.0),
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildForm(context),
                PlatformElevatedButton(
                  // btn Read MRTD
                  onPressed: _buttonPressed,
                  child: PlatformText(_isReading ? 'Đang đọc ...' : 'Bắt đầu đọc'),
                ),
                SizedBox(height: 12),
                PlatformTextButton(
                  onPressed: _isReading ? null : _sendFormToHost,
                  child: PlatformText(
                    _mrtdData != null ? 'Gửi kết quả đọc chip về host' : 'Xác nhận thông tin (form tay)',
                  ),
                ),
                PlatformTextButton(onPressed: _isReading ? null : _cancelToHost, child: PlatformText('Hủy')),
                SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    Text('NFC available:', style: TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold)),
                    SizedBox(width: 4),
                    Text(_isNfcAvailable ? "Yes" : "No", style: TextStyle(fontSize: 18.0)),
                  ],
                ),
                SizedBox(height: 15),
                Text(
                  _alertMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15.0, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 15),
                Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _mrtdData != null ? "CCCD Data:" : "",
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 15.0, fontWeight: FontWeight.bold),
                      ),
                      Padding(
                        padding: EdgeInsets.only(left: 16.0, top: 8.0, bottom: 8.0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _mrtdDataWidgets()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildForm(BuildContext context) {
    return Card(
      borderOnForeground: false,
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.all(16.0),
      child: Form(
        key: _mrzData,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextFormField(
              enabled: !_disabledInput(),
              controller: _docNumber,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'CCCD number',
                fillColor: Colors.white,
              ),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9]+')),
                LengthLimitingTextInputFormatter(14),
              ],
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.characters,
              autofocus: true,
              validator: (value) {
                if (value?.isEmpty ?? false) {
                  return 'Please enter passport number';
                }
                return null;
              },
            ),
            SizedBox(height: 12),
            TextFormField(
              enabled: !_disabledInput(),
              controller: _dob,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Date of Birth',
                hintText: 'DD/MM/YYYY',
                fillColor: Colors.white,
              ),
              autofocus: false,
              validator: (value) {
                if (value?.isEmpty ?? false) {
                  return 'Please select Date of Birth';
                }
                return null;
              },
              onTap: () async {
                FocusScope.of(context).requestFocus(FocusNode());
                // Can pick date which dates 15 years back or more
                final now = DateTime.now();
                final firstDate = DateTime(now.year - 90, now.month, now.day);
                final lastDate = DateTime(now.year - 15, now.month, now.day);
                final initDate = _getDOBDate();
                final date = await _pickDate(context, firstDate, initDate ?? lastDate, lastDate);

                FocusScope.of(context).requestFocus(FocusNode());
                if (date != null) {
                  _dob.text = date;
                }
              },
            ),
            SizedBox(height: 12),
            TextFormField(
              enabled: !_disabledInput(),
              controller: _doe,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Date of Expiry',
                hintText: 'DD/MM/YYYY',
                fillColor: Colors.white,
              ),
              autofocus: false,
              validator: (value) {
                if (value?.isEmpty ?? false) {
                  return 'Please select Date of Expiry';
                }
                return null;
              },
              onTap: () async {
                FocusScope.of(context).requestFocus(FocusNode());
                // Can pick date from tomorrow and up to 10 years
                final now = DateTime.now();
                final firstDate = DateTime(now.year, now.month, now.day + 1);
                final lastDate = DateTime(now.year + 10, now.month + 6, now.day);
                final initDate = _getDOEDate();
                final date = await _pickDate(context, firstDate, initDate ?? firstDate, lastDate);

                FocusScope.of(context).requestFocus(FocusNode());
                if (date != null) {
                  _doe.text = date;
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void extractCertificatesFromSOD(Uint8List sodBytes) {
    print('➡️ SOD bytes length: ${sodBytes.length}');
    print('➡️ First 10 bytes: ${sodBytes.take(10).toList()}');

    final outerParser = ASN1Parser(sodBytes);
    final outerObject = outerParser.nextObject();

    // Bỏ lớp ngoài [APPLICATION 0]
    final innerParser = ASN1Parser(outerObject.valueBytes());
    final topLevel = innerParser.nextObject();

    if (topLevel is! ASN1Sequence) {
      print('❌ Inner content is not ASN1Sequence');
      return;
    }

    final topLevelSeq = topLevel;

    if (topLevelSeq.elements.length < 2) {
      print('❌ Dữ liệu SOD không đúng định dạng (không có đủ 2 phần tử)');
      return;
    }

    final oid = topLevelSeq.elements[0];
    print('📛 OID: ${(oid as ASN1ObjectIdentifier)}');

    final signedDataWrapper = topLevelSeq.elements[1];

    final signedDataParser = ASN1Parser(signedDataWrapper.valueBytes());
    final signedData = signedDataParser.nextObject();

    if (signedData is! ASN1Sequence) {
      print('❌ SignedData không phải ASN1Sequence');
      return;
    }

    final signedDataSeq = signedData;

    // 🔍 In chi tiết các phần tử trong SignedData để xác định cert nằm ở đâu
    print('📦 SignedData có ${signedDataSeq.elements.length} phần tử:');
    for (int i = 0; i < signedDataSeq.elements.length; i++) {
      final el = signedDataSeq.elements[i];
      print('  🔹 Element $i: tag=${el.tag}, type=${el.runtimeType}, length=${el.encodedBytes.length}');
    }

    // 👉 Gợi ý: thường certificate nằm ở element có tag == 0, bạn có thể cần thay đổi chỉ số
    // ASN1Object? certBlock;
    // for (int i = 0; i < signedDataSeq.elements.length; i++) {
    //   final el = signedDataSeq.elements[i];
    //   if (el.tag == 0 && el.valueBytes().isNotEmpty) {
    //     certBlock = el;
    //     print('✅ Found certificate block at element $i');
    //     break;
    //   }
    // }

    // final certBlock = signedDataSeq.elements[3];

    // if (certBlock == null) {
    //   print('❌ Không tìm thấy certificates trong SignedData');
    //   return;
    // }

    final certBlockRaw = signedDataSeq.elements[3];
    final certBlockParser = ASN1Parser(certBlockRaw.valueBytes());
    final certSet = certBlockParser.nextObject();

    print('🔐 Tìm thấy tag=${certSet.tag} type=${certSet.runtimeType} length=${certSet.encodedBytes.length}');

    if (certSet is! ASN1Set && certSet is! ASN1Sequence) {
      print('❌ Certificate block không phải ASN1Set hoặc ASN1Sequence');
      return;
    }

    List<ASN1Object> certList = [];

    if (certSet is ASN1Set) {
      certList = certSet.elements.toList();
    } else if (certSet is ASN1Sequence) {
      certList = certSet.elements.toList();
    } else {
      print('❌ Certificate block không phải ASN1Set hoặc ASN1Sequence');
      return;
    }

    // final certList = certSet.elements.toList();
    // print('🔐 Tìm thấy ${certList.length} certificate(s):');

    for (int i = 0; i < certList.length; i++) {
      final cert = certList[i];
      final certBytes = cert.encodedBytes;
      final base64Cert = base64.encode(certBytes);

      print('\n📄 Certificate $i (length: ${certBytes.length} bytes)');
      print('-----BEGIN CERTIFICATE-----');
      print(base64Cert);
      print('-----END CERTIFICATE-----');

      var certString = base64Cert.replaceAll('\n', '');
      print('certString: $certString');

      // Convert base64 to PEM format
      final pemCert = '-----BEGIN CERTIFICATE-----\n$certString\n-----END CERTIFICATE-----';
      print('PEM certificate: $pemCert');
    }

    print('========================================================================');
  }

  void readEfDG13(Uint8List efDG13Bytes) {
    print('📦 EF.DG13 length: ${efDG13Bytes.length}');
    print('➡️ First 10 bytes: ${efDG13Bytes.take(10).toList()}');

    try {
      final parser = ASN1Parser(efDG13Bytes);
      final topLevel = parser.nextObject();

      if (topLevel is! ASN1Sequence) {
        print('❌ EF.DG13 không phải ASN1Sequence');
        return;
      }

      final seq = topLevel;
      print('📚 EF.DG13 gồm ${seq.elements.length} phần tử:');

      for (int i = 0; i < seq.elements.length; i++) {
        final el = seq.elements[i];
        print('  🔹 Element $i: tag=${el.tag}, type=${el.runtimeType}, length=${el.encodedBytes.length}');

        // Nếu phần tử là 1 SEQUENCE lớn, ta phân tích tiếp
        if (el is ASN1Sequence) {
          print('🔎 Phân tích sâu Element $i:');

          final innerElements = el.elements.toList();
          for (int j = 0; j < innerElements.length; j++) {
            final subEl = innerElements[j];
            print(
              '    🔸 Sub-element $j: tag=${subEl.tag}, type=${subEl.runtimeType}, length=${subEl.encodedBytes.length}',
            );

            // Nếu là ASN1Set chứa các SEQUENCE(tag, value), ta parse tiếp
            if (subEl is ASN1Set) {
              final subItems = subEl.elements.toList();
              for (int k = 0; k < subItems.length; k++) {
                final item = subItems[k];
                if (item is ASN1Sequence && item.elements.length == 2) {
                  final tag = item.elements[0];
                  final value = item.elements[1];

                  final tagNumber = (tag is ASN1Integer) ? tag.intValue : null;
                  final valueStr = _tryDecodeString(value.valueBytes());

                  print('       🏷️ Field $tagNumber: $valueStr');
                }
              }
            }
          }
        }
      }

      print('✅ Hoàn tất đọc EF.DG13');
    } catch (e) {
      print('❌ Lỗi khi phân tích EF.DG13: $e');
    }
  }

  String? _tryDecodeString(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  // String getDsCertFileEncoded(EfSOD sodFile) {
  //   try {
  //     // Get PEM certificate
  //     final String pemCertificate = sodFile.toPEM();

  //     // Encode PEM to base64
  //     return base64Encode(utf8.encode(pemCertificate));
  //   } catch (e) {
  //     print('Error getting DS certificate: $e');
  //     return "";
  //   }
  // }

  // String convertToPEMFormat(Uint8List certificateBytes) {
  //   final StringBuffer pemFormat = StringBuffer();
  //   pemFormat.write("-----BEGIN CERTIFICATE-----\n");

  //   // Convert DER to base64 and format to 64 characters per line
  //   final String base64Cert = base64Encode(certificateBytes);
  //   for (int i = 0; i < base64Cert.length; i += 64) {
  //     final int end = (i + 64 < base64Cert.length) ? i + 64 : base64Cert.length;
  //     pemFormat.write(base64Cert.substring(i, end));
  //     pemFormat.write("\n");
  //   }

  //   pemFormat.write("-----END CERTIFICATE-----\n");
  //   return pemFormat.toString();
  // }

  // void _navigateToMrzScanner() async {
  //   Navigator.push(
  //     context,
  //     MaterialPageRoute(
  //       builder: (context) => MrzScannerScreen(
  //         onMrzDataReceived: (docNumber, dob, doe) {
  //           setState(() {
  //             _docNumber.text = docNumber;
  //             _dob.text = dob;
  //             _doe.text = doe;
  //           });
  //         },
  //       ),
  //     ),
  //   );
  // }
}
