import 'package:flutter/material.dart';

class DashboardScreen extends StatefulWidget {
  final bool gpsFix;
  final bool fenceActive;
  final bool isAlert;
  final int alertCount;
  final String statusMessage;
  final String cattleStatus; // "Normal", "Resting", "Alert"
  final VoidCallback onGoToMap;

  const DashboardScreen({
    super.key,
    required this.gpsFix,
    required this.fenceActive,
    required this.isAlert,
    required this.alertCount,
    required this.statusMessage,
    required this.cattleStatus,
    required this.onGoToMap,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A2E1A),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '🛡️ ZoneLock',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'HerdShield Farm Management',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.green.shade300,
                        ),
                      ),
                    ],
                  ),
                  // Alert badge
                  if (widget.isAlert)
                    ScaleTransition(
                      scale: _pulseAnimation,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: Colors.white, size: 16),
                            SizedBox(width: 4),
                            Text('ALERT',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12)),
                          ],
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B6B3A),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: Colors.greenAccent, size: 16),
                          SizedBox(width: 4),
                          Text('SAFE',
                              style: TextStyle(
                                  color: Colors.greenAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 20),

              // ── Main Status Card ─────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: widget.isAlert
                        ? [const Color(0xFF7F0000), const Color(0xFFB71C1C)]
                        : [const Color(0xFF1B6B3A), const Color(0xFF2E7D32)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: (widget.isAlert ? Colors.red : Colors.green)
                          .withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          widget.isAlert ? '🚨' : '🐄',
                          style: const TextStyle(fontSize: 36),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.isAlert
                                  ? 'Cattle Left Fence!'
                                  : 'Cattle Status',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13),
                            ),
                            Text(
                              widget.isAlert ? 'BOUNDARY BREACH' : widget.cattleStatus,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.statusMessage,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Stats Row ────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      icon: Icons.satellite_alt,
                      label: 'GPS Signal',
                      value: widget.gpsFix ? 'Fixed ✅' : 'Searching...',
                      valueColor: widget.gpsFix ? Colors.greenAccent : Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.fence,
                      label: 'Virtual Fence',
                      value: widget.fenceActive ? 'Active ✅' : 'Not Set',
                      valueColor: widget.fenceActive ? Colors.greenAccent : Colors.grey,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      icon: Icons.notifications_active,
                      label: "Today's Alerts",
                      value: '${widget.alertCount}',
                      valueColor: widget.alertCount > 0 ? Colors.red.shade300 : Colors.greenAccent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.router,
                      label: 'Collar WiFi',
                      value: widget.gpsFix ? 'Connected' : 'Disconnected',
                      valueColor: widget.gpsFix ? Colors.greenAccent : Colors.red.shade300,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // ── Activity Status ──────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF112D1A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF1B6B3A), width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '📊 Activity Monitor',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    _ActivityBar(
                      label: 'Normal Grazing',
                      color: Colors.greenAccent,
                      isActive: widget.cattleStatus == 'Normal',
                    ),
                    const SizedBox(height: 8),
                    _ActivityBar(
                      label: 'Resting',
                      color: Colors.amber,
                      isActive: widget.cattleStatus == 'Resting',
                    ),
                    const SizedBox(height: 8),
                    _ActivityBar(
                      label: 'Alert / Panic',
                      color: Colors.red,
                      isActive: widget.cattleStatus == 'Alert' || widget.isAlert,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── Go to Map Button ─────────────────────────
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: widget.onGoToMap,
                  icon: const Icon(Icons.map),
                  label: const Text(
                    'View Live Map & Fence',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // ── Footer ──────────────────────────────────
              Center(
                child: Text(
                  'ZoneLock by HerdShield • Powered by IoT',
                  style: TextStyle(
                      color: Colors.green.shade800,
                      fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Stat Card Widget ─────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF112D1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1B6B3A), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.green.shade400, size: 22),
          const SizedBox(height: 8),
          Text(label,
              style: TextStyle(color: Colors.green.shade300, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 14,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ── Activity Bar Widget ──────────────────────────────────────
class _ActivityBar extends StatelessWidget {
  final String label;
  final Color color;
  final bool isActive;

  const _ActivityBar({
    required this.label,
    required this.color,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: isActive ? color : Colors.grey.shade700,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: isActive ? color : Colors.grey.shade600,
            fontSize: 13,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        const Spacer(),
        if (isActive)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'ACTIVE',
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }
}
