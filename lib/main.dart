import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// The ESP32 creates its own Wi-Fi and is always at this address.
const String esp32Ip = '192.168.4.1';
const int esp32UdpPort = 4210;
const String esp32WifiName = 'ESP32_CAR';

/// The ESP32 presses the buttons of the car's own remote control, so the
/// app talks only to the ESP32. Nothing in the car is changed.

/// true  = try speech recognition on the phone itself first (no internet,
///         faster). If the phone has no offline English, the app switches
///         to online recognition by itself (needs mobile data).
/// false = start with online recognition.
const bool useOfflineSpeech = true;

/// Language for speech. If the phone doesn't have it, the app picks
/// another English one, or the phone's own language.
const String preferredSpeechLocale = 'en_US';

/// FAST RESPONSE: true = "forward" / "backward" are sent the moment the
/// phone hears the word, so the car starts right away. If more words
/// follow in the same sentence ("forward LEFT", "forward 5 SECONDS"), the
/// longer command is sent a moment later and replaces it.
/// false = wait [driveSettle] for more words first (the old way: the car
/// starts up to 0.8 s later, but never does the short "forward" first).
const bool sendDriveAtOnce = true;
const Duration driveSettle = Duration(milliseconds: 800);

/// How often the app tells the car "I'm still here". The car stops by
/// itself if it hears nothing for 600 ms (see FAILSAFE_MS in the sketch).
const Duration heartbeatEvery = Duration(milliseconds: 150);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The app starts in voice mode, which is portrait.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: CarPage()));
}

/// Words the speech engine often hears instead of the real command word,
/// especially with noise or an accent. Each is changed to the real word.
const Map<String, String> soundAlikes = {
  // stop (a wrong "stop" is safe: it only stops the car)
  'stopp': 'stop', 'stops': 'stop', 'stopped': 'stop', 'stopping': 'stop',
  'stap': 'stop', 'stob': 'stop', 'stub': 'stop', 'top': 'stop',
  'halt': 'stop', 'brake': 'stop', 'break': 'stop', 'brakes': 'stop',
  // start
  'started': 'start', 'starts': 'start', 'startup': 'start', 'stat': 'start',
  'star': 'start', 'stars': 'start', 'stark': 'start', 'starch': 'start',
  // forward
  'forwards': 'forward', 'foreword': 'forward', 'forword': 'forward',
  'froward': 'forward', 'forwad': 'forward', 'forard': 'forward',
  'ahead': 'forward', 'front': 'forward', 'fourward': 'forward',
  'toward': 'forward', 'towards': 'forward',
  // backward
  'backwards': 'backward', 'backword': 'backward', 'bakward': 'backward',
  'packward': 'backward', 'back': 'backward', 'reverse': 'backward',
  'bag': 'backward', 'beck': 'backward',
  // left
  'lift': 'left', 'laughed': 'left', 'lef': 'left', 'leff': 'left',
  'loft': 'left', 'lefts': 'left', 'leftt': 'left',
  // right
  'write': 'right', 'rite': 'right', 'ride': 'right', 'wright': 'right',
  'rights': 'right', 'riot': 'right', 'righ': 'right', 'bright': 'right',
  // five
  '5': 'five', '5s': 'five', 'fife': 'five', 'fives': 'five',
  // drift
  'drifts': 'drift', 'drifting': 'drift', 'drifted': 'drift', 'rift': 'drift',
  'drip': 'drift', 'thrift': 'drift', 'spin': 'drift', 'spinning': 'drift',
  'rotate': 'drift', 'swing': 'drift',
  // off
  'of': 'off', 'auf': 'off', 'offf': 'off',
};

/// Two words the engine sometimes splits ("for ward") are joined first.
const Map<String, String> splitWords = {
  'for ward': 'forward',
  'four ward': 'forward',
  'for word': 'forward',
  'four word': 'forward',
  'fore word': 'forward',
  'for words': 'forward',
  'back ward': 'backward',
  'back word': 'backward',
  'back words': 'backward',
  'shut down': 'shutdown',
  'turn of': 'turn off',
  'turnoff': 'turn off',
  'turnon': 'turn on',
};

/// The real command words. A heard word that is ONE letter away from a
/// long word (two letters for "forward"/"backward") is treated as that word.
const List<String> commandWords = [
  'stop',
  'start',
  'forward',
  'backward',
  'left',
  'right',
  'five',
  'engine',
  'turn',
  'off',
  'on',
  'power',
  'switch',
  'shutdown',
  'seconds',
  'drift',
];

int _editDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// Cleans what the speech engine heard: lower case, no punctuation, split
/// words joined, sound-alike and slightly misspelled words corrected.
List<String> normalizeHeardWords(String sentence) {
  var text = sentence
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return [];
  // "5s" / "5 second" etc. keep the 5; "5-second" became "5 second" above.
  splitWords.forEach((from, to) {
    text = ' $text '.replaceAll(' $from ', ' $to ').trim();
  });
  return text.split(' ').map((w) {
    final alike = soundAlikes[w];
    if (alike != null) return alike;
    if (commandWords.contains(w) || w.length < 4) return w;
    for (final c in commandWords) {
      final allowed = c.length >= 7 ? 2 : (c.length >= 4 ? 1 : 0);
      if (allowed > 0 &&
          (c.length - w.length).abs() <= allowed &&
          _editDistance(w, c) <= allowed) {
        return c;
      }
    }
    return w;
  }).toList();
}

/// Turns the recognised words into a command for the ESP32, or null.
///
///   "start" / "engine on" / "turn on"          -> START
///   "turn off" / "engine off" / "shut down"    -> OFF
///   "stop"                                     -> STOP
///   "5 seconds forward" / "5s forward"         -> FWD5
///   "forward"                                  -> FWD   (short 1 s move)
///   "5 seconds backward"                       -> BACK5
///   "backward"                                 -> BACK  (short 1 s move)
///   "forward left" / "forward right"           -> FWD_LEFT / FWD_RIGHT (1 s)
///   "backward left" / "backward right"         -> BACK_LEFT / BACK_RIGHT (1 s)
///   "drift left" / "turn left" / "spin left"   -> DRIFT_LEFT  (nose to the left)
///   "drift right" / "turn right"               -> DRIFT_RIGHT (nose to the right)
String? parseVoiceCommand(String sentence) {
  final list = normalizeHeardWords(sentence);
  final text = list.join(' ');
  final words = list.toSet();
  final padded = ' $text ';
  bool has(List<String> options) => options.any(words.contains);
  bool phrase(List<String> options) =>
      options.any((p) => padded.contains(' $p '));

  // Order matters: STOP always wins, then engine off, then engine on.
  if (has(['stop', 'halt', 'brake', 'break'])) return 'STOP';
  if (phrase([
    'turn off',
    'engine off',
    'power off',
    'switch off',
    'shut down',
    'shutdown',
    'turnoff',
  ])) {
    return 'OFF';
  }
  if (has(['start', 'started', 'starts']) ||
      phrase(['engine on', 'turn on', 'power on', 'switch on'])) {
    return 'START';
  }

  final forward = has(['forward', 'forwards', 'ahead', 'front']);
  final backward = has(['backward', 'backwards', 'back', 'reverse']);
  final left = has(['left', 'lift', 'laughed']);
  final right = has(['right', 'write', 'rite', 'ride']);
  final five = has(['5', '5s', 'five', 'fives']);
  if (left && right) return null; // can't be both, ask again

  // "drift left" / "turn left": turn the nose on the spot.
  if ((has(['drift']) || phrase(['turn left', 'turn right'])) &&
      (left || right)) {
    return left ? 'DRIFT_LEFT' : 'DRIFT_RIGHT';
  }

  if (forward && !backward) {
    if (left) return 'FWD_LEFT';
    if (right) return 'FWD_RIGHT';
    return five ? 'FWD5' : 'FWD';
  }
  if (backward && !forward) {
    if (left) return 'BACK_LEFT';
    if (right) return 'BACK_RIGHT';
    return five ? 'BACK5' : 'BACK';
  }
  return null;
}

/// Picks the command from everything the speech engine thinks it heard.
/// Android gives up to 10 guesses ("alternates"), best first. If ANY guess
/// is "stop", the car stops (safe choice in noise). Otherwise the best
/// guess that is a command wins.
String? pickCommand(List<String> guesses) {
  final commands = guesses.map(parseVoiceCommand).toList();
  if (commands.contains('STOP')) return 'STOP';
  final best = commands.firstWhere((c) => c != null, orElse: () => null);
  // A plain "forward"/"backward" may have lost a word in the noise
  // ("forward laugh"). If another guess has the longer command in the
  // same direction, use that one.
  if (best == 'FWD' || best == 'BACK') {
    final longer = commands.firstWhere(
      (c) =>
          c != null &&
          c != best &&
          (best == 'FWD' ? c.startsWith('FWD') : c.startsWith('BACK')),
      orElse: () => null,
    );
    if (longer != null) return longer;
  }
  return best;
}

/// Decides WHEN a heard command is sent. Speech arrives word by word, and
/// "forward" could still become "forward left" or "forward 5 seconds".
///
/// [instantDrive] true (fast): plain FWD / BACK are sent at once. If the
/// same sentence then grows into a longer command in the same direction
/// (FWD -> FWD_LEFT, FWD_RIGHT, FWD5;
/// BACK -> BACK_LEFT, BACK_RIGHT, BACK5) within [upgradeWithin], that
/// longer command is sent too and replaces it on the car.
/// [instantDrive] false: plain FWD / BACK wait [settle] for more words (or
/// the end of the sentence). Every other command, STOP included, is
/// always sent at once.
///
/// The mic keeps listening after a command (it is NOT stopped and
/// restarted, which made some phones' speech service go deaf). Words that
/// already gave a command are skipped, so "forward ... stop" in one
/// listening round sends FWD and then STOP.
/// The longest command ("five seconds forward", "backward left") plus a
/// spare word.
const int maxCommandWords = 5;

class VoiceCommandPicker {
  VoiceCommandPicker(
    this.onCommand, {
    this.settle = const Duration(milliseconds: 800),
    this.instantDrive = false,
    this.upgradeWithin = const Duration(seconds: 2),
  });

  final void Function(String command) onCommand;
  final Duration settle;
  final bool instantDrive;
  final Duration upgradeWithin;
  Timer? _timer;
  // instantDrive: the FWD / BACK just sent, which more words may still
  // turn into a longer command, and where its words begin.
  String? _upgradable;
  int _upgradeFrom = 0;
  Timer? _upgradeTimer;
  String? _waiting;
  List<String> _waitingWords = const []; // words used by the waiting command
  List<String> _used = const []; // words of this round that gave a command
  String? _lastSent; // last command sent in this round

  /// Call when a new listening round starts. A FWD / BACK still waiting
  /// from the last round is sent first, so it is never lost.
  void newRound() {
    flush();
    _timer?.cancel();
    _timer = null;
    _waiting = null;
    _waitingWords = const [];
    _used = const [];
    _lastSent = null;
    _endUpgrade();
  }

  void _endUpgrade() {
    _upgradeTimer?.cancel();
    _upgradeTimer = null;
    _upgradable = null;
  }

  static bool _isUpgrade(String from, String to) => from == 'FWD'
      ? const ['FWD_LEFT', 'FWD_RIGHT', 'FWD5'].contains(to)
      : from == 'BACK' &&
          const ['BACK_LEFT', 'BACK_RIGHT', 'BACK5'].contains(to);

  static bool _startsWith(List<String> words, List<String> prefix) {
    if (prefix.length > words.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (words[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Returns the command it understood (sent or waiting), or null.
  String? hear(
    String words, {
    required bool isFinal,
    List<String> alternates = const [],
  }) {
    final best = normalizeHeardWords(words);
    // The mic stays open after a command, so more words come in the same
    // round. If the text still begins with the words that gave the last
    // command, only the words after them are read. Otherwise the phone
    // started a new phrase (or reworded the old one): read all of it, but
    // never send the same command twice for one phrase.
    final continues = _startsWith(best, _used);
    // The phone sometimes re-writes earlier words of a long round
    // ("forward stop" -> "ford stop backward"). If the text got LONGER,
    // the new words are still at the end: read only those. Reading all of
    // it again made an old "stop" win over every new command, so after a
    // few commands the mic seemed deaf until the round ended.
    final from = continues || best.length > _used.length ? _used.length : 0;
    String fresh(String text) {
      final w = normalizeHeardWords(text);
      final rest = w.skip(from > w.length ? w.length : from).toList();
      // A command is at most 4 words. Only the latest few words count, so
      // old chatter in a long round can't mix with a new command.
      return rest
          .skip(
            rest.length > maxCommandWords ? rest.length - maxCommandWords : 0,
          )
          .join(' ');
    }

    var command = pickCommand([fresh(words), ...alternates.map(fresh)]);
    if (!continues && command != null && command == _lastSent) {
      _used = best; // the old phrase reworded: nothing new
      command = null;
    }
    // instantDrive: "forward" was already sent and the sentence goes on
    // ("forward" -> "forward left"): read it again from where "forward"
    // began, and send the longer command if that is what it became.
    final up = _upgradable;
    if (command == null && up != null && continues) {
      String again(String text) {
        final w = normalizeHeardWords(text);
        return w
            .skip(_upgradeFrom > w.length ? w.length : _upgradeFrom)
            .join(' ');
      }

      final longer = pickCommand([again(words), ...alternates.map(again)]);
      if (longer != null && _isUpgrade(up, longer)) {
        _send(longer, best);
        return longer;
      }
    }
    if (command == null) {
      if (isFinal) flush();
      return null;
    }
    if ((command == 'FWD' || command == 'BACK') && instantDrive) {
      _send(command, best);
      _upgradable = command;
      _upgradeFrom = from;
      _upgradeTimer = Timer(upgradeWithin, _endUpgrade);
      return command;
    }
    if ((command == 'FWD' || command == 'BACK') && !isFinal) {
      _waiting = command;
      _waitingWords = best;
      _timer?.cancel();
      _timer = Timer(settle, flush);
      return command;
    }
    _send(command, best);
    return command;
  }

  /// Sends a FWD / BACK that is still waiting (used after the pause, at the
  /// end of a sentence, and when you let go of the mic in push-to-talk).
  void flush() {
    final w = _waiting;
    if (w != null) _send(w, _waitingWords);
  }

  void _send(String command, List<String> words) {
    _endUpgrade();
    _timer?.cancel();
    _timer = null;
    _waiting = null;
    _used = words;
    _lastSent = command;
    onCommand(command);
  }

  void dispose() {
    _timer?.cancel();
    _upgradeTimer?.cancel();
  }
}

/// Decides how soon the mic listens again after a listening round ends,
/// and when the phone's speech service is stuck and must be rebuilt.
///
/// In hands-free mode Android ends a round every few seconds when nobody
/// speaks, with "error_speech_timeout" or "error_no_match". That is
/// NORMAL and must not count as a failure. (The older app counted it: after
/// a few quiet minutes it waited up to 2.4 s between rounds and rebuilt the
/// speech service every ~5 rounds, about 1 s deaf each time. That was the
/// "slow / not hearing after a while" bug.)
class MicRestartPolicy {
  /// A quiet round shorter than this is not normal: the service failed
  /// at once, so it counts as a failure.
  static const Duration quickFail = Duration(milliseconds: 1500);

  /// Wait before the next round when everything is fine. Not lower: some
  /// phones answer "error_busy" if a new round starts too soon.
  static const int normalWaitMs = 250;
  static const int rebuildAfter = 5; // failures in a row

  int failures = 0;
  DateTime? _roundStartedAt;

  void roundStarted(DateTime now) => _roundStartedAt = now;

  /// Words came in: the service works.
  void heard() => failures = 0;

  void rebuilt() {
    failures = 0;
    _roundStartedAt = null;
  }

  static const quietEnds = ['error_no_match', 'error_speech_timeout'];

  /// Call for every error. Returns true when the error is a real failure.
  bool error(String msg, DateTime now) {
    final started = _roundStartedAt;
    final quick = started == null || now.difference(started) < quickFail;
    final real = !quietEnds.contains(msg) || quick;
    if (real) failures++;
    return real;
  }

  bool get needsRebuild => failures >= rebuildAfter;

  /// Milliseconds to wait before the next round.
  int waitMs() => failures == 0
      ? normalWaitMs
      : 300 * (1 << (failures > 4 ? 3 : failures - 1)); // 0.3 .. 2.4 s
}

enum ControlMode { voice, controller }

class CarPage extends StatefulWidget {
  const CarPage({super.key});

  @override
  State<CarPage> createState() => _CarPageState();
}

class _CarPageState extends State<CarPage> with WidgetsBindingObserver {
  final SpeechToText _speech = SpeechToText();

  // ---- UDP connection to the ESP32 ----
  RawDatagramSocket? _udp;
  Timer? _heartbeat;
  DateTime _lastReplyAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSocketReset = DateTime.now();
  bool _connected = false;

  // ---- Voice command sending (with retry) ----
  // Start from a different number each time the app opens, so the ESP32
  // never mistakes a new command for a repeat of an old one.
  int _seq = DateTime.now().millisecondsSinceEpoch % 100000;
  int? _pendingSeq;
  String? _pendingCommand;
  Stopwatch _sendWatch = Stopwatch();
  Timer? _retryTimer;
  int _retries = 0;

  // ---- Mode and car state ----
  ControlMode _mode = ControlMode.voice;
  String _carState = 'STOP FAST STRAIGHT OFF 0';

  // ---- Controller buttons ----
  bool _holdForward = false;
  bool _holdBackward = false;
  bool _holdLeft = false;
  bool _holdRight = false;
  int _manualSpeed = 0; // controller: Slow (0) or Fast (1)

  // ---- Speech ----
  bool _speechReady = false;
  bool _handsFree = false; // tap the mic: keeps listening
  bool _pushToTalk = false; // hold the mic: listens while held
  bool _onDevice = useOfflineSpeech;
  int _engineSwitches = 0;
  String? _localeId = preferredSpeechLocale;
  String _localeInfo = '';
  String _heard = ''; // live words, so you can see what the phone hears
  double _micLevel = 0; // 0..1
  DateTime _lastCommandAt = DateTime.fromMillisecondsSinceEpoch(0);
  late final VoiceCommandPicker _picker = VoiceCommandPicker(
    _onVoiceCommand,
    instantDrive: sendDriveAtOnce,
    settle: driveSettle,
  );
  bool _restartScheduled = false;
  // Mic health: if the phone's speech service stops sending anything
  // (no sound level, no words, no status) the app restarts it by itself.
  int _silentTicks = 0; // watchdog seconds with no sound or words
  Timer? _micWatchdog;
  final MicRestartPolicy _micPolicy = MicRestartPolicy();
  DateTime _lastCancelAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _stalledTicks = 0; // watchdog seconds with hands-free on but no round
  bool _resetting = false;
  String _status = 'Starting...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startHeartbeat();
    _setupSpeech();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _handsFree = false;
    _speech.cancel();
    _micWatchdog?.cancel();
    _picker.dispose();
    _heartbeat?.cancel(); // no heartbeat = the car's failsafe stops it
    _retryTimer?.cancel();
    _udp?.close();
    super.dispose();
  }

  /// SAFETY: when the app goes to the background (home button, phone call,
  /// screen off) the car stops and the heartbeat stops, so the ESP32
  /// failsafe also kicks in.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startHeartbeat();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _stopEverything();
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  void _setStatus(String text) {
    if (mounted) setState(() => _status = text);
  }

  // ===================== UDP =====================

  Future<RawDatagramSocket> _socket() async {
    if (_udp != null) return _udp!;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _onReply(utf8.decode(datagram.data, allowMalformed: true).trim());
    });
    _udp = socket;
    return socket;
  }

  /// Drops the socket so the next send makes a new one. Needed when the
  /// phone joined the ESP32 Wi-Fi after the old socket was created.
  void _resetSocket() {
    _udp?.close();
    _udp = null;
    _lastSocketReset = DateTime.now();
  }

  Future<void> _sendRaw(String text) async {
    try {
      final socket = await _socket();
      socket.send(utf8.encode(text), InternetAddress(esp32Ip), esp32UdpPort);
    } catch (_) {
      _resetSocket();
    }
  }

  void _onReply(String reply) {
    _lastReplyAt = DateTime.now();
    if (!_connected) {
      _connected = true;
      if (_pendingCommand == null) _setStatus(_readyText());
    }

    if (reply.startsWith('ST ')) {
      _updateCarState(reply.substring(3));
      return;
    }

    // "OK 17 FWD5 FWD FAST STRAIGHT ON 5"
    // "BLOCKED 18 FWD STOP FAST STRAIGHT OFF 0" = engine is off
    final blocked = reply.startsWith('BLOCKED ');
    if (reply.startsWith('OK ') || blocked) {
      final parts = reply.split(' ');
      if (parts.length < 6) return;
      final seq = int.tryParse(parts[1]);
      final command = parts[2];
      _updateCarState(parts.sublist(3).join(' '));
      if (seq != null && seq == _pendingSeq) {
        _sendWatch.stop();
        _retryTimer?.cancel();
        _pendingSeq = null;
        _pendingCommand = null;
        _setStatus(
          blocked
              ? 'The engine is off. Say "start" first.'
              : '${_commandName(command)}  (${_sendWatch.elapsedMilliseconds} ms)',
        );
      }
    }
  }

  void _updateCarState(String state) {
    if (state != _carState && mounted) setState(() => _carState = state);
  }

  /// Runs every 150 ms. In voice mode it sends "HB" (I'm still here).
  /// In controller mode it sends the buttons' state, which also counts
  /// as the heartbeat.
  void _startHeartbeat() {
    if (_heartbeat != null) return;
    _heartbeat = Timer.periodic(heartbeatEvery, (_) {
      if (_mode == ControlMode.controller) {
        _sendControllerState();
      } else {
        _sendRaw('HB');
      }
      _checkConnection();
    });
  }

  void _checkConnection() {
    final now = DateTime.now();
    final silentFor = now.difference(_lastReplyAt);
    if (_connected && silentFor > const Duration(seconds: 1)) {
      _connected = false;
      _setStatus(
        'Connection lost. The car stopped by itself.\n'
        'Is the phone on the Wi-Fi "$esp32WifiName"?',
      );
    }
    // Not connected: make a fresh socket every 2 s in case the phone
    // just joined the ESP32 Wi-Fi.
    if (!_connected &&
        now.difference(_lastSocketReset) > const Duration(seconds: 2)) {
      _resetSocket();
      if (_pendingCommand == null) {
        _setStatus(
          'Looking for the car...\n'
          'Connect this phone to the Wi-Fi "$esp32WifiName".',
        );
      }
    }
  }

  // ===================== Controller mode =====================

  /// "M F L 1" = forward, left, normal speed. Sent on every button change
  /// and every 150 ms while the controller is shown.
  void _sendControllerState() {
    final dir = _holdForward && !_holdBackward
        ? 'F'
        : _holdBackward && !_holdForward
            ? 'B'
            : 'S';
    final steer = _holdLeft && !_holdRight
        ? 'L'
        : _holdRight && !_holdLeft
            ? 'R'
            : 'C';
    _sendRaw('M $dir $steer $_manualSpeed');
  }

  void _setHold({bool? forward, bool? backward, bool? left, bool? right}) {
    setState(() {
      _holdForward = forward ?? _holdForward;
      _holdBackward = backward ?? _holdBackward;
      _holdLeft = left ?? _holdLeft;
      _holdRight = right ?? _holdRight;
    });
    _sendControllerState(); // send right away, don't wait for the timer
  }

  // ===================== Voice commands =====================

  /// Sends a voice command. It goes out twice straight away (a Wi-Fi
  /// packet is sometimes lost, and a second copy is quicker than waiting
  /// to notice that). If the ESP32 still doesn't answer within 80 ms we
  /// send again (up to 5 times). The sequence number stops the car from
  /// running the same command twice.
  void _sendVoiceCommand(String command) {
    _lastCommandAt = DateTime.now();
    _seq++;
    final seq = _seq;
    _pendingSeq = seq;
    _pendingCommand = command;
    _retries = 0;
    _sendWatch = Stopwatch()..start();
    _setStatus('Sending: ${_commandName(command)}...');
    final message = 'V $seq $command';
    _sendRaw(message);
    _sendRaw(message);

    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(milliseconds: 80), (timer) {
      if (_pendingSeq != seq) {
        timer.cancel();
        return;
      }
      if (_retries >= 5) {
        timer.cancel();
        _pendingSeq = null;
        _pendingCommand = null;
        _setStatus(
          'The car did not answer.\n'
          'Is the phone on the Wi-Fi "$esp32WifiName"?',
        );
        return;
      }
      _retries++;
      _sendRaw(message);
    });
  }

  String _commandName(String command) {
    const names = {
      'START': 'Engine on',
      'OFF': 'Engine off',
      'STOP': 'Stop',
      'FWD': 'Forward (short)',
      'BACK': 'Backward (short)',
      'FWD5': 'Forward 5 seconds',
      'BACK5': 'Backward 5 seconds',
      'FWD_LEFT': 'Forward left',
      'FWD_RIGHT': 'Forward right',
      'BACK_LEFT': 'Backward left',
      'BACK_RIGHT': 'Backward right',
      'DRIFT_LEFT': 'Drift left (nose to the left)',
      'DRIFT_RIGHT': 'Drift right (nose to the right)',
    };
    return names[command] ?? command;
  }

  // ===================== Speech =====================

  Future<void> _setupSpeech() async {
    // initialize() also asks for the microphone permission.
    _speechReady = await _tryInit(null);
    // Some phones (many sold in China) have no default speech service set.
    // Then ask Android for any installed speech service instead.
    if (!_speechReady) {
      _speechReady = await _tryInit([SpeechToText.androidIntentLookup]);
    }
    if (!_speechReady) {
      _setStatus(
        'No speech recognition service on this phone.\n'
        'Install "Speech Recognition & Synthesis from Google" (see guide).',
      );
      return;
    }
    await _pickLocale();
  }

  Future<bool> _tryInit(List<SpeechConfigOption>? options) async {
    try {
      return await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
        options: options,
      );
    } catch (_) {
      return false;
    }
  }

  /// Uses English (US) if the phone has it, else any English, else the
  /// phone's own language (with a warning).
  Future<void> _pickLocale() async {
    try {
      final locales = await _speech.locales();
      String norm(String id) => id.replaceAll('-', '_').toLowerCase();
      final ids = locales.map((l) => l.localeId).toList();
      String? pick = ids.cast<String?>().firstWhere(
            (id) => norm(id!) == norm(preferredSpeechLocale),
            orElse: () => null,
          );
      pick ??= ids.cast<String?>().firstWhere(
            (id) => norm(id!).startsWith('en'),
            orElse: () => null,
          );
      if (pick == null && ids.isNotEmpty) {
        final system = await _speech.systemLocale();
        _localeId = system?.localeId;
        _localeInfo = 'No English on this phone\'s speech service!';
      } else {
        _localeId = pick ?? preferredSpeechLocale;
        _localeInfo = '';
      }
    } catch (_) {
      _localeId = preferredSpeechLocale;
    }
    if (mounted) setState(() {});
  }

  String _speechInfo() {
    final engine = _onDevice ? 'offline' : 'online';
    final lang = _localeId ?? 'phone default';
    return _localeInfo.isNotEmpty
        ? '$_localeInfo ($lang)'
        : 'Speech: $lang · $engine';
  }

  String _readyText() => _mode == ControlMode.voice
      ? 'Connected to the car.\nTap the mic, or hold it while you speak.'
      : 'Connected to the car.\nTap the power button to start the engine, then hold the arrows.';

  Future<bool> _speechCanStart() async {
    if (!_speechReady) {
      await _setupSpeech();
      if (!_speechReady) return false;
    }
    if (!_connected) {
      _setStatus(
        'Not connected to the car yet.\n'
        'Connect this phone to the Wi-Fi "$esp32WifiName".',
      );
      return false;
    }
    return true;
  }

  /// Tap: hands-free on/off (keeps listening, round after round).
  Future<void> _onMicTap() async {
    if (_handsFree) {
      await _stopListening();
      _setStatus('Mic off. Tap the mic to start again.');
      return;
    }
    if (!await _speechCanStart()) return;
    setState(() => _handsFree = true);
    _micPolicy.rebuilt();
    _startWatchdog();
    await _startListening();
  }

  /// Hold: push-to-talk. Best in noise: the phone only listens while you
  /// hold, and decides the moment you let go.
  Future<void> _onMicHoldStart() async {
    if (_handsFree) await _stopListening();
    if (!await _speechCanStart()) return;
    setState(() => _pushToTalk = true);
    await _startListening();
  }

  Future<void> _onMicHoldEnd() async {
    if (!_pushToTalk) return;
    setState(() => _pushToTalk = false);
    await _speech.stop(); // gives the final result now
    // If the phone sends no final result, a waiting "forward" still goes.
    Future.delayed(const Duration(milliseconds: 800), _picker.flush);
  }

  Future<void> _cancelSpeech() {
    _lastCancelAt = DateTime.now();
    return _speech.cancel();
  }

  Future<void> _stopListening() async {
    _micWatchdog?.cancel();
    _micWatchdog = null;
    _handsFree = false;
    _pushToTalk = false;
    _heard = '';
    _micLevel = 0;
    await _cancelSpeech();
    if (mounted) setState(() {});
  }

  Future<void> _startListening() async {
    final wanted = _handsFree || _pushToTalk;
    if (!wanted || _mode != ControlMode.voice) return;
    // The previous round may still be closing: end it first, so a new
    // round (or a quick second hold of the mic) always starts listening.
    if (_speech.isListening) await _cancelSpeech();
    _picker.newRound();
    _micPolicy.roundStarted(DateTime.now());
    _silentTicks = 0;
    // Keep showing the last command for a moment instead of "Listening".
    final recent =
        DateTime.now().difference(_lastCommandAt) < const Duration(seconds: 3);
    if (_pendingCommand == null && !recent) {
      _setStatus(
        _pushToTalk ? 'Listening... let go when done.' : 'Listening...',
      );
    }
    try {
      await _speech.listen(
        onResult: _onSpeechResult,
        onSoundLevelChange: _onSoundLevel,
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          partialResults: true, // get words WHILE you are still speaking
          cancelOnError: false,
          onDevice: _onDevice,
          // "search" is tuned for short phrases, better for commands.
          listenMode: ListenMode.search,
          listenFor: const Duration(seconds: 30),
          // Hold-to-talk: don't end just because you paused.
          pauseFor: Duration(seconds: _pushToTalk ? 10 : 3),
        ),
      );
    } catch (_) {
      _restartSoon();
    }
  }

  /// Keeps hands-free mode going: when Android ends a listening round
  /// (silence, timeout or after a command) a new round starts.
  void _restartSoon() {
    if (!_handsFree || _restartScheduled || _resetting) return;
    _restartScheduled = true;
    // A normal end of a round (also a quiet one) restarts in 0.25 s. Only
    // real failures in a row wait longer (0.3, 0.6, 1.2, 2.4 s), so a busy
    // speech service gets time to recover instead of being hammered.
    final wait = _micPolicy.waitMs();
    Future.delayed(Duration(milliseconds: wait), () async {
      _restartScheduled = false;
      if (mounted && !_resetting) await _startListening();
    });
  }

  /// Checks every second that the mic is alive while hands-free is on.
  void _startWatchdog() {
    _micWatchdog?.cancel();
    _silentTicks = 0;
    _micWatchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_handsFree || _resetting || _restartScheduled) {
        _stalledTicks = 0;
        return;
      }
      if (!_speech.isListening) {
        // Between rounds: not deaf, but make sure a new round really
        // starts (a lost "done" status must not leave the mic off).
        _silentTicks = 0;
        if (++_stalledTicks >= 3) {
          _stalledTicks = 0;
          _startListening();
        }
        return;
      }
      _stalledTicks = 0;
      // Says "listening" but sends no sound and no words: deaf.
      _silentTicks++;
      if (_silentTicks > 4) _resetMic(auto: true);
    });
  }

  /// Fully restarts the phone's speech recogniser. Used by the watchdog,
  /// after many errors in a row, and by the "Reset mic" button.
  Future<void> _resetMic({required bool auto}) async {
    if (_resetting) return;
    _resetting = true;
    if (mounted) {
      setState(() {
        _micLevel = 0;
        _heard = '';
      });
    }
    _setStatus(
      auto
          ? 'The mic stopped responding. Restarting it...'
          : 'Restarting the mic...',
    );
    _picker.newRound();
    try {
      await _cancelSpeech();
      await Future.delayed(const Duration(milliseconds: 400));
      // Android only builds a NEW recogniser when the engine setting
      // changes, so start and cancel once with the other setting. The next
      // normal listen then gets a brand-new recogniser.
      await _speech.listen(
        onResult: (_) {},
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          onDevice: !_onDevice,
          partialResults: false,
          cancelOnError: false,
          listenMode: ListenMode.search,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 150));
      await _cancelSpeech();
    } catch (_) {
      // nothing to do, the normal listen below tries again
    }
    await Future.delayed(const Duration(milliseconds: 400));
    _resetting = false;
    _micPolicy.rebuilt();
    _restartScheduled = false;
    _silentTicks = 0;
    if (!mounted) return;
    if (_handsFree) {
      if (_micWatchdog == null) _startWatchdog();
      await _startListening();
    } else {
      _setStatus('Mic restarted. Tap or hold the mic.');
    }
  }

  void _onSoundLevel(double level) {
    // Android reports about -2 (quiet) to 10 (loud).
    if (_resetting) return;
    _silentTicks = 0;
    final v = ((level + 2) / 12).clamp(0.0, 1.0);
    if (mounted && (v - _micLevel).abs() > 0.05) {
      setState(() => _micLevel = v);
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (_resetting) return;
    _silentTicks = 0;
    _micPolicy.heard();
    if (mounted) setState(() => _heard = result.recognizedWords);
    // Check EVERY partial result and all of the engine's guesses, so most
    // commands are sent as soon as the words are recognised.
    final command = _picker.hear(
      result.recognizedWords,
      isFinal: result.finalResult,
      alternates:
          result.alternates.skip(1).map((a) => a.recognizedWords).toList(),
    );
    if (command == null &&
        result.finalResult &&
        result.recognizedWords.isNotEmpty) {
      _setStatus(
        'Heard: "${result.recognizedWords}"\n'
        'Not a command. Try again, a bit slower.',
      );
    }
  }

  void _onVoiceCommand(String command) {
    // Only send. The mic is NOT stopped here: stopping it in the middle of
    // a sentence and starting it again right away made some phones'
    // speech service go deaf. It keeps listening, so "stop" right after
    // "forward" still works, and the round ends by itself after a pause.
    _sendVoiceCommand(command);
  }

  void _onSpeechStatus(String status) {
    // A status alone does NOT count as "the mic is alive": a deaf
    // recogniser still says "listening". Only sound levels and words do.
    if (_resetting) return;
    if (status == 'done' || status == 'notListening') {
      if (mounted) setState(() => _micLevel = 0);
      _restartSoon();
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    if (_resetting) return;
    final msg = error.errorMsg;
    final now = DateTime.now();
    // "error_client" right after the app itself cancelled a round is just
    // the echo of that cancel, not a problem.
    if (msg == 'error_client' &&
        now.difference(_lastCancelAt) < const Duration(milliseconds: 500)) {
      return;
    }
    _micPolicy.error(msg, now);
    // Normal in hands-free mode: nobody spoke, or nothing matched.
    const harmless = [
      'error_no_match',
      'error_speech_timeout',
      'error_busy',
      'error_client',
    ];
    const noOffline = [
      'error_language_unavailable',
      'error_language_not_supported',
    ];
    const noOnline = [
      'error_network',
      'error_network_timeout',
      'error_server',
      'error_server_disconnected',
      'error_too_many_requests',
    ];

    if (msg == 'error_permission' || msg == 'error_audio_error') {
      _stopListening();
      _setStatus(
        'The app can\'t use the microphone.\n'
        'Allow "Microphone" for this app in the phone settings.',
      );
      return;
    }
    // Switch between offline and online by itself (at most twice, so it
    // can't flip forever).
    if (_engineSwitches < 2 &&
        ((_onDevice && noOffline.contains(msg)) ||
            (!_onDevice && noOnline.contains(msg)))) {
      _engineSwitches++;
      _onDevice = !_onDevice;
      _setStatus(
        _onDevice
            ? 'Online speech failed. Switched to offline.'
            : 'Offline English isn\'t installed. Switched to online speech.',
      );
    } else if (!harmless.contains(msg)) {
      _setStatus(
        'Speech problem: $msg\nSee "Voice not recognised" in the guide.',
      );
    }
    // Many errors in a row: the recogniser is stuck, rebuild it.
    if (_handsFree && _micPolicy.needsRebuild) {
      _resetMic(auto: true);
      return;
    }
    if (_handsFree) _restartSoon();
  }

  // ===================== Stop / mode switch =====================

  /// Stops the car and the mic, and releases all controller buttons.
  /// Used when switching mode and when the app goes to the background.
  void _stopEverything() {
    _holdForward = _holdBackward = _holdLeft = _holdRight = false;
    if (_handsFree || _pushToTalk) _stopListening();
    if (_mode == ControlMode.controller) {
      _sendRaw('M S C $_manualSpeed');
    } else {
      _sendVoiceCommand('STOP');
    }
  }

  void _switchMode(ControlMode mode) {
    if (mode == _mode) return;
    _stopEverything(); // the car always stops when you switch
    _setOrientation(mode);
    setState(() {
      _mode = mode;
      _status = _connected ? _readyText() : _status;
    });
  }

  /// Controller = landscape (like a game controller), voice = portrait.
  void _setOrientation(ControlMode mode) {
    SystemChrome.setPreferredOrientations(
      mode == ControlMode.controller
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
  }

  // ===================== UI =====================

  bool get _engineOn =>
      _carState.split(' ').length > 3 && _carState.split(' ')[3] == 'ON';

  /// "FWD FAST LEFT ON 3" -> "Forward · Left · 3 s"
  String _prettyState() {
    final parts = _carState.split(' ');
    if (parts.length < 5) return _carState;
    if (parts[3] != 'ON') return 'Engine off';
    const names = {
      'FWD': 'Forward',
      'BACK': 'Backward',
      'STOP': 'Engine on · Stopped',
      'LEFT': 'Left',
      'RIGHT': 'Right',
    };
    final text = [names[parts[0]] ?? parts[0]];
    if (parts[0] != 'STOP') {
      if (_mode == ControlMode.controller) {
        text.add(parts[1] == 'SLOW' ? 'Slow' : 'Fast');
      }
      if (parts[2] != 'STRAIGHT') text.add(names[parts[2]] ?? parts[2]);
      if (parts[4] != '0') text.add('${parts[4]} s');
    }
    return text.join(' · ');
  }

  void _onEngineTap() {
    if (!_connected) {
      _setStatus(
        'Not connected to the car yet.\n'
        'Connect this phone to the Wi-Fi "$esp32WifiName".',
      );
      return;
    }
    _holdForward = _holdBackward = _holdLeft = _holdRight = false;
    _sendVoiceCommand(_engineOn ? 'OFF' : 'START');
  }

  // ---- Pieces shared by both layouts ----

  Widget _topBar() {
    return Row(
      children: [
        Icon(
          Icons.circle,
          size: 14,
          color: _connected ? Colors.green : Colors.redAccent,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _connected ? _prettyState() : 'Not connected',
            key: const Key('car_state'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        // Engine on/off. You can also say "start" or "turn off".
        IconButton(
          key: const Key('engine_button'),
          tooltip: _engineOn ? 'Engine off' : 'Start engine',
          onPressed: _onEngineTap,
          icon: Icon(
            Icons.power_settings_new,
            color: _engineOn ? Colors.green : Colors.grey,
          ),
        ),
        const SizedBox(width: 4),
        SegmentedButton<ControlMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ControlMode.voice, icon: Icon(Icons.mic)),
            ButtonSegment(
              value: ControlMode.controller,
              icon: Icon(Icons.gamepad),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => _switchMode(s.first),
        ),
      ],
    );
  }

  Widget _statusText() {
    return Text(
      _status,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.grey, fontSize: 14),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: OrientationBuilder(
            builder: (context, orientation) {
              // For a moment while the phone rotates, the screen still has
              // the old shape. Show nothing then, instead of a squashed layout.
              final landscape = orientation == Orientation.landscape;
              if (_mode == ControlMode.voice && !landscape) {
                return _buildVoiceLayout();
              }
              if (_mode == ControlMode.controller && landscape) {
                return _buildControllerLayout();
              }
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
  }

  // ---- Voice mode: portrait, the simple mic screen ----
  Widget _buildVoiceLayout() {
    return Column(
      children: [
        _topBar(),
        Expanded(
          child: Center(
            // Scrolls on very small screens instead of overflowing.
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Tap = keep listening. Hold = listen only while held.
                  GestureDetector(
                    key: const Key('mic_button'),
                    onTap: _onMicTap,
                    onLongPressStart: (_) => _onMicHoldStart(),
                    onLongPressEnd: (_) => _onMicHoldEnd(),
                    onLongPressCancel: _onMicHoldEnd,
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (_handsFree || _pushToTalk)
                            ? Colors.red.shade50
                            : Colors.blue.shade50,
                      ),
                      child: Icon(
                        (_handsFree || _pushToTalk)
                            ? Icons.mic
                            : Icons.mic_none,
                        size: 100,
                        color: (_handsFree || _pushToTalk)
                            ? Colors.red
                            : Colors.blue,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Mic level: if this doesn't move when you talk, the phone
                  // isn't hearing you.
                  SizedBox(
                    width: 160,
                    child: LinearProgressIndicator(
                      key: const Key('mic_level'),
                      value: _micLevel,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _heard.isEmpty
                        ? 'Tap = keep listening · Hold = push to talk'
                        : '"$_heard"',
                    key: const Key('heard_text'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _heard.isEmpty ? Colors.grey : Colors.black87,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Start · Turn off · Stop\n'
                    'Forward · Backward · 5 seconds forward/backward\n'
                    'Forward left/right · Backward left/right\n'
                    'Drift left · Drift right',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _speechInfo(),
                    key: const Key('speech_info'),
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  TextButton.icon(
                    key: const Key('reset_mic'),
                    onPressed: _resetting ? null : () => _resetMic(auto: false),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Reset mic'),
                  ),
                ],
              ),
            ),
          ),
        ),
        _statusText(),
        const SizedBox(height: 16),
      ],
    );
  }

  // ---- Controller mode: landscape, simple gamepad ----
  //   car state                                   [mic|gamepad]
  //   [ ▲ ]                                         [ ◀ ][ ▶ ]
  //   [ ▼ ]           [ Slow | Fast ]
  // No STOP button: letting go of ▲ / ▼ stops the car.
  Widget _buildControllerLayout() {
    return Column(
      children: [
        _topBar(), // state in the top-left corner, mode switch top-right
        Expanded(
          child: Row(
            children: [
              // Left thumb: forward / backward
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  HoldButton(
                    key: const Key('btn_forward'),
                    enabled: _engineOn,
                    icon: Icons.arrow_upward,
                    pressed: _holdForward,
                    onChanged: (v) => _setHold(forward: v),
                  ),
                  const SizedBox(height: 16),
                  HoldButton(
                    key: const Key('btn_backward'),
                    enabled: _engineOn,
                    icon: Icons.arrow_downward,
                    pressed: _holdBackward,
                    onChanged: (v) => _setHold(backward: v),
                  ),
                ],
              ),
              // Middle: the Slow / Fast switch (and a hint while the
              // engine is off)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_connected && !_engineOn)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Engine off. Tap the power button to start.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    SizedBox(
                      height: 56,
                      child: SegmentedButton<int>(
                        key: const Key('speed_switch'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('Slow', style: TextStyle(fontSize: 20)),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Fast', style: TextStyle(fontSize: 20)),
                          ),
                        ],
                        selected: {_manualSpeed},
                        onSelectionChanged: (s) {
                          setState(() => _manualSpeed = s.first);
                          _sendControllerState();
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // Right thumb: left / right
              Row(
                children: [
                  HoldButton(
                    key: const Key('btn_left'),
                    enabled: _engineOn,
                    icon: Icons.arrow_back,
                    pressed: _holdLeft,
                    onChanged: (v) => _setHold(left: v),
                  ),
                  const SizedBox(width: 12),
                  HoldButton(
                    key: const Key('btn_right'),
                    enabled: _engineOn,
                    icon: Icons.arrow_forward,
                    pressed: _holdRight,
                    onChanged: (v) => _setHold(right: v),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A button that is "on" only while a finger is on it. Several buttons
/// can be held at the same time (for example forward + left). If two
/// fingers touch the same button, it stays on until both are lifted.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.icon,
    required this.pressed,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final bool pressed;
  final bool enabled; // grey while the engine is off
  final ValueChanged<bool> onChanged;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  final Set<int> _fingers = {};

  void _down(PointerEvent e) {
    _fingers.add(e.pointer);
    if (_fingers.length == 1) widget.onChanged(true);
  }

  void _up(PointerEvent e) {
    if (_fingers.remove(e.pointer) && _fingers.isEmpty) {
      widget.onChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: !widget.enabled
              ? Colors.grey.shade200
              : widget.pressed
                  ? Colors.blue
                  : Colors.blue.shade50,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(
          widget.icon,
          size: 48,
          color: !widget.enabled
              ? Colors.grey
              : widget.pressed
                  ? Colors.white
                  : Colors.blue,
        ),
      ),
    );
  }
}
