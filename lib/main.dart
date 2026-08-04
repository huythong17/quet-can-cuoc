import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_nfc_kit/flutter_nfc_kit.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:cccd_vietnam/dmrtd.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_page.dart';
void main() {
  runApp(const SalaCccdApp());
}

class SalaCccdApp extends StatelessWidget {
  const SalaCccdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quét Căn Cước',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C3AED),
          primary: const Color(0xFF7C3AED),
          secondary: const Color(0xFF3B82F6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF7C3AED),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const MainHomeScreen(),
    );
  }
}

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({super.key});

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  bool _isNfcScanning = false;
  String _nfcStatus = '📡 Quét mã QR mặt sau thẻ CCCD rồi áp thẻ vào lưng điện thoại để đọc chíp...';
  Uint8List? _portraitImageBytes;

  // MRZ data for BAC authentication
  String _mrzDocNum = ''; // 9-char document number from MRZ
  String _mrzDob = '';    // YYMMDD date of birth
  String _mrzExpiry = ''; // YYMMDD expiry date
  
  Map<String, String>? _fullQrData;
  bool _isSyncing = false;
  String? _createdPin;
  String? _createdName;
  bool _isTriggeringEnroll = false;

  @override
  void initState() {
    super.initState();
    _checkNfcAvailability();
  }

  Future<void> _checkNfcAvailability() async {
    try {
      NFCAvailability availability = await FlutterNfcKit.nfcAvailability;
      if (availability != NFCAvailability.available) {
        setState(() {
          _nfcStatus = '⚠️ NFC chưa được bật hoặc không hỗ trợ trên điện thoại này. Vui lòng bật NFC trong Cài đặt.';
        });
      }
    } catch (e) {
      debugPrint('NFC availability err: $e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }




  // ── QR CODE SCANNER → AUTO NFC ─────────────────────────
  Future<void> _scanQrAndStartNfc() async {
    // Request camera permission
    PermissionStatus cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted && !cameraStatus.isLimited) {
      setState(() {
        _nfcStatus = '❌ Chưa cấp quyền camera!\n💡 Vào Cài đặt > Ứng dụng > SALA CCCD NFC > Quyền > Bật Máy ảnh.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('❌ Cần cấp quyền Camera để quét QR.'),
          backgroundColor: Colors.red,
        ));
        if (cameraStatus.isPermanentlyDenied) await openAppSettings();
      }
      return;
    }

    // Open full-screen live QR scanner page
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (result == null || !mounted) return;

    // Parse QR result
    String cccd = result['cccd'] ?? '';
    String dob = result['dob'] ?? '';   // YYMMDD
    String exp = result['exp'] ?? '';   // YYMMDD
    String name = result['name'] ?? '';

    if (cccd.isEmpty) {
      setState(() {
        _nfcStatus = '⚠️ Bấm nút "📸 BẮT ĐẦU QUÉT" ở dưới để đưa camera quét mã QR mặt sau thẻ CCCD.';
      });
      return;
    }

    String docNum = cccd;

    setState(() {
      _fullQrData = result;
      _mrzDocNum = docNum;
      _mrzDob = dob;
      _mrzExpiry = exp;
      _nfcStatus = '✅ ĐÃ QUÉT THÀNH CÔNG QR CCCD!\n'
          '🆔 Số CCCD: $cccd${name.isNotEmpty ? "\n👤 Họ tên: $name" : ""}\n'
          '🎂 DOB: $dob | Hết hạn: $exp\n\n'
          '📡 HÃY ÁP LƯNG ĐIỆN THOẠI VÀO THẺ NFC NGAY ĐỂ ĐỌC ẢNH CHÂN DUNG...';
    });

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('✅ Đã nhận QR! Hãy áp lưng điện thoại vào thẻ CCCD để đọc chíp...'),
      backgroundColor: Colors.green,
      duration: Duration(seconds: 3),
    ));

    // Wait 1 second to ensure the camera and QR page is fully disposed
    await Future.delayed(const Duration(milliseconds: 1000));

    await _startNfcScan();
  }

  // ── NFC SCANNER LOGIC (SỬ DỤNG GIAO THỨC PACE / cccd_vietnam) ──
  Future<void> _startNfcScan() async {
    if (_isNfcScanning) return;

    // Nếu chưa quét QR thì yêu cầu quét trước
    if (_mrzDob.isEmpty) {
      await _scanQrAndStartNfc();
      return;
    }

    setState(() {
      _isNfcScanning = true;
      _portraitImageBytes = null;
      _nfcStatus = '📡 ĐANG BẬT MÁY QUÉT NFC...\n👉 HÃY ÁP MẶT SAU THẺ CCCD VÀO LƯNG ĐIỆN THOẠI!';
    });

    final nfc = NfcProvider();
    try {
      int dobY = int.parse(_mrzDob.substring(0, 2));
      int dobM = int.parse(_mrzDob.substring(2, 4));
      int dobD = int.parse(_mrzDob.substring(4, 6));
      DateTime dtDob = DateTime((dobY > 35 ? 1900 : 2000) + dobY, dobM, dobD);

      List<String> expCandidates = [];
      if (_mrzExpiry.isNotEmpty) {
        expCandidates.add(_mrzExpiry); // format: YYMMDD
      }
      // Tự sinh các ngày hết hạn dự kiến theo luật Việt Nam (25, 40, 60 tuổi)
      if (_mrzDob.length == 6) {
        try {
          int yy = int.parse(_mrzDob.substring(0, 2));
          String mmdd = _mrzDob.substring(2, 6);
          int fullBirthYear = (yy > 35 ? 1900 : 2000) + yy;
          for (int expAge in [25, 40, 60]) {
            int eYear = (fullBirthYear + expAge) % 100;
            expCandidates.add('${eYear.toString().padLeft(2, '0')}$mmdd');
          }
        } catch (_) {}
      }
      expCandidates = expCandidates.toSet().toList();
      
      List<DateTime> dtExpCandidates = expCandidates.map((expStr) {
        int eY = int.parse(expStr.substring(0, 2));
        int eM = int.parse(expStr.substring(2, 4));
        int eD = int.parse(expStr.substring(4, 6));
        return DateTime(2000 + eY, eM, eD);
      }).toList();

      List<String> docNumCandidates = [];
      if (_mrzDocNum.isNotEmpty) {
        if (_mrzDocNum.length == 12) {
          docNumCandidates.add(_mrzDocNum.substring(3, 12)); // Last 9 digits (Standard for VN CCCD MRZ)
        }
        docNumCandidates.add(_mrzDocNum); // Full 12 digits
        if (_mrzDocNum.length >= 9) {
          docNumCandidates.add(_mrzDocNum.substring(0, 9)); // First 9 digits
        }
      }
      docNumCandidates = docNumCandidates.toSet().toList();
      if (docNumCandidates.isEmpty) throw Exception("Không có thông tin số CCCD từ mã QR.");

      await nfc.connect(iosAlertMessage: "Chạm thẻ CCCD vào lưng thiết bị");
      
      setState(() {
        _nfcStatus = '✅ ĐÃ KẾT NỐI NFC!\n\n📥 Đang thực hiện xác thực PACE...';
      });

      final passport = Passport(nfc);
      final cardAccess = await passport.readEfCardAccess();
      
      bool paceSuccess = false;
      String lastError = "";

      // Thử tất cả tổ hợp DocNum và Ngày hết hạn
      outerLoop:
      for (String dNum in docNumCandidates) {
        for (DateTime dtExp in dtExpCandidates) {
          try {
            debugPrint("Trying PACE with docNum=$dNum, exp=${dtExp.toString()}");
            var accessKey = DBAKey(dNum, dtDob, dtExp, paceMode: true);
            await passport.startSessionPACE(accessKey, cardAccess);
            paceSuccess = true;
            debugPrint("PACE SUCCESS with docNum=$dNum, exp=${dtExp.toString()}");
            break outerLoop;
          } catch (e) {
            lastError = e.toString();
            debugPrint("PACE FAILED with docNum=$dNum, exp=${dtExp.toString()}: $lastError");
          }
        }
      }

      if (!paceSuccess) {
        throw Exception("Sai thông tin xác thực MRZ.\n$lastError");
      }

      setState(() {
        _nfcStatus = '✅ XÁC THỰC PACE THÀNH CÔNG!\n\n📥 Đang đọc ảnh chân dung (DG2)...';
      });

      final dg2 = await passport.readEfDG2();
      if (dg2.imageData != null) {
        setState(() {
          _portraitImageBytes = Uint8List.fromList(dg2.imageData!);
          _nfcStatus = '🎉 ĐÃ BÓC TÁCH ẢNH CHÂN DUNG THÀNH CÔNG!\n'
              '📸 Ảnh DG2 từ chíp: ${dg2.imageData!.length} bytes\n'
              '✅ Quá trình đọc hoàn tất!';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('🎉 THÀNH CÔNG! Đã đọc ảnh chân dung từ chíp NFC.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ));
        }
      } else {
        setState(() {
          _nfcStatus = '⚠️ Chưa giải mã được ảnh DG2 từ chíp NFC.\n'
              '👉 Mẹo: Hãy bấm nút "📸 BẮT ĐẦU QUÉT" ở dưới rồi quét mã QR mặt sau thẻ CCCD để tự động mở khóa chíp NFC.';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('💡 Không tìm thấy ảnh trong thẻ NFC.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ));
        }
      }
    } catch (e) {
      String errStr = e.toString().replaceAll("Exception:", "").trim();
      setState(() {
        _nfcStatus = '❌ Lỗi đọc NFC: $errStr\n💡 Hãy giữ yên thẻ ở lưng máy và bấm nút quét lại.';
      });
      try { await FlutterNfcKit.finish(iosErrorMessage: "Lỗi đọc NFC"); } catch (_) {}
    } finally {
      setState(() {
        _isNfcScanning = false;
      });
    }
  }

  Future<void> _syncToOdoo({required bool syncZk, int? departmentId}) async {
    if (_fullQrData == null || _portraitImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('⚠️ Thiếu dữ liệu thẻ hoặc ảnh chân dung! Vui lòng quét QR và NFC trước.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    setState(() => _isSyncing = true);

    try {
      final String url = 'https://erp.salahanoi.us';
      final createUri = Uri.parse('$url/sala/cccd/create_employee');
      
      // Convert date to YYYY-MM-DD for Odoo
      String odooDate(String raw) {
        if (raw.length == 8) {
          if (raw.contains('/')) {
             final p = raw.split('/');
             if (p.length == 3) return '${p[2]}-${p[1]}-${p[0]}';
          }
          return '${raw.substring(4,8)}-${raw.substring(2,4)}-${raw.substring(0,2)}';
        }
        return '';
      }

      final Map<String, dynamic> paramsData = {
        'cccd_number': _fullQrData!['cccd'],
        'cccd_old_number': _fullQrData!['cccd_old_number'],
        'cccd_full_name': _fullQrData!['name'],
        'cccd_dob': odooDate(_fullQrData!['dob_raw'] ?? ''),
        'cccd_gender': _fullQrData!['gender'],
        'cccd_address': _fullQrData!['address'],
        'cccd_issue_date': odooDate(_fullQrData!['issue_raw'] ?? ''),
        'image_1920': base64Encode(_portraitImageBytes!),
        'sync_zk': syncZk,
      };

      if (departmentId != null) {
        paramsData['department_id'] = departmentId;
      }

      final createBody = {
        'jsonrpc': '2.0',
        'params': paramsData,
      };

      final createRes = await http.post(createUri,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(createBody),
      );

      final createData = jsonDecode(createRes.body);
      
      if (createData['error'] != null) {
        throw Exception(createData['error']['data']?['message'] ?? createData['error']['message'] ?? 'Lỗi tạo nhân viên');
      }

      final result = createData['result'] ?? {};
      if (result['success'] == true) {
        final pin = result['pin']?.toString() ?? '';
        final name = result['name']?.toString() ?? _fullQrData?['name'] ?? 'Nhân viên';
        setState(() {
          _createdPin = pin.isNotEmpty ? pin : null;
          _createdName = name;
        });

        String msg = '🎉 Đã tạo nhân viên trên Odoo thành công!';
        if (syncZk) msg += '\n🖥️ Thông tin đã được gửi sang máy chấm công (Mã PIN: $pin).';
        if (result['sync_warning'] != null) msg += '\n⚠️ Cảnh báo ZK: ${result['sync_warning']}';
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ));
        }
      } else {
        throw Exception(result['error'] ?? 'Lỗi không xác định từ Odoo');
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Lỗi đồng bộ: ${e.toString().replaceAll("Exception: ", "")}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ));
      }
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  // ── DEPARTMENT FETCH & SELECTION DIALOG ──────────────
  List<Map<String, dynamic>> _departmentsList = [];

  Future<List<Map<String, dynamic>>> _fetchDepartments() async {
    if (_departmentsList.isNotEmpty) return _departmentsList;
    try {
      final Uri uri = Uri.parse('https://erp.salahanoi.us/sala/cccd/departments');
      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'jsonrpc': '2.0', 'params': {}}),
      ).timeout(const Duration(seconds: 4));
      
      final data = jsonDecode(res.body);
      if (data['result'] != null && data['result']['success'] == true) {
        final List depts = data['result']['departments'] ?? [];
        _departmentsList = depts.map((d) => {
          'id': d['id'] as int?,
          'name': d['name'].toString(),
        }).toList();
      }
    } catch (e) {
      debugPrint('Error fetching departments: $e');
    }

    if (_departmentsList.isEmpty) {
      _departmentsList = [
        {'id': 2, 'name': 'Sản Xuất'},
        {'id': 6, 'name': 'Sản Xuất / Sản Xuất 1'},
        {'id': 7, 'name': 'Sản Xuất / Sản Xuất 2'},
        {'id': 9, 'name': 'Sản Xuất / Hỗ Trợ'},
        {'id': 3, 'name': 'Kho Hàng'},
        {'id': 4, 'name': 'Tài Xế'},
        {'id': 5, 'name': 'Đốt Lò'},
        {'id': 1, 'name': 'Administration'},
      ];
    }
    return _departmentsList;
  }

  void _onTapCreateEmployee() async {
    if (_fullQrData == null || _portraitImageBytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('⚠️ Thiếu dữ liệu thẻ hoặc ảnh chân dung! Vui lòng quét QR và NFC trước.'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    final depts = await _fetchDepartments();
    
    // Find default "Sản Xuất"
    Map<String, dynamic>? defaultDept;
    for (var d in depts) {
      final nameLower = d['name'].toString().trim().toLowerCase();
      if (nameLower == 'sản xuất') {
        defaultDept = d;
        break;
      }
    }
    defaultDept ??= depts.firstWhere((d) => d['name'].toString().toLowerCase().contains('sản xuất'), orElse: () => depts.first);

    Map<String, dynamic>? selectedDept = defaultDept;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.business, color: Color(0xFF7C3AED), size: 26),
                  SizedBox(width: 10),
                  Text('Chọn phòng ban', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Vui lòng chọn phòng ban cho nhân viên trước khi tiếp tục:', style: TextStyle(fontSize: 13, color: Colors.black87)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFF7C3AED), width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                      color: Colors.purple.shade50,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<Map<String, dynamic>>(
                        isExpanded: true,
                        value: selectedDept,
                        items: depts.map((d) {
                          return DropdownMenuItem<Map<String, dynamic>>(
                            value: d,
                            child: Text(
                              d['name'].toString(),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                            ),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedDept = val;
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Hủy', style: TextStyle(color: Colors.grey, fontSize: 15)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7C3AED),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _syncToOdoo(
                      syncZk: true,
                      departmentId: selectedDept?['id'] as int?,
                    );
                  },
                  child: const Text('Xác nhận', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── CCCD INFORMATION CARD WIDGET ─────────────────────
  String _fmtDisplayDate(String raw) {
    if (raw.isEmpty) return '';
    if (raw.contains('/')) return raw;
    if (raw.length == 8) {
      return '${raw.substring(0, 2)}/${raw.substring(2, 4)}/${raw.substring(4, 8)}';
    }
    return raw;
  }

  Widget _buildCccdDetailsCard() {
    if (_fullQrData == null) return const SizedBox.shrink();
    final cccd = _fullQrData!['cccd'] ?? '';
    final oldCccd = _fullQrData!['cccd_old_number'] ?? '';
    final name = _fullQrData!['name'] ?? '';
    final dobRaw = _fullQrData!['dob_raw'] ?? '';
    final gender = _fullQrData!['gender'] ?? '';
    final address = _fullQrData!['address'] ?? '';
    final issueRaw = _fullQrData!['issue_raw'] ?? '';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.shade200, width: 1.5),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.badge, color: Color(0xFF7C3AED), size: 22),
              const SizedBox(width: 8),
              const Text(
                'Thông tin CCCD (từ Mã QR)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF7C3AED)),
              ),
            ],
          ),
          const Divider(height: 16),
          _infoRow('Số CCCD:', cccd, isBold: true),
          if (oldCccd.isNotEmpty) _infoRow('CMND cũ:', oldCccd),
          _infoRow('Họ và tên:', name, isBold: true),
          _infoRow('Ngày sinh:', _fmtDisplayDate(dobRaw)),
          _infoRow('Giới tính:', gender),
          _infoRow('Thường trú:', address),
          _infoRow('Ngày cấp:', _fmtDisplayDate(issueRaw)),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool isBold = false}) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _triggerRemoteEnrollment() async {
    if (_createdPin == null || _createdPin!.isEmpty) return;
    setState(() => _isTriggeringEnroll = true);
    
    try {
      // Try local IP first, fallback to domain if needed
      final url = Uri.parse('http://192.168.1.50:8190/api/enroll?pin=$_createdPin');
      await http.get(url).timeout(const Duration(seconds: 5));

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.face, color: Colors.purple, size: 30),
                SizedBox(width: 10),
                Text('Đăng ký khuôn mặt', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              '🟢 ĐÃ BẬT THÀNH CÔNG!\n\n'
              'Màn hình máy SenseFace 4A đang hiển thị chế độ Đăng ký khuôn mặt cho:\n'
              '👤 Nhân viên: ${_createdName ?? ""}\n'
              '🆔 Mã ID: $_createdPin\n\n'
              '👉 Nhân viên chỉ cần bước tới đứng trước camera máy chấm công trong 2 GIÂY là xong!',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ĐÃ HIỂU', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Lỗi kết nối máy chấm công: ${e.toString()}'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      setState(() => _isTriggeringEnroll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét Căn Cước', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: true,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Photo Frame
              Container(
                width: 180,
                height: 240,
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300, width: 3),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, 4))],
                ),
                child: _portraitImageBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(13),
                        child: Image.memory(_portraitImageBytes!, fit: BoxFit.cover),
                      )
                    : const Icon(Icons.person, size: 80, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              
              // Status Text
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Text(
                  _nfcStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: Color(0xFF1E293B), height: 1.5, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 20),

              // CCCD Details Card (from QR code)
              if (_fullQrData != null) _buildCccdDetailsCard(),

              // Scan Button
              ElevatedButton.icon(
                onPressed: _isNfcScanning ? null : _scanQrAndStartNfc,
                icon: _isNfcScanning
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                    : const Icon(Icons.camera_alt, size: 28),
                label: Text(
                  _isNfcScanning ? 'ĐANG ĐỌC CHÍP...' : '📸 BẮT ĐẦU QUÉT',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(60),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  elevation: 4,
                ),
              ),
              
              if (_portraitImageBytes != null && _fullQrData != null) ...[
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _isSyncing ? null : _onTapCreateEmployee,
                  icon: const Icon(Icons.person_add, size: 24),
                  label: Text(
                    _isSyncing ? 'ĐANG XỬ LÝ...' : '👤 Tạo nhân viên',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 4,
                  ),
                ),
                if (_createdPin != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.purple.shade300, width: 2),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '🎉 Đã sẵn sàng cho nhân viên ${_createdName ?? ""} (ID: $_createdPin)',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.purple.shade900, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          onPressed: _isTriggeringEnroll ? null : _triggerRemoteEnrollment,
                          icon: _isTriggeringEnroll
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.face_retouching_natural, size: 26),
                          label: const Text('📸 BẬT MỞ QUÉT KHUÔN MẶT TRÊN MÁY', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple.shade700,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class Math {
  static int min(int a, int b) => a < b ? a : b;
}

// ── FULL-SCREEN QR SCANNER PAGE ──────────────────────────────
// Scans Vietnamese CCCD QR code / PDF417 barcode
// Returns Map<String,String>: cccd, name, dob (YYMMDD), exp (YYMMDD)
class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode, BarcodeFormat.pdf417, BarcodeFormat.dataMatrix, BarcodeFormat.code128],
  );
  bool _detected = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Map<String, String> _parseQr(String raw) {
    List<String> p = raw.trim().split('|');
    String cccd = p.isNotEmpty ? p[0].trim() : '';
    String oldCccd = p.length > 1 ? p[1].trim() : '';
    String name = p.length > 2 ? p[2].trim() : '';
    String dobRaw = p.length > 3 ? p[3].trim() : '';
    String gender = p.length > 4 ? p[4].trim() : '';
    String address = p.length > 5 ? p[5].trim() : '';
    String issueRaw = p.length > 6 ? p[6].trim() : '';
    String issueDate = issueRaw.isNotEmpty ? _fmtDate(issueRaw) : '';
    
    // MRZ needs these
    String expRaw = p.length > 8 ? p[8].trim() : '';

    String dob = _fmtDate(dobRaw);
    String exp = expRaw.isNotEmpty ? _fmtDate(expRaw) : _calcExp(dobRaw, issueRaw);
    
    return {
      'cccd': cccd, 
      'cccd_old_number': oldCccd,
      'name': name, 
      'dob': dob, 
      'gender': gender,
      'address': address,
      'issue_date': issueDate,
      'exp': exp,
      'dob_raw': dobRaw,
      'issue_raw': issueRaw,
    };
  }

  String _calcExp(String dobStr, String issueStr) {
    try {
      int dobDay, dobMonth, dobYear;
      if (dobStr.length == 8 && !dobStr.contains('/')) {
        dobDay = int.parse(dobStr.substring(0, 2));
        dobMonth = int.parse(dobStr.substring(2, 4));
        dobYear = int.parse(dobStr.substring(4, 8));
      } else {
        List<String> p = dobStr.split('/');
        if (p.length != 3) return '';
        dobDay = int.parse(p[0]);
        dobMonth = int.parse(p[1]);
        dobYear = int.parse(p[2]);
      }

      int issueYear = dobYear + 25;
      if (issueStr.isNotEmpty) {
        if (issueStr.length == 8 && !issueStr.contains('/')) {
          issueYear = int.parse(issueStr.substring(4, 8));
        } else {
          List<String> issP = issueStr.split('/');
          if (issP.length == 3) issueYear = int.parse(issP[2]);
        }
      }

      int ageAtIssue = issueYear - dobYear;
      int expYear;
      if (ageAtIssue < 23) {
        expYear = dobYear + 25;
      } else if (ageAtIssue < 38) {
        expYear = dobYear + 40;
      } else {
        expYear = dobYear + 60;
      }

      String yy = (expYear % 100).toString().padLeft(2, '0');
      String mm = dobMonth.toString().padLeft(2, '0');
      String dd = dobDay.toString().padLeft(2, '0');
      return '$yy$mm$dd';
    } catch (_) {}
    return '';
  }

  String _fmtDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      if (raw.length == 8 && !raw.contains('/')) {
        return '${raw.substring(6, 8)}${raw.substring(2, 4)}${raw.substring(0, 2)}';
      }
      List<String> p = raw.split('/');
      if (p.length == 3 && p[2].length >= 4) {
        return '${p[2].substring(2, 4)}${p[1].padLeft(2, '0')}${p[0].padLeft(2, '0')}';
      }
    } catch (_) {}
    return '';
  }
  void _onDetect(BarcodeCapture cap) {
    if (_detected) return;
    for (final barcode in cap.barcodes) {
      final raw = barcode.rawValue ?? '';
      if (raw.isEmpty) continue;
      debugPrint('QR raw: $raw');

      // Must contain | separator typical of CCCD QR
      final parsed = _parseQr(raw);
      if (parsed['cccd']!.length >= 9) {
        _detected = true;
        _ctrl.stop();
        if (mounted) Navigator.of(context).pop(parsed);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('📷 Quét QR mặt sau thẻ CCCD', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _ctrl.toggleTorch(),
            tooltip: 'Đèn flash',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera preview
          MobileScanner(
            controller: _ctrl,
            onDetect: _onDetect,
          ),
          // Overlay guide
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 280,
                  height: 160,
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFF00FF88), width: 3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Đặt mã QR mặt sau thẻ CCCD vào khung',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
