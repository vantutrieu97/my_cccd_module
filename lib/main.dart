import 'dart:io';

import 'package:cccd_vietnam/dmrtd.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'cccd_host_bridge.dart';
import 'cccd_scan_helpers.dart';
import 'mrtd_data.dart';

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((r) {
    print('${r.loggerName} ${r.level.name}: ${r.time}: ${r.message}');
  });
  runApp(
    MaterialApp(
      locale: const Locale('vi', 'VN'),
      supportedLocales: const [
        Locale('vi', 'VN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const MrtdHomePage(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class MrtdHomePage extends StatefulWidget {
  const MrtdHomePage({super.key});

  @override
  State<MrtdHomePage> createState() => _MrtdHomePageState();
}

class _MrtdHomePageState extends State<MrtdHomePage> {
  var _alertMessage = '';
  final _log = Logger('mrtdeg.app');
  var _isNfcAvailable = false;
  var _isReading = false;

  final _docNumber = TextEditingController(text: '001301005420');
  final _dob = TextEditingController(text: '16/03/2001');
  final _doe = TextEditingController(text: '16/03/2041');

  MrtdData? _mrtdData;
  double? _lastReadSeconds;

  final NfcProvider _nfc = NfcProvider();
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlatformState();
    _loadHostPrefillData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _docNumber.dispose();
    _dob.dispose();
    _doe.dispose();
    super.dispose();
  }

  Future<void> _loadHostPrefillData() async {
    try {
      final map = await CccdHostBridge.getLaunchArgs();
      if (map == null || !mounted) return;
      final cccd = (map['cccd'] ?? '').toString().trim();
      final dob = (map['dob'] ?? '').toString().trim();
      final doe = (map['doe'] ?? '').toString().trim();
      setState(() {
        if (cccd.isNotEmpty) _docNumber.text = cccd;
        if (dob.isNotEmpty) _dob.text = dob;
        if (doe.isNotEmpty) _doe.text = doe;
      });
    } catch (e, st) {
      _log.warning('getLaunchArgs failed: $e\n$st');
    }
  }

  Future<String?> _persistDg2(MrtdData data) async {
    final dg2 = data.dg2;
    if (dg2 == null) return null;
    try {
      final img = dg2.imageData;
      final bytes = (img != null && img.isNotEmpty) ? img : dg2.toBytes();
      if (bytes.isEmpty) return null;
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/dg2_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _returnToHost(MrtdData data, double readSeconds) async {
    if (!mounted) return false;
    final dg2Path = await _persistDg2(data);
    final payload = buildCccdScanResultMapSync(
      data: data,
      readDurationSeconds: readSeconds,
      fallbackDoc: _docNumber.text,
      fallbackDob: _dob.text,
      fallbackDoe: _doe.text,
      dg2ImagePath: dg2Path,
    );
    final ok = await CccdHostBridge.finishWithJson(payload);
    if (!ok) _log.warning('finishWithResult failed or not Android host');
    return ok;
  }

  Future<void> _cancelToHost() async {
    if (_isReading) return;
    final ok = await CccdHostBridge.finishWithJson({'cancelled': true, 'source': 'user_cancel'});
    if (mounted && !ok) setState(() => _alertMessage = 'Không gửi được về host.');
  }

  Future<void> _initPlatformState() async {
    var ok = false;
    try {
      final st = await NfcProvider.nfcStatus;
      ok = st == NfcStatus.enabled;
    } on PlatformException {
      ok = false;
    }
    if (mounted) setState(() => _isNfcAvailable = ok);
  }

  DateTime? _dobDt() => tryParseDisplayDate(_dob.text);
  DateTime? _doeDt() => tryParseDisplayDate(_doe.text);

  Future<void> _pickDate({required bool isDob}) async {
    final ctx = context;
    final now = DateTime.now();
    final DateTime first;
    final DateTime last;
    final DateTime initial;
    if (isDob) {
      first = DateTime(now.year - 90, now.month, now.day);
      last = DateTime(now.year - 15, now.month, now.day);
      initial = _dobDt() ?? last;
    } else {
      // Ngày hết hạn: dải theo yêu cầu nghiệp vụ (picker vẫn bắt buộc first/last).
      first = DateTime(1945, 1, 1);
      last = DateTime(2100, 12, 31);
      var i = _doeDt() ?? DateTime(now.year + 10, now.month, now.day);
      if (i.isBefore(first)) i = first;
      if (i.isAfter(last)) i = last;
      initial = i;
    }
    final picked = await showDatePicker(
      context: ctx,
      firstDate: first,
      initialDate: initial,
      lastDate: last,
      // Locale vi: ô nhập trong date picker dùng dd/MM/yyyy (không bị mm/dd như en_US).
      locale: const Locale('vi', 'VN'),
      initialEntryMode: isDob ? DatePickerEntryMode.calendar : DatePickerEntryMode.input,
    );
    if (picked == null || !mounted) return;
    final s = kDisplayDateFormat.format(picked);
    if (isDob) {
      _dob.text = s;
    } else {
      _doe.text = s;
    }
  }

  /// BAC (ICAO 9303) — không cần EF.CardAccess. Thời gian: từ lúc bắt đầu kết nối tới xong DG2.
  Future<void> _readChip() async {
    if (_docNumber.text.isEmpty || _dob.text.isEmpty || _doe.text.isEmpty) {
      setState(() => _alertMessage = 'Nhập đủ số CCCD, ngày sinh, ngày hết hạn.');
      return;
    }
    if (_dobDt() == null || _doeDt() == null) {
      setState(() => _alertMessage = 'Định dạng ngày: DD/MM/YYYY.');
      return;
    }
    final doc = normalizeDocNumberForRead(_docNumber.text);
    if (doc.isEmpty) {
      setState(() => _alertMessage = 'Số CCCD không hợp lệ.');
      return;
    }

    final sw = Stopwatch()..start();
    try {
      setState(() {
        _mrtdData = null;
        _lastReadSeconds = null;
        _alertMessage = 'Áp chip CCCD vào thiết bị...';
        _isReading = true;
      });

      await _nfc.connect(
        iosAlertMessage: 'Áp CCCD vào mặt sau điện thoại',
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      if (!_nfc.isConnected()) {
        throw Exception(
          'Không phải chip CCCD/ePassport (ISO-7816) hoặc đã mất thẻ. Giữ thẻ sát điện thoại và thử lại.',
        );
      }
      setState(() => _alertMessage = 'Đang đọc chip...');

      final passport = Passport(_nfc);
      final mrtdData = MrtdData()
        ..isPACE = false
        ..isDBA = true;

      await passport.startSession(DBAKey(doc, _dobDt()!, _doeDt()!));

      mrtdData.com = await passport.readEfCOM();
      if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
        mrtdData.dg1 = await passport.readEfDG1();
      }
      if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
        mrtdData.dg2 = await passport.readEfDG2();
      }

      sw.stop();
      final sec = sw.elapsedMilliseconds / 1000.0;
      _log.info('NFC xong ${sw.elapsedMilliseconds} ms');

      setState(() {
        _mrtdData = mrtdData;
        _lastReadSeconds = sec;
        _alertMessage = '';
      });

      final hostClosed = await _returnToHost(mrtdData, sec);
      if (mounted && !hostClosed) {
        await _scrollController.animateTo(200, duration: const Duration(milliseconds: 400), curve: Curves.ease);
      }
    } on Object catch (e, st) {
      _log.warning('Read chip failed: $e\n$st');
      if (mounted) setState(() => _alertMessage = _mapErrorMessage(e));
    } finally {
      if (sw.isRunning) sw.stop();
      try {
        if (_alertMessage.isNotEmpty) {
          await _nfc.disconnect(iosErrorMessage: _alertMessage);
        } else {
          await _nfc.disconnect(iosAlertMessage: 'Hoàn tất');
        }
      } catch (_) {}
      if (mounted) setState(() => _isReading = false);
    }
  }

  String _mapErrorMessage(Object e) {
    final s = e.toString().toLowerCase();
    if (e is PassportError) {
      final m = e.message;
      if (s.contains('security status not satisfied')) {
        return 'BAC thất bại: số CCCD (đúng 9 số MRZ nếu có) hoặc ngày sinh / ngày hết hạn không khớp chip.';
      }
      if (m.isNotEmpty) return 'Chip: $m';
    }
    if (s.contains('timeout')) return 'Hết thời gian chờ thẻ.';
    if (s.contains('tag was lost')) return 'Mất kết nối thẻ. Giữ thẻ sát và thử lại.';
    if (s.contains('invalidated by user')) return '';
    final raw = e.toString();
    if (raw.length > 200) return 'Không đọc được chip: ${raw.substring(0, 200)}…';
    return 'Không đọc được chip: $raw';
  }

  bool get _disabled => _isReading || !_isNfcAvailable;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Đọc chip CCCD')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          enabled: !_disabled,
                          controller: _docNumber,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Số CCCD (nhập tùy độ dài; BAC dùng 9 số cuối)',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: false,
                            signed: false,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(19),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          enabled: !_disabled,
                          controller: _dob,
                          readOnly: true,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: 'Ngày sinh',
                            hintText: 'DD/MM/YYYY — chạm ô hoặc biểu tượng lịch',
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.calendar_month),
                              tooltip: 'Chọn ngày sinh',
                              onPressed: _disabled
                                  ? null
                                  : () async {
                                      FocusScope.of(context).unfocus();
                                      await _pickDate(isDob: true);
                                    },
                            ),
                          ),
                          onTap: _disabled
                              ? null
                              : () async {
                                  FocusScope.of(context).unfocus();
                                  await _pickDate(isDob: true);
                                },
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          enabled: !_disabled,
                          controller: _doe,
                          keyboardType: TextInputType.datetime,
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            labelText: 'Ngày hết hạn',
                            hintText: 'DD/MM/YYYY — gõ tay hoặc nút lịch',
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.calendar_month),
                              tooltip: 'Chọn ngày',
                              onPressed: _disabled
                                  ? null
                                  : () async {
                                      FocusScope.of(context).unfocus();
                                      await _pickDate(isDob: false);
                                    },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _disabled ? null : _readChip,
                  child: Text(_isReading ? 'Đang đọc...' : 'Đọc chip (NFC)'),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: _isReading ? null : _cancelToHost, child: const Text('Hủy')),
                if (!_isNfcAvailable)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Bật NFC để đọc thẻ.', style: TextStyle(color: Colors.orange.shade800)),
                  ),
                if (_alertMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_alertMessage, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                if (_lastReadSeconds != null)
                  Text(
                    'Thời gian đọc: ${_lastReadSeconds!.toStringAsFixed(2)} giây',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                if (_mrtdData?.dg2?.imageData != null && _mrtdData!.dg2!.imageData!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Center(child: Image.memory(_mrtdData!.dg2!.imageData!, height: 160, fit: BoxFit.contain)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
