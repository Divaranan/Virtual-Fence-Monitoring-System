import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dashboard.dart';
import 'auth.dart';

// SIMPLIFIED VERSION — no notification system, no database/
// ThingSpeak/history. Only two things come from the device: GPS
// location (/gps) and gyro/activity data (/activity). Fence,
// buzzer, login/logout, and live monitoring all still work exactly
// as before; the app just displays state on-screen instead of
// pushing alerts or syncing anywhere.

void main() {
  runApp(const HerdShieldApp());
}

bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  if (polygon.length < 3) return true;
  int intersections = 0;
  for (int i = 0; i < polygon.length; i++) {
    LatLng a = polygon[i];
    LatLng b = polygon[(i + 1) % polygon.length];
    if (((a.longitude <= point.longitude && point.longitude < b.longitude) ||
        (b.longitude <= point.longitude &&
            point.longitude < a.longitude)) &&
        (point.latitude <
            (b.latitude - a.latitude) *
                (point.longitude - a.longitude) /
                (b.longitude - a.longitude) +
                a.latitude)) {
      intersections++;
    }
  }
  return intersections % 2 == 1;
}

class HerdShieldApp extends StatelessWidget {
  const HerdShieldApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZoneLock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B6B3A)),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class MainScreen extends StatefulWidget {
  final String deviceKey;
  const MainScreen({super.key, required this.deviceKey});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  LatLng? collarLocation;
  LatLng? phoneLocation;
  bool isAlert = false;
  bool fenceActive = false;
  bool gpsFix = false;
  String statusMessage = "Waiting for GPS...";
  String cattleStatus = "Normal";
  int alertCount = 0;
  bool espConnected = false;
  double batteryVoltage = 0.0;
  int batteryPct = 0;

  String activityLabel = "Resting";
  double svmAcc = 0.0;
  double svmGyro = 0.0;
  double roll = 0.0;
  double pitch = 0.0;
  double yaw = 0.0;
  double tempC = 0.0;

  List<double> svmAccHistory = List.filled(30, 0.0);
  List<double> svmGyroHistory = List.filled(30, 0.0);
  List<double> tempHistory = List.filled(30, 0.0);

  List<LatLng> polygonPoints = [];
  bool drawingMode = false;

  final String espIP = "http://192.168.4.1";
  Timer? _pollTimer;
  Timer? _activityTimer;

  @override
  void initState() {
    super.initState();
    _startPhoneLocation();
    _startPolling();
    _startActivityPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _activityTimer?.cancel();
    super.dispose();
  }

  Future<void> _startPhoneLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return;

    late LocationSettings locationSettings;
    if (Platform.isAndroid) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
      );
    } else {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 1,
        pauseLocationUpdatesAutomatically: false,
      );
    }

    Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position pos) {
      setState(() => phoneLocation = LatLng(pos.latitude, pos.longitude));
    });
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final response = await http
            .get(Uri.parse('$espIP/gps'))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          bool wasAlert = isAlert;
          setState(() {
            espConnected = true;
            gpsFix = data['fix'] ?? false;
            batteryVoltage = (data['battery'] as num?)?.toDouble() ?? batteryVoltage;
            batteryPct = (data['batteryPct'] as num?)?.toInt() ?? batteryPct;
            if (gpsFix) {
              collarLocation = LatLng(
                (data['lat'] as num).toDouble(),
                (data['lon'] as num).toDouble(),
              );
            }
            statusMessage = gpsFix
                ? "GPS: ${collarLocation?.latitude.toStringAsFixed(5)}, ${collarLocation?.longitude.toStringAsFixed(5)}"
                : "Searching for GPS signal...";
            // Trust the collar's own fence-breach flag directly — it
            // runs the same check continuously on-device regardless
            // of whether the app is connected, so this is always the
            // authoritative state, not just a local re-check.
            isAlert = data['alert'] ?? false;
            if (isAlert && !wasAlert) {
              alertCount++;
              cattleStatus = "Alert";
            } else if (!isAlert && cattleStatus == "Alert") {
              cattleStatus = "Normal";
            }
          });
        }
      } catch (e) {
        setState(() {
          espConnected = false;
          statusMessage = "SmartHerd is not connected";
        });
      }
    });
  }

  void _startActivityPolling() {
    _activityTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final response = await http
            .get(Uri.parse('$espIP/activity'))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          setState(() {
            activityLabel = data['activity'] ?? 'Resting';
            svmAcc = (data['svm_acc'] as num).toDouble();
            svmGyro = (data['svm_gyro'] as num).toDouble();
            roll = (data['roll'] as num).toDouble();
            pitch = (data['pitch'] as num).toDouble();
            yaw = (data['yaw'] as num).toDouble();
            tempC = (data['temp'] as num).toDouble();
            svmAccHistory.removeAt(0);
            svmAccHistory.add(svmAcc);
            svmGyroHistory.removeAt(0);
            svmGyroHistory.add(svmGyro);
            tempHistory.removeAt(0);
            tempHistory.add(tempC);
          });
        }
      } catch (_) {}
    });
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF10231A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Choose how you want to log out.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _doLogout(resetAccount: false);
            },
            child: const Text('Logout', style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _doLogout(resetAccount: true);
            },
            child: const Text('Logout & Reset\n(for demo)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _doLogout({required bool resetAccount}) async {
    if (resetAccount) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthGate()),
          (route) => false,
    );
  }

  Future<bool> _sendFenceToESP() async {
    if (polygonPoints.length < 3) return false;
    double minLat = polygonPoints.map((p) => p.latitude).reduce(min);
    double maxLat = polygonPoints.map((p) => p.latitude).reduce(max);
    double minLon = polygonPoints.map((p) => p.longitude).reduce(min);
    double maxLon = polygonPoints.map((p) => p.longitude).reduce(max);
    try {
      final resp = await http.post(Uri.parse('$espIP/setfence'), body: {
        'lat1': minLat.toString(),
        'lon1': minLon.toString(),
        'lat2': maxLat.toString(),
        'lon2': maxLon.toString(),
        'key': widget.deviceKey,
      }).timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Only shows "ACTIVE" once the ESP actually confirms it received the
  // fence — an unstable WiFi connection could otherwise silently drop
  // the /setfence request while the app still claimed protection was
  // on. Retries a few times since a flaky link often succeeds on the
  // 2nd or 3rd attempt.
  Future<void> _confirmAndActivateFence() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('📡 Sending fence to collar...'),
      duration: Duration(seconds: 2),
    ));

    bool success = false;
    for (int attempt = 1; attempt <= 3 && !success; attempt++) {
      success = await _sendFenceToESP();
      if (!success && attempt < 3) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (!mounted) return;

    if (success) {
      setState(() => fenceActive = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Fence confirmed on collar! ZoneLock ACTIVE!'),
        backgroundColor: Color(0xFF1B6B3A),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text(
            '❌ Could not confirm fence with collar. Buzzer will NOT work yet — check connection and try again.'),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: _confirmAndActivateFence,
        ),
      ));
    }
  }

  Future<void> _stopBuzzer() async {
    try {
      await http
          .get(Uri.parse('$espIP/stop?key=${widget.deviceKey}'))
          .timeout(const Duration(seconds: 3));
      setState(() {
        isAlert = false;
        cattleStatus = "Normal";
      });
    } catch (_) {}
  }

  void _resetFence() {
    setState(() {
      polygonPoints.clear();
      fenceActive = false;
      isAlert = false;
      drawingMode = false;
      cattleStatus = "Normal";
    });
    http
        .get(Uri.parse('$espIP/resetfence?key=${widget.deviceKey}'))
        .timeout(const Duration(seconds: 3))
        .catchError((_) => http.Response('', 500));
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      DashboardScreen(
        gpsFix: gpsFix,
        fenceActive: fenceActive,
        isAlert: isAlert,
        alertCount: alertCount,
        statusMessage: statusMessage,
        cattleStatus: cattleStatus,
        onGoToMap: () => setState(() => _currentIndex = 1),
      ),
      MapTab(
        phoneLocation: phoneLocation,
        collarLocation: collarLocation,
        polygonPoints: polygonPoints,
        fenceActive: fenceActive,
        drawingMode: drawingMode,
        statusMessage: statusMessage,
        gpsFix: gpsFix,
        isAlert: isAlert,
        espConnected: espConnected,
        onToggleDrawMode: () {
          setState(() {
            drawingMode = !drawingMode;
            if (!drawingMode && polygonPoints.length < 3) polygonPoints.clear();
          });
        },
        onMapTap: (LatLng tapped) {
          if (!drawingMode) return;
          if (polygonPoints.length >= 3) {
            final dist = const Distance()
                .as(LengthUnit.Meter, tapped, polygonPoints.first);
            if (dist < 8) {
              setState(() => drawingMode = false);
              _confirmAndActivateFence();
              return;
            }
          }
          setState(() => polygonPoints.add(tapped));
        },
        onReset: _resetFence,
      ),
      ActivityTab(
        activityLabel: activityLabel,
        svmAcc: svmAcc,
        svmGyro: svmGyro,
        roll: roll,
        pitch: pitch,
        yaw: yaw,
        tempC: tempC,
        svmAccHistory: svmAccHistory,
        svmGyroHistory: svmGyroHistory,
        tempHistory: tempHistory,
        espConnected: espConnected,
      ),
      AlertTab(
        isAlert: isAlert,
        collarLocation: collarLocation,
        alertCount: alertCount,
        onStopBuzzer: _stopBuzzer,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('🛡️ ZoneLock'),
          if (fenceActive)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('ACTIVE',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.bold)),
            ),
          const SizedBox(width: 8),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: espConnected ? Colors.greenAccent : Colors.red,
              shape: BoxShape.circle,
            ),
          ),
        ]),
        backgroundColor: const Color(0xFF0A2E1A),
        foregroundColor: Colors.white,
        actions: [
          if (batteryVoltage > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(children: [
                Icon(
                  batteryPct > 60
                      ? Icons.battery_full
                      : batteryPct > 25
                      ? Icons.battery_5_bar
                      : Icons.battery_alert,
                  color: batteryPct > 25 ? Colors.greenAccent : Colors.orangeAccent,
                  size: 20,
                ),
                const SizedBox(width: 2),
                Text('$batteryPct%', style: const TextStyle(fontSize: 13)),
              ]),
            ),
          if (isAlert)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Icon(Icons.warning_amber_rounded, color: Colors.yellow),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF10231A),
            onSelected: (value) {
              if (value == 'logout') _confirmLogout();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, color: Colors.white70, size: 18),
                  SizedBox(width: 8),
                  Text('Logout', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        selectedItemColor: const Color(0xFF1B6B3A),
        unselectedItemColor: Colors.grey,
        backgroundColor: const Color(0xFF0A2E1A),
        selectedLabelStyle: const TextStyle(color: Colors.greenAccent),
        onTap: (i) => setState(() => _currentIndex = i),
        items: [
          const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard), label: 'Dashboard'),
          const BottomNavigationBarItem(icon: Icon(Icons.map), label: 'Map'),
          const BottomNavigationBarItem(
              icon: Icon(Icons.monitor_heart), label: 'Activity'),
          BottomNavigationBarItem(
            icon: Stack(children: [
              const Icon(Icons.notifications),
              if (isAlert)
                const Positioned(
                  top: 0,
                  right: 0,
                  child: CircleAvatar(radius: 5, backgroundColor: Colors.red),
                ),
            ]),
            label: 'Alert',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// WAVE PAINTER
// ============================================================
class WavePainter extends CustomPainter {
  final List<double> data;
  final Color color;
  final double maxVal;

  const WavePainter({
    required this.data,
    required this.color,
    required this.maxVal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    final ui.Path path = ui.Path();
    final ui.Path fillPath = ui.Path();

    double xStep = size.width / (data.length - 1);
    double clampedMax = maxVal <= 0 ? 1 : maxVal;

    fillPath.moveTo(0, size.height);

    for (int i = 0; i < data.length; i++) {
      double x = i * xStep;
      double normalized = (data[i] / clampedMax).clamp(0.0, 1.0);
      double y = size.height - (normalized * size.height * 0.85) - size.height * 0.05;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        double prevX = (i - 1) * xStep;
        double prevNorm = (data[i - 1] / clampedMax).clamp(0.0, 1.0);
        double prevY = size.height - (prevNorm * size.height * 0.85) - size.height * 0.05;
        double cpX = (prevX + x) / 2;
        path.cubicTo(cpX, prevY, cpX, y, x, y);
        fillPath.cubicTo(cpX, prevY, cpX, y, x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;
    for (int i = 1; i < 4; i++) {
      double y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    if (data.isNotEmpty) {
      double lastNorm = (data.last / clampedMax).clamp(0.0, 1.0);
      double dotY = size.height - (lastNorm * size.height * 0.85) - size.height * 0.05;
      canvas.drawCircle(
        Offset(size.width, dotY),
        4,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(WavePainter oldDelegate) => true;
}

// ============================================================
// ACTIVITY TAB — live monitoring only, no history/export/summary
// ============================================================
class ActivityTab extends StatelessWidget {
  final String activityLabel;
  final double svmAcc, svmGyro, roll, pitch, yaw, tempC;
  final List<double> svmAccHistory, svmGyroHistory, tempHistory;
  final bool espConnected;

  const ActivityTab({
    super.key,
    required this.activityLabel,
    required this.svmAcc,
    required this.svmGyro,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.tempC,
    required this.svmAccHistory,
    required this.svmGyroHistory,
    required this.tempHistory,
    required this.espConnected,
  });

  Color get _activityColor {
    switch (activityLabel) {
      case 'Grazing':   return const Color(0xFFF9C74F);
      case 'Walking':   return Colors.blue;
      case 'Panic':     return Colors.orange;
      case 'Distress':  return Colors.red;
      case 'Immobile':  return Colors.deepPurple;
      default:          return const Color(0xFF1B6B3A);
    }
  }

  String get _activityEmoji {
    switch (activityLabel) {
      case 'Grazing':   return '🌿';
      case 'Walking':   return '🚶';
      case 'Panic':     return '⚠️';
      case 'Distress':  return '🚨';
      case 'Immobile':  return '🆘';
      default:          return '😴';
    }
  }

  String get _activityDesc {
    switch (activityLabel) {
      case 'Grazing':   return 'Cattle is eating / grazing';
      case 'Walking':   return 'Cattle is walking normally';
      case 'Panic':     return 'Unusual movement — monitoring';
      case 'Distress':  return 'HIGH MOVEMENT DETECTED!';
      case 'Immobile':  return 'NO MOVEMENT FOR 2+ HOURS — CHECK ANIMAL';
      default:          return 'Cattle is resting';
    }
  }

  Color get _tempColor {
    if (tempC > 40.0) return Colors.red;
    if (tempC > 38.5) return Colors.orange;
    return Colors.green;
  }

  String get _tempStatus {
    if (tempC > 40.0) return '🔴 Heat Stress!';
    if (tempC > 38.5) return '🟠 Warm';
    return '🟢 Normal';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A2E1A),
      child: !espConnected
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.wifi_off, size: 64, color: Colors.red),
            SizedBox(height: 16),
            Text('SmartHerd is not connected',
                style: TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text('Connect to SmartHerd_Collar WiFi',
                style: TextStyle(fontSize: 13, color: Colors.white54)),
          ],
        ),
      )
          : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: _activityColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _activityColor, width: 2),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_activityEmoji,
                          style: const TextStyle(fontSize: 40)),
                      const SizedBox(height: 8),
                      Text(activityLabel,
                          style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: _activityColor)),
                      Text(_activityDesc,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70)),
                    ]),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _tempColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _tempColor),
                  ),
                  child: Column(children: [
                    const Text('🌡️',
                        style: TextStyle(fontSize: 22)),
                    Text('${tempC.toStringAsFixed(1)}°C',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: _tempColor)),
                    Text(_tempStatus,
                        style: TextStyle(
                            fontSize: 10, color: _tempColor)),
                  ]),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          _waveCard('Accelerometer Signal (SVM)',
              '${svmAcc.toStringAsFixed(2)} m/s²',
              svmAccHistory, Colors.orange, 10.0),
          const SizedBox(height: 12),
          _waveCard('Gyroscope Signal (SVM)',
              '${svmGyro.toStringAsFixed(1)} °/s',
              svmGyroHistory, Colors.lightBlue, 60.0),
          const SizedBox(height: 12),
          _waveCard('Temperature',
              '${tempC.toStringAsFixed(1)} °C',
              tempHistory, _tempColor, 50.0),

          const SizedBox(height: 16),

          const Align(
            alignment: Alignment.centerLeft,
            child: Text('📊 Activity Thresholds',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          _thresholdRow('😴 Resting',
              'SVM_acc < 3.43  |  SVM_gyro < 10 °/s',
              const Color(0xFF1B6B3A)),
          _thresholdRow('🌿 Grazing',
              'SVM_acc > 4.41  |  SVM_gyro > 27 °/s',
              const Color(0xFFF9C74F)),
          _thresholdRow('🚶 Walking',
              'SVM_acc 3.43–4.41  |  SVM_gyro 10–27',
              Colors.blue),
          _thresholdRow('🚨 Distress',
              'SVM_acc > 5.39  |  SVM_gyro > 50 °/s',
              Colors.red),
          const SizedBox(height: 8),
          _thresholdRow(
              '🟢 Normal Temp', 'Below 38.5°C', Colors.green),
          _thresholdRow(
              '🟠 Warm', '38.5 – 40.0°C', Colors.orange),
          _thresholdRow(
              '🔴 Heat Stress', 'Above 40.0°C', Colors.red),
        ]),
      ),
    );
  }

  Widget _waveCard(String title, String value, List<double> history,
      Color color, double maxVal) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(title,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 70,
          child: CustomPaint(
            painter: WavePainter(
                data: history, color: color, maxVal: maxVal),
            child: Container(),
          ),
        ),
      ]),
    );
  }

  Widget _thresholdRow(String label, String range, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Text(label,
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 12)),
        const Spacer(),
        Text(range,
            style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ]),
    );
  }
}

// ============================================================
// MAP TAB
// ============================================================
class MapTab extends StatefulWidget {
  final LatLng? phoneLocation;
  final LatLng? collarLocation;
  final List<LatLng> polygonPoints;
  final bool fenceActive, drawingMode, gpsFix, isAlert, espConnected;
  final String statusMessage;
  final VoidCallback onToggleDrawMode, onReset;
  final Function(LatLng) onMapTap;

  const MapTab({
    super.key,
    required this.phoneLocation,
    required this.collarLocation,
    required this.polygonPoints,
    required this.fenceActive,
    required this.drawingMode,
    required this.statusMessage,
    required this.gpsFix,
    required this.isAlert,
    required this.espConnected,
    required this.onToggleDrawMode,
    required this.onMapTap,
    required this.onReset,
  });

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final MapController _mapController = MapController();

  LatLng get _center =>
      widget.collarLocation ??
          widget.phoneLocation ??
          const LatLng(8.5774, 81.2330);

  String get _instruction {
    if (!widget.espConnected) return '⚠️ SmartHerd is not connected';
    if (!widget.drawingMode && widget.polygonPoints.isEmpty)
      return '🖊️ Press "Draw Fence" → tap to draw fence';
    if (widget.drawingMode && widget.polygonPoints.isEmpty)
      return '📍 Tap first corner (START dot)';
    if (widget.drawingMode && widget.polygonPoints.length < 3)
      return '📍 ${widget.polygonPoints.length} points. Continue tapping...';
    if (widget.drawingMode)
      return '🎯 ${widget.polygonPoints.length} points. Tap START → AUTO CLOSE!';
    if (widget.fenceActive)
      return '✅ ZoneLock ACTIVE! Alert when boundary crossed';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        width: double.infinity,
        color: widget.espConnected
            ? const Color(0xFF155724)
            : Colors.red.shade900,
        padding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(
              widget.espConnected ? Icons.wifi : Icons.wifi_off,
              color: Colors.white,
              size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(widget.statusMessage,
                style:
                const TextStyle(color: Colors.white, fontSize: 11),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
      Expanded(
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _center,
            initialZoom: 17.0,
            interactionOptions: InteractionOptions(
              flags: widget.drawingMode
                  ? InteractiveFlag.pinchZoom
                  : InteractiveFlag.all,
            ),
            onTap: (tapPos, latLng) => widget.onMapTap(latLng),
          ),
          children: [
            TileLayer(
              urlTemplate:
              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.herdshield.app',
            ),
            if (widget.fenceActive && widget.polygonPoints.length >= 3)
              PolygonLayer(polygons: [
                Polygon(
                  points: widget.polygonPoints,
                  color: (widget.isAlert ? Colors.red : Colors.green)
                      .withValues(alpha: 0.15),
                  borderColor: widget.isAlert
                      ? Colors.red
                      : const Color(0xFF1B6B3A),
                  borderStrokeWidth: 2.5,
                ),
              ]),
            if (widget.drawingMode &&
                widget.polygonPoints.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: widget.polygonPoints,
                  color: Colors.orange,
                  strokeWidth: 2.5,
                  isDotted: true,
                ),
              ]),
            MarkerLayer(markers: [
              if (widget.phoneLocation != null)
                Marker(
                  point: widget.phoneLocation!,
                  width: 44,
                  height: 50,
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        borderRadius: BorderRadius.circular(20),
                        border:
                        Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.person_pin,
                          color: Colors.white, size: 18),
                    ),
                    const Text('Me',
                        style: TextStyle(
                            fontSize: 9,
                            color: Colors.blue,
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
              if (widget.collarLocation != null)
                Marker(
                  point: widget.collarLocation!,
                  width: 52,
                  height: 55,
                  child: Column(children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: widget.isAlert
                            ? Colors.red
                            : const Color(0xFF1B6B3A),
                        borderRadius: BorderRadius.circular(20),
                        border:
                        Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Text('🐄',
                          style: TextStyle(fontSize: 18)),
                    ),
                    Text('Cow',
                        style: TextStyle(
                            fontSize: 9,
                            color: widget.isAlert
                                ? Colors.red
                                : const Color(0xFF1B6B3A),
                            fontWeight: FontWeight.bold)),
                  ]),
                ),
              for (int i = 0; i < widget.polygonPoints.length; i++)
                Marker(
                  point: widget.polygonPoints[i],
                  width: i == 0 ? 44 : 28,
                  height: i == 0 ? 54 : 28,
                  child: i == 0
                      ? Column(children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.green
                                .withValues(alpha: 0.5),
                            blurRadius: 8,
                            spreadRadius: 3,
                          )
                        ],
                      ),
                      child: const Center(
                        child: Text('START',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                    if (widget.polygonPoints.length >= 3 &&
                        widget.drawingMode)
                      const Text('tap!',
                          style: TextStyle(
                              fontSize: 9,
                              color: Colors.green,
                              fontWeight: FontWeight.bold)),
                  ])
                      : Container(
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),
      if (_instruction.isNotEmpty)
        Container(
          width: double.infinity,
          color: !widget.espConnected
              ? Colors.red.shade100
              : widget.drawingMode
              ? Colors.orange.shade50
              : widget.fenceActive
              ? Colors.green.shade50
              : Colors.grey.shade100,
          padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(_instruction,
              style: TextStyle(
                  fontSize: 12,
                  color: !widget.espConnected
                      ? Colors.red.shade900
                      : widget.drawingMode
                      ? Colors.orange.shade800
                      : widget.fenceActive
                      ? const Color(0xFF1B6B3A)
                      : Colors.black87)),
        ),
      Container(
        color: Colors.white,
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed:
              widget.fenceActive ? null : widget.onToggleDrawMode,
              icon: Icon(
                  widget.drawingMode ? Icons.stop : Icons.edit),
              label: Text(widget.drawingMode
                  ? 'Stop Drawing'
                  : 'Draw Fence'),
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.drawingMode
                    ? Colors.orange
                    : const Color(0xFF1B6B3A),
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () {
              final target =
                  widget.collarLocation ?? widget.phoneLocation;
              if (target != null) _mapController.move(target, 17);
            },
            icon: const Icon(Icons.my_location),
            label: const Text('Find'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: widget.onReset,
            icon: const Icon(Icons.refresh),
            label: const Text('Reset'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey,
                foregroundColor: Colors.white),
          ),
        ]),
      ),
    ]);
  }
}

// ============================================================
// ALERT TAB
// ============================================================
class AlertTab extends StatelessWidget {
  final bool isAlert;
  final LatLng? collarLocation;
  final int alertCount;
  final VoidCallback onStopBuzzer;

  const AlertTab({
    super.key,
    required this.isAlert,
    required this.collarLocation,
    required this.alertCount,
    required this.onStopBuzzer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A2E1A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: isAlert
              ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  size: 80, color: Colors.red),
              const SizedBox(height: 16),
              const Text('🚨 ALERT!\nCow left the fence!',
                  style: TextStyle(
                      fontSize: 26,
                      color: Colors.red,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              if (collarLocation != null)
                Text(
                  'Last location:\n'
                      '${collarLocation!.latitude.toStringAsFixed(6)}, '
                      '${collarLocation!.longitude.toStringAsFixed(6)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, color: Colors.white70),
                ),
              const SizedBox(height: 8),
              Text('Total alerts today: $alertCount',
                  style: TextStyle(
                      fontSize: 13,
                      color: Colors.red.shade300)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onStopBuzzer,
                icon: const Icon(Icons.volume_off),
                label: const Text('Stop Buzzer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 14),
                ),
              ),
            ],
          )
              : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.shield,
                  size: 80, color: Color(0xFF1B6B3A)),
              const SizedBox(height: 16),
              const Text('✅ All good!\nCow is inside the fence.',
                  style: TextStyle(
                      fontSize: 20, color: Colors.white),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text('Total alerts today: $alertCount',
                  style: TextStyle(
                      fontSize: 13,
                      color: Colors.green.shade400)),
            ],
          ),
        ),
      ),
    );
  }
}
