import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';

// SmartHerd/ZoneLock has no internet dependency by design, so
// authentication is local-only (stored on-device), not cloud-based.
// The "Device Access Key" set here must match DEVICE_KEY on the
// ESP8266 firmware — that's what actually stops someone who isn't
// the farmer from sending fence/buzzer commands directly to the
// collar, even if they know the WiFi password.

const String _kUsername = 'sh_username';
const String _kPassword = 'sh_password';
const String _kDeviceKey = 'sh_device_key';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  bool _hasAccount = false;

  @override
  void initState() {
    super.initState();
    _checkAccount();
  }

  Future<void> _checkAccount() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hasAccount = prefs.containsKey(_kUsername);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFF10231A),
        body: Center(child: CircularProgressIndicator(color: Colors.greenAccent)),
      );
    }
    return _hasAccount ? const LoginScreen() : const RegisterScreen();
  }
}

// ---------------------------------------------------------------
// Shared UI pieces
// ---------------------------------------------------------------
InputDecoration _fieldDecoration(String label, IconData icon) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, color: Colors.greenAccent),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );
}

// ---------------------------------------------------------------
// Register Screen
// ---------------------------------------------------------------
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _deviceKey = TextEditingController();
  bool _saving = false;
  String? _error;

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUsername, _username.text.trim());
    await prefs.setString(_kPassword, _password.text);
    await prefs.setString(_kDeviceKey, _deviceKey.text.trim());
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => MainScreen(deviceKey: _deviceKey.text.trim()),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF10231A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.shield, color: Colors.greenAccent, size: 56),
                  const SizedBox(height: 12),
                  const Text('Set up ZoneLock',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Create your farmer account for this phone',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _username,
                    style: const TextStyle(color: Colors.white),
                    decoration: _fieldDecoration('Your Name', Icons.person),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: _fieldDecoration('App Password', Icons.lock),
                    validator: (v) => (v == null || v.length < 4) ? 'At least 4 characters' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirmPassword,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: _fieldDecoration('Confirm Password', Icons.lock_outline),
                    validator: (v) => v != _password.text ? 'Passwords do not match' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _deviceKey,
                    style: const TextStyle(color: Colors.white),
                    decoration: _fieldDecoration('Device Access Key', Icons.key),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the collar\'s device key' : null,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'This must match the DEVICE_KEY set in the ESP8266 firmware. '
                        'It authorises fence/buzzer commands sent to the collar.',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  const SizedBox(height: 22),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                    ),
                  ElevatedButton(
                    onPressed: _saving ? null : _register,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _saving
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Create Account', style: TextStyle(fontSize: 16, color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------
// Login Screen
// ---------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _password = TextEditingController();
  String _username = '';
  String? _error;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _username = prefs.getString(_kUsername) ?? 'Farmer');
  }

  Future<void> _login() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final prefs = await SharedPreferences.getInstance();
    final savedPassword = prefs.getString(_kPassword) ?? '';
    final deviceKey = prefs.getString(_kDeviceKey) ?? '';

    if (_password.text == savedPassword) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => MainScreen(deviceKey: deviceKey),
      ));
    } else {
      setState(() {
        _error = 'Incorrect password';
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF10231A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.shield, color: Colors.greenAccent, size: 56),
                const SizedBox(height: 12),
                Text('Welcome back, $_username',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 28),
                TextField(
                  controller: _password,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: _fieldDecoration('App Password', Icons.lock),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 18),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                ElevatedButton(
                  onPressed: _checking ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _checking
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Unlock ZoneLock', style: TextStyle(fontSize: 16, color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
