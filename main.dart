import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const AstroRoverApp());
}

// ── Palette ──────────────────────────────────────────────────────────────────
const _void   = Color(0xFF0A0A0F);
const _panel  = Color(0xFF12121A);
const _border = Color(0xFF1E1E2E);
const _cyan   = Color(0xFF00E5FF);
const _cyanDim= Color(0xFF004D5A);
const _green  = Color(0xFF39FF14);
const _red    = Color(0xFFFF3B30);
const _text   = Color(0xFFE0E0F0);
const _dim    = Color(0xFF5A5A7A);

// ── Direction enum ────────────────────────────────────────────────────────────
enum RoverDir { stop, forward, backward, left, right }

extension RoverDirExt on RoverDir {
  String get cmd => name; // matches /cmd?c= values
  String get label => switch (this) {
    RoverDir.stop     => '■  HALT',
    RoverDir.forward  => '▲  FWD',
    RoverDir.backward => '▼  REV',
    RoverDir.left     => '◀  LEFT',
    RoverDir.right    => '▶  RIGHT',
  };
  Color get color => switch (this) {
    RoverDir.stop     => _dim,
    RoverDir.forward  => _cyan,
    RoverDir.backward => _red,
    RoverDir.left     => const Color(0xFFFFAA00),
    RoverDir.right    => const Color(0xFFFFAA00),
  };
}

// ── App root ──────────────────────────────────────────────────────────────────
class AstroRoverApp extends StatelessWidget {
  const AstroRoverApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'AstroRover Remote',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      scaffoldBackgroundColor: _void,
      colorScheme: const ColorScheme.dark(primary: _cyan, surface: _panel),
      fontFamily: 'monospace',
    ),
    home: const RemoteScreen(),
  );
}

// ── Main screen ───────────────────────────────────────────────────────────────
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});
  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen>
    with TickerProviderStateMixin {

  // Config
  String _ip         = '192.168.1.100';
  int    _speed      = 200;
  double _deadZone   = 8.0;   // degrees
  bool   _active     = false;

  // Sensor state
  double _tiltX = 0; // pitch  (+forward / -backward)
  double _tiltY = 0; // roll   (+right   / -left)
  RoverDir _dir = RoverDir.stop;
  RoverDir _lastSent = RoverDir.stop;

  // Status
  bool   _connected  = false;
  String _statusMsg  = 'STANDBY';
  int    _cmdCount   = 0;
  DateTime? _lastCmdTime;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  Timer? _sendTimer;

  late AnimationController _pulseCtrl;
  late Animation<double>   _pulseAnim;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _pulseCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _ip       = p.getString('ip')    ?? _ip;
      _speed    = p.getInt('speed')    ?? _speed;
      _deadZone = p.getDouble('dz')    ?? _deadZone;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ip',    _ip);
    await p.setInt('speed',    _speed);
    await p.setDouble('dz',    _deadZone);
  }

  void _startListening() {
    _accelSub = accelerometerEventStream().listen(_onAccel);
    // Send commands at 10 Hz — avoids flooding the ESP32
    _sendTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _maybeSend());
    setState(() { _active = true; _statusMsg = 'ACTIVE'; });
  }

  void _stopListening() {
    _accelSub?.cancel();
    _sendTimer?.cancel();
    _accelSub = null;
    _sendTimer = null;
    _sendCmd(RoverDir.stop);
    setState(() { _active = false; _dir = RoverDir.stop; _statusMsg = 'STANDBY'; });
  }

  void _onAccel(AccelerometerEvent e) {
    // e.x = left/right tilt, e.y = forward/back tilt
    // Convert m/s² → degrees (−90..90)
    final pitch = _clampDeg(atan2(-e.y, sqrt(e.x*e.x + e.z*e.z)) * 180 / pi);
    final roll  = _clampDeg(atan2( e.x, sqrt(e.y*e.y + e.z*e.z)) * 180 / pi);

    RoverDir next;
    final dz = _deadZone;

    if (pitch.abs() > roll.abs()) {
      if (pitch >  dz)  next = RoverDir.forward;
      else if (pitch < -dz) next = RoverDir.backward;
      else next = RoverDir.stop;
    } else {
      if (roll >  dz)  next = RoverDir.right;
      else if (roll < -dz) next = RoverDir.left;
      else next = RoverDir.stop;
    }

    setState(() { _tiltX = pitch; _tiltY = roll; _dir = next; });
  }

  double _clampDeg(double d) => d.clamp(-90.0, 90.0);

  void _maybeSend() {
    if (_dir != _lastSent) {
      _sendCmd(_dir);
      _lastSent = _dir;
    }
  }

  Future<void> _sendCmd(RoverDir d) async {
    try {
      final uri = Uri.parse(
        'http://$_ip/cmd?c=${d.cmd}&s=$_speed');
      final resp = await http.get(uri).timeout(const Duration(milliseconds: 300));
      setState(() {
        _connected  = resp.statusCode == 200;
        _cmdCount++;
        _lastCmdTime = DateTime.now();
        _statusMsg   = _connected ? 'LINK OK' : 'HTTP ${resp.statusCode}';
      });
    } catch (_) {
      setState(() { _connected = false; _statusMsg = 'NO LINK'; });
    }
  }

  @override
  void dispose() {
    _stopListening();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildHorizonBall()),
            _buildDirLabel(),
            const SizedBox(height: 12),
            _buildTiltReadouts(),
            const SizedBox(height: 16),
            _buildControlRow(),
            const SizedBox(height: 12),
            _buildFooter(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: _border)),
    ),
    child: Row(
      children: [
        AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _active ? _green : _dim,
              boxShadow: _active ? [
                BoxShadow(color: _green.withOpacity(_pulseAnim.value * 0.8),
                    blurRadius: 10, spreadRadius: 2)
              ] : [],
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text('ASTROROVER', style: TextStyle(
          color: _text, fontSize: 18, letterSpacing: 4,
          fontWeight: FontWeight.w700)),
        const Spacer(),
        GestureDetector(
          onTap: _showSettings,
          child: const Icon(Icons.tune, color: _dim, size: 22),
        ),
      ],
    ),
  );

  Widget _buildHorizonBall() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: CustomPaint(
      painter: _HorizonPainter(
        pitch: _tiltX,
        roll:  _tiltY,
        active: _active,
        dir:    _dir,
      ),
      child: const SizedBox(width: 260, height: 260),
    ),
  );

  Widget _buildDirLabel() => AnimatedSwitcher(
    duration: const Duration(milliseconds: 180),
    child: Text(
      _dir.label,
      key: ValueKey(_dir),
      style: TextStyle(
        color: _dir.color, fontSize: 22,
        letterSpacing: 5, fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _buildTiltReadouts() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _readout('PITCH', _tiltX, '°'),
        Container(width: 1, height: 36, color: _border),
        _readout('ROLL',  _tiltY, '°'),
        Container(width: 1, height: 36, color: _border),
        _readout('SPD',   _speed.toDouble(), ''),
      ],
    ),
  );

  Widget _readout(String label, double val, String unit) => Column(
    children: [
      Text(label, style: const TextStyle(color: _dim, fontSize: 10, letterSpacing: 2)),
      const SizedBox(height: 4),
      Text(
        '${val.toStringAsFixed(unit == '°' ? 1 : 0)}$unit',
        style: const TextStyle(color: _cyan, fontSize: 20,
          fontWeight: FontWeight.w700, letterSpacing: 1),
      ),
    ],
  );

  Widget _buildControlRow() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTapDown: (_) => _startListening(),
            onTapUp:   (_) => _stopListening(),
            onTapCancel: ()  => _stopListening(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 64,
              decoration: BoxDecoration(
                color: _active ? _cyan.withOpacity(0.15) : _panel,
                border: Border.all(
                  color: _active ? _cyan : _border, width: _active ? 2 : 1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  _active ? 'HOLD TO DRIVE' : 'HOLD TO DRIVE',
                  style: TextStyle(
                    color: _active ? _cyan : _dim,
                    letterSpacing: 3, fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildFooter() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _footerChip(Icons.wifi,
          _connected ? 'LINK' : 'NO LINK',
          _connected ? _green : _red),
        _footerChip(Icons.sports_esports, 'CMD $_cmdCount', _dim),
        _footerChip(Icons.router, _ip, _dim),
      ],
    ),
  );

  Widget _footerChip(IconData icon, String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: color, fontSize: 11, letterSpacing: 1)),
    ],
  );

  // ── Settings sheet ─────────────────────────────────────────────────────────

  void _showSettings() {
    final ipCtrl = TextEditingController(text: _ip);
    showModalBottomSheet(
      context: context,
      backgroundColor: _panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => StatefulBuilder(builder: (ctx, setSt) => Padding(
        padding: EdgeInsets.fromLTRB(24, 20, 24,
          MediaQuery.of(ctx).viewInsets.bottom + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SETTINGS', style: TextStyle(
              color: _cyan, letterSpacing: 4, fontSize: 13,
              fontWeight: FontWeight.w700)),
            const SizedBox(height: 20),
            _settingLabel('ROVER IP'),
            TextField(
              controller: ipCtrl,
              style: const TextStyle(color: _text, fontFamily: 'monospace'),
              keyboardType: TextInputType.url,
              decoration: _inputDeco('192.168.x.x'),
            ),
            const SizedBox(height: 16),
            _settingLabel('MOTOR SPEED  $_speed'),
            Slider(
              value: _speed.toDouble(),
              min: 100, max: 255, divisions: 31,
              activeColor: _cyan, inactiveColor: _cyanDim,
              onChanged: (v) => setSt(() => _speed = v.round()),
            ),
            const SizedBox(height: 4),
            _settingLabel('DEAD ZONE  ${_deadZone.toStringAsFixed(1)}°'),
            Slider(
              value: _deadZone,
              min: 3, max: 25, divisions: 22,
              activeColor: _cyan, inactiveColor: _cyanDim,
              onChanged: (v) => setSt(() => _deadZone = v),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: _void,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  setState(() { _ip = ipCtrl.text.trim(); });
                  _savePrefs();
                  Navigator.pop(context);
                },
                child: const Text('SAVE', letterSpacing: 4,
                  style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      )),
    );
  }

  Widget _settingLabel(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: const TextStyle(
      color: _dim, fontSize: 11, letterSpacing: 2)),
  );

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: _dim),
    filled: true, fillColor: _void,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _border)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _border)),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: _cyan)),
  );
}

// ── Horizon ball painter ──────────────────────────────────────────────────────
class _HorizonPainter extends CustomPainter {
  final double pitch;
  final double roll;
  final bool active;
  final RoverDir dir;
  _HorizonPainter({
    required this.pitch, required this.roll,
    required this.active, required this.dir,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final r  = size.width  / 2 - 4;

    // Clip to circle
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r)));

    // Sky / ground split based on pitch
    final pitchOffset = (pitch / 90.0) * r;
    final rollRad = roll * pi / 180;
    final skyPaint  = Paint()..color = const Color(0xFF060B14);
    final gndPaint  = Paint()..color = const Color(0xFF1A0A00);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), gndPaint);

    final path = Path();
    path.moveTo(-r * 2, cy - pitchOffset);
    path.lineTo( r * 2 + cx, cy - pitchOffset);
    path.lineTo( r * 2 + cx, -r * 2);
    path.lineTo(-r * 2, -r * 2);
    path.close();

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(rollRad);
    canvas.translate(-cx, -cy);
    canvas.drawPath(path, skyPaint);

    // Horizon line
    final hPaint = Paint()
      ..color = active ? _cyan.withOpacity(0.8) : _dim.withOpacity(0.5)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(-r * 2, cy - pitchOffset),
      Offset( r * 2 + cx, cy - pitchOffset),
      hPaint,
    );

    // Tick marks on horizon
    for (int i = -3; i <= 3; i++) {
      if (i == 0) continue;
      final tx = cx + i * 20.0;
      final ty = cy - pitchOffset;
      canvas.drawLine(
        Offset(tx, ty - 6), Offset(tx, ty + 6),
        Paint()..color = _dim..strokeWidth = 1,
      );
    }

    canvas.restore();
    canvas.restore();

    // Outer ring
    final ringColor = active ? dir.color : _border;
    canvas.drawCircle(Offset(cx, cy), r,
      Paint()
        ..color = ringColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 2.5 : 1.5,
    );

    // Glow when active
    if (active) {
      canvas.drawCircle(Offset(cx, cy), r + 4,
        Paint()
          ..color = dir.color.withOpacity(0.15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8,
      );
    }

    // Fixed crosshair
    final crossPaint = Paint()
      ..color = _cyan.withOpacity(active ? 0.9 : 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(cx - 20, cy), Offset(cx + 20, cy), crossPaint);
    canvas.drawLine(Offset(cx, cy - 20), Offset(cx, cy + 20), crossPaint);
    canvas.drawCircle(Offset(cx, cy), 4,
      Paint()..color = _cyan.withOpacity(active ? 1.0 : 0.4));

    // Cardinal labels
    final labelStyle = TextStyle(
      color: _dim, fontSize: 11,
      fontWeight: FontWeight.w600,
    );
    _drawLabel(canvas, 'F', Offset(cx, cy - r + 16), labelStyle);
    _drawLabel(canvas, 'B', Offset(cx, cy + r - 10), labelStyle);
    _drawLabel(canvas, 'L', Offset(cx - r + 10, cy), labelStyle);
    _drawLabel(canvas, 'R', Offset(cx + r - 10, cy), labelStyle);
  }

  void _drawLabel(Canvas c, String t, Offset o, TextStyle s) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: s),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_HorizonPainter old) =>
      old.pitch != pitch || old.roll != roll ||
      old.active != active || old.dir != dir;
}
