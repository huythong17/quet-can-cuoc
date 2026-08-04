import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  final _dbCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _isLoading = true;
  bool _obscurePass = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlCtrl.text = prefs.getString('odoo_url') ?? '';
      _dbCtrl.text = prefs.getString('odoo_db') ?? '';
      _userCtrl.text = prefs.getString('odoo_user') ?? '';
      _passCtrl.text = prefs.getString('odoo_pass') ?? '';
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;
    
    String url = _urlCtrl.text.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('odoo_url', url);
    await prefs.setString('odoo_db', _dbCtrl.text.trim());
    await prefs.setString('odoo_user', _userCtrl.text.trim());
    await prefs.setString('odoo_pass', _passCtrl.text.trim());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Đã lưu cấu hình Odoo'), backgroundColor: Colors.green),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cấu hình kết nối Odoo'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Cấu hình thông tin kết nối tới hệ thống Odoo để tự động đồng bộ nhân viên sau khi quét CCCD.',
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  const SizedBox(height: 24),
                  
                  TextFormField(
                    controller: _urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Địa chỉ máy chủ Odoo (URL)',
                      hintText: 'VD: https://myodoo.com',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                    keyboardType: TextInputType.url,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Vui lòng nhập URL';
                      if (!v.startsWith('http')) return 'URL phải bắt đầu bằng http:// hoặc https://';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  TextFormField(
                    controller: _dbCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tên Database (Tùy chọn)',
                      hintText: 'Để trống nếu máy chủ chỉ có 1 Database',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.storage),
                    ),
                  ),
                  const SizedBox(height: 16),
                  
                  TextFormField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Tên đăng nhập (Email)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Vui lòng nhập Tên đăng nhập' : null,
                  ),
                  const SizedBox(height: 16),
                  
                  TextFormField(
                    controller: _passCtrl,
                    decoration: InputDecoration(
                      labelText: 'Mật khẩu',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePass ? Icons.visibility : Icons.visibility_off),
                        onPressed: () {
                          setState(() {
                            _obscurePass = !_obscurePass;
                          });
                        },
                      ),
                    ),
                    obscureText: _obscurePass,
                    validator: (v) => v == null || v.trim().isEmpty ? 'Vui lòng nhập Mật khẩu' : null,
                  ),
                  const SizedBox(height: 32),
                  
                  ElevatedButton.icon(
                    onPressed: _saveSettings,
                    icon: const Icon(Icons.save),
                    label: const Text('Lưu cấu hình', style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                    ),
                  )
                ],
              ),
            ),
          ),
    );
  }
}
