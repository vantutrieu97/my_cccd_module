import 'dart:async';
import 'dart:io';

import 'package:cccd_vietnam/dmrtd.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

import 'cccd_host_bridge.dart';
import 'cccd_scan_helpers.dart';
import 'mta_host_ui_tokens.dart';
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
      theme: MtaHostUi.theme(),
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
  /// Thông báo lỗi (đỏ).
  var _alertMessage = '';

  /// Trạng thái từng bước đọc NFC (xám) hoặc lỗi tạm nếu [ _statusIsError ].
  var _statusLine = '';
  var _statusIsError = false;

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

  void _setNfcStatus(String line, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusLine = line;
      _statusIsError = isError;
      _alertMessage = '';
    });
  }

  /// Đóng màn / về host: luôn gọi được; nếu đang đọc chip thì ngắt NFC trước.
  Future<void> _onClosePressed() async {
    FocusScope.of(context).unfocus();
    final wasReading = _isReading;
    if (wasReading) {
      try {
        await _nfc.disconnect(iosErrorMessage: 'Đã hủy');
      } catch (_) {}
      if (mounted) {
        setState(() => _isReading = false);
      }
    }
    if (!mounted) return;
    final ok = await CccdHostBridge.finishWithJson({
      'cancelled': true,
      'source': wasReading ? 'user_close_while_reading' : 'user_cancel',
    });
    if (mounted && !ok) {
      setState(() {
        _alertMessage = 'Không gửi được về host.';
        _statusLine = '';
        _statusIsError = false;
      });
    }
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

  /// Date picker Material: mặc định nhập tay (input); có thể chuyển sang lịch trong cùng dialog.
  Future<void> _pickDate({required bool isDob}) async {
    final now = DateTime.now();
    final DateTime first;
    final DateTime last;
    final DateTime initial;
    if (isDob) {
      first = DateTime(now.year - 90, now.month, now.day);
      last = DateTime(now.year - 15, now.month, now.day);
      var i = _dobDt() ?? last;
      if (i.isBefore(first)) i = first;
      if (i.isAfter(last)) i = last;
      initial = i;
    } else {
      first = DateTime(1945, 1, 1);
      last = DateTime(2100, 12, 31);
      var i = _doeDt() ?? DateTime(now.year + 10, now.month, now.day);
      if (i.isBefore(first)) i = first;
      if (i.isAfter(last)) i = last;
      initial = i;
    }

    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      initialDate: initial,
      lastDate: last,
      locale: const Locale('vi', 'VN'),
      initialEntryMode: DatePickerEntryMode.input,
    );

    if (!mounted || picked == null) return;
    setState(() {
      if (isDob) {
        _dob.text = kDisplayDateFormat.format(picked);
      } else {
        _doe.text = kDisplayDateFormat.format(picked);
      }
    });
  }

  /// BAC (ICAO 9303) — không cần EF.CardAccess. Thời gian: từ lúc bắt đầu kết nối tới xong DG2.
  Future<void> _readChip() async {
    if (_docNumber.text.isEmpty || _dob.text.isEmpty || _doe.text.isEmpty) {
      setState(() {
        _alertMessage = 'Nhập đủ số CCCD, ngày sinh, ngày hết hạn.';
        _statusLine = '';
        _statusIsError = false;
      });
      return;
    }
    if (_dobDt() == null || _doeDt() == null) {
      setState(() {
        _alertMessage = 'Định dạng ngày: DD/MM/YYYY.';
        _statusLine = '';
        _statusIsError = false;
      });
      return;
    }
    final doc = normalizeDocNumberForRead(_docNumber.text);
    if (doc.isEmpty) {
      setState(() {
        _alertMessage = 'Số CCCD không hợp lệ.';
        _statusLine = '';
        _statusIsError = false;
      });
      return;
    }

    final swTotal = Stopwatch()..start();
    final phaseMs = <String, int>{};
    String? nfcDisconnectError;
    try {
      setState(() {
        _mrtdData = null;
        _lastReadSeconds = null;
        _alertMessage = '';
        _statusIsError = false;
        _statusLine = 'Đang tìm chip — áp mặt sau CCCD vào thiết bị…';
        _isReading = true;
      });

      final swConnect = Stopwatch()..start();
      await _nfc.connect(
        iosAlertMessage: 'Áp CCCD vào mặt sau điện thoại',
        timeout: const Duration(seconds: 30),
      );
      swConnect.stop();
      phaseMs['connect'] = swConnect.elapsedMilliseconds;
      if (!mounted) return;
      if (!_nfc.isConnected()) {
        throw Exception(
          'Không phải chip CCCD/ePassport (ISO-7816) hoặc đã mất thẻ. Giữ thẻ sát điện thoại và thử lại.',
        );
      }
      _setNfcStatus('Đã kết nối chip. Đang xác thực BAC (khóa từ số CCCD và ngày)…');

      final passport = Passport(_nfc);
      final mrtdData = MrtdData()
        ..isPACE = false
        ..isDBA = true;

      final swBac = Stopwatch()..start();
      await passport.startSession(DBAKey(doc, _dobDt()!, _doeDt()!));
      swBac.stop();
      phaseMs['bac'] = swBac.elapsedMilliseconds;
      if (!mounted) return;
      _setNfcStatus('BAC thành công. Đang đọc danh mục dữ liệu trên chip (COM)…');

      final swCom = Stopwatch()..start();
      mrtdData.com = await passport.readEfCOM();
      swCom.stop();
      phaseMs['com'] = swCom.elapsedMilliseconds;
      if (!mounted) return;

      if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
        _setNfcStatus('Đang đọc dữ liệu nhận dạng (DG1)…');
        final swDg1 = Stopwatch()..start();
        mrtdData.dg1 = await passport.readEfDG1();
        swDg1.stop();
        phaseMs['dg1'] = swDg1.elapsedMilliseconds;
        if (!mounted) return;
      }
      if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
        _setNfcStatus('Đang đọc ảnh chân dung (DG2)…');
        final swDg2 = Stopwatch()..start();
        mrtdData.dg2 = await passport.readEfDG2();
        swDg2.stop();
        phaseMs['dg2'] = swDg2.elapsedMilliseconds;
        if (!mounted) return;
      }

      swTotal.stop();
      final sec = swTotal.elapsedMilliseconds / 1000.0;
      _log.info(
        'NFC tổng ${swTotal.elapsedMilliseconds} ms | pha: '
        '${phaseMs.entries.map((e) => '${e.key}=${e.value}ms').join(', ')}',
      );

      _setNfcStatus('Đọc chip xong. Đang gửi kết quả về ứng dụng…');
      setState(() {
        _mrtdData = mrtdData;
        _lastReadSeconds = sec;
      });

      final hostClosed = await _returnToHost(mrtdData, sec);
      if (mounted && !hostClosed) {
        await _scrollController.animateTo(200, duration: const Duration(milliseconds: 400), curve: Curves.ease);
      }
    } on Object catch (e, st) {
      _log.warning('Read chip failed: $e\n$st');
      if (phaseMs.isNotEmpty) {
        _log.warning(
          'NFC pha trước lỗi: ${phaseMs.entries.map((e) => '${e.key}=${e.value}ms').join(', ')}',
        );
      }
      if (mounted) {
        final msg = _mapErrorMessage(e);
        if (msg.isNotEmpty) {
          nfcDisconnectError = msg;
          _setNfcStatus(msg, isError: true);
        } else {
          _setNfcStatus('Đã hủy hoặc ngắt kết nối.', isError: true);
        }
      }
    } finally {
      if (swTotal.isRunning) swTotal.stop();
      try {
        if (nfcDisconnectError != null && nfcDisconnectError.isNotEmpty) {
          await _nfc.disconnect(iosErrorMessage: nfcDisconnectError);
        } else {
          await _nfc.disconnect(iosAlertMessage: 'Hoàn tất');
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isReading = false;
          if (nfcDisconnectError == null) {
            _statusLine = '';
            _statusIsError = false;
          }
        });
      }
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

  void _dismissToHost() {
    unawaited(_onClosePressed());
  }

  Future<void> _pickDateIfEnabled({required bool isDob}) async {
    if (_disabled) return;
    FocusScope.of(context).unfocus();
    await _pickDate(isDob: isDob);
  }

  /// Form trong thẻ modal (scrim + surface nằm ở [build]).
  List<Widget> _buildFormBody(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final feedbackLine = _alertMessage.isNotEmpty ? _alertMessage : _statusLine;
    final feedbackIsErr = _alertMessage.isNotEmpty || _statusIsError;
    return [
      TextField(
        enabled: !_disabled,
        controller: _docNumber,
        style: t.bodyLarge,
        decoration: const InputDecoration(
          labelText: 'Số CCCD',
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: false, signed: false),
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
        style: t.bodyLarge,
        decoration: InputDecoration(
          labelText: 'Ngày sinh',
          hintText: 'Chạm để nhập hoặc chọn lịch (dd/MM/yyyy)',
          suffixIcon: IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Chọn ngày sinh',
            onPressed: () => _pickDateIfEnabled(isDob: true),
          ),
        ),
        onTap: () => _pickDateIfEnabled(isDob: true),
      ),
      const SizedBox(height: 12),
      TextField(
        enabled: !_disabled,
        controller: _doe,
        readOnly: true,
        style: t.bodyLarge,
        decoration: InputDecoration(
          labelText: 'Ngày hết hạn',
          hintText: 'Chạm để nhập hoặc chọn lịch (dd/MM/yyyy)',
          suffixIcon: IconButton(
            icon: const Icon(Icons.calendar_month),
            tooltip: 'Chọn ngày',
            onPressed: () => _pickDateIfEnabled(isDob: false),
          ),
        ),
        onTap: () => _pickDateIfEnabled(isDob: false),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _disabled ? null : _readChip,
        child: Text(_isReading ? 'Đang đọc...' : 'Đọc chip (NFC)'),
      ),
      if (!_isNfcAvailable)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Bật NFC để đọc thẻ.',
            style: t.bodyMedium?.copyWith(color: MtaHostUi.warning, fontWeight: FontWeight.w600),
          ),
        ),
      if (feedbackLine.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            feedbackLine,
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(
              color: feedbackIsErr ? MtaHostUi.error : MtaHostUi.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      if (_lastReadSeconds != null)
        Text(
          'Thời gian đọc: ${_lastReadSeconds!.toStringAsFixed(2)} giây',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: MtaHostUi.textSecondary),
        ),
      if (_mrtdData?.dg2?.imageData != null && _mrtdData!.dg2!.imageData!.isNotEmpty) ...[
        const SizedBox(height: 12),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: MtaHostUi.surface,
              child: Image.memory(
                _mrtdData!.dg2!.imageData!,
                height: 160,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final availW = mq.width - pad.horizontal;
    final availH = mq.height - pad.vertical;
    final cardW = availW * MtaHostUi.cardWidthFraction;
    final maxCardH = availH * MtaHostUi.cardMaxHeightFraction;
    final t = Theme.of(context).textTheme;

    // Cùng tông / tỷ lệ với MRZ dialog host: 80% ngang, cao theo content (tối đa 92%), scrim black54.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_onClosePressed());
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _dismissToHost,
                  child: const ColoredBox(color: Colors.black54),
                ),
              ),
              Center(
                child: SizedBox(
                  width: cardW,
                  child: Material(
                    elevation: MtaHostUi.cardElevation,
                    shadowColor: Colors.black26,
                    surfaceTintColor: Colors.transparent,
                    color: MtaHostUi.background,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(MtaHostUi.cardRadius),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxCardH),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'Đọc chip CCCD',
                                        style: t.titleLarge,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Kiểm tra số CCCD và ngày, rồi áp thẻ để đọc chip NFC.',
                                        style: t.bodyMedium?.copyWith(color: MtaHostUi.textSecondary),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Đóng',
                                  onPressed: () => unawaited(_onClosePressed()),
                                  icon: const Icon(Icons.close, color: MtaHostUi.textSecondary),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            ..._buildFormBody(context),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
