import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

late _Handler handler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

// ---------- math to speech ----------
String mathToSpeech(String t) {
  final rules = <List<String>>[
    [r'\\frac\{([^{}]+)\}\{([^{}]+)\}', r'$1 over $2'],
    [r'\\sqrt\{([^{}]+)\}', r'square root of $1'],
    [r'\^2\b', ' squared'],
    [r'\^3\b', ' cubed'],
    [r'\^\{?(\w+)\}?', r' to the power of $1'],
    [r'_\{?(\w+)\}?', r' sub $1'],
    [r'\\times', ' times '], [r'\\div', ' divided by '],
    [r'\\pm', ' plus or minus '], [r'\\leq', ' less than or equal to '],
    [r'\\geq', ' greater than or equal to '], [r'\\neq', ' not equal to '],
    [r'\\infty', ' infinity '], [r'\\sum', ' sum of '],
    [r'\\int', ' integral of '], [r'\\partial', ' partial '],
    [r'\\alpha', ' alpha '], [r'\\beta', ' beta '], [r'\\pi', ' pi '],
    [r'\\theta', ' theta '], [r'\\sigma', ' sigma '], [r'\\lambda', ' lambda '],
    [r'[×*]', ' times '], [r'÷', ' divided by '], [r'±', ' plus or minus '],
    [r'≤', ' less than or equal to '], [r'≥', ' greater than or equal to '],
    [r'∞', ' infinity '], [r'√', ' square root of '], [r'π', ' pi '],
    [r'∑', ' sum of '], [r'∫', ' integral of '], [r'%', ' percent '],
  ];
  for (final r in rules) {
    t = t.replaceAllMapped(RegExp(r[0]), (m) {
      var out = r[1];
      for (var i = 1; i <= m.groupCount; i++) {
        out = out.replaceAll('\$$i', m.group(i) ?? '');
      }
      return out;
    });
  }
  t = t.replaceAll(RegExp(r'\\[a-zA-Z]+'), ' ');
  return t.replaceAll(RegExp(r'[{}]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<String> chunkText(String raw) {
  raw = raw.replaceAll(RegExp(r'\r\n|\r'), '\n');
  final paras = raw.split(RegExp(r'\n\s*\n'));
  final out = <String>[];
  for (var p in paras) {
    p = p.trim();
    if (p.isEmpty) continue;
    for (var s in p.split(RegExp(r'(?<=[.!?])\s+'))) {
      s = s.trim();
      if (s.isEmpty) continue;
      if (s.length <= 280) {
        out.add(s);
      } else {
        var buf = StringBuffer();
        for (var part in s.split(RegExp(r',\s+'))) {
          if (buf.length + part.length > 280 && buf.isNotEmpty) {
            out.add(buf.toString().trim());
            buf = StringBuffer();
          }
          buf.write('$part, ');
        }
        if (buf.toString().trim().isNotEmpty) out.add(buf.toString().trim());
      }
    }
  }
  return out;
}

Future<List<String>> extractChunks(File f) async {
  final doc = PdfDocument(inputBytes: await f.readAsBytes());
  final sb = StringBuffer();
  final ex = PdfTextExtractor(doc);
  for (var i = 0; i < doc.pages.count; i++) {
    sb.writeln(ex.extractText(startPageIndex: i, endPageIndex: i));
    sb.writeln('\n');
  }
  doc.dispose();
  return chunkText(sb.toString());
}

// ---------- TTS handler ----------
class _Handler extends BaseAudioHandler {
  final FlutterTts tts = FlutterTts();
  List<String> chunks = [];
  int idx = 0;
  double rate = 0.95;
  bool active = false;
  void Function(int newIndex)? onIndexChanged;

  Future<void> init() async {
    await tts.awaitSpeakCompletion(true);
    await tts.setSpeechRate(rate);
    final raw = await tts.getVoices;
    final voices = (raw as List).cast<Map>();
    final chosen = voices.firstWhere(
      (v) => '${v['locale']}'.contains('en-IN'),
      orElse: () => voices.firstWhere(
        (v) => '${v['locale']}'.startsWith('en'),
        orElse: () => <String, dynamic>{},
      ),
    );
    if (chosen.isNotEmpty) await tts.setVoice(Map<String, dynamic>.from(chosen as Map));
    tts.setCompletionHandler(() { if (active) { idx++; _speak(); } });
    tts.setErrorHandler((_) {
      active = false;
      playbackState.add(playbackState.value.copyWith(playing: false));
    });
  }

  Future<List<Map<String, dynamic>>> voices() async {
    final raw = await tts.getVoices;
    return (raw as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> setRate(double r) async { rate = r; await tts.setSpeechRate(r); }

  Future<void> setVoice(String name) async {
    final v = (await voices()).firstWhere((e) => e['name'] == name);
    await tts.setVoice(v);
  }

  @override
  Future<void> play() async {
    if (active) { await tts.resume(); } else { active = true; _speak(); }
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.ready, playing: true));
  }

  @override
  Future<void> pause() async {
    await tts.pause();
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> stop() async {
    active = false;
    await tts.stop();
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.idle, playing: false));
  }

  @override
  Future<void> skipToNext() async {
    if (idx < chunks.length - 1) { idx++; onIndexChanged?.call(idx); await tts.stop(); if (active) _speak(); }
  }

  @override
  Future<void> skipToPrevious() async {
    if (idx > 0) { idx--; onIndexChanged?.call(idx); await tts.stop(); if (active) _speak(); }
  }

  Future<void> _speak() async {
    if (idx >= chunks.length) {
      active = false;
      playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.completed, playing: false));
      return;
    }
    await tts.speak(mathToSpeech(chunks[idx]));
    onIndexChanged?.call(idx);
    mediaItem.add(MediaItem(
      id: 'c$idx', title: 'Part ${idx + 1}/${chunks.length}',
      artist: 'PDF Read Aloud'));
    playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.ready,
        playing: true, updatePosition: Duration.zero));
  }
}

// ---------- App ----------
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: const Home(),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  File? _pdfFile;
  final PdfViewerController _viewerCtrl = PdfViewerController();
  final GlobalKey<SfPdfViewerState> _viewerKey = GlobalKey();

  bool reading = false;
  bool paused = false;
  double rate = 0.95;
  String status = 'Pick a PDF first';
  String voiceLabel = 'Auto';
  List<Map<String, dynamic>> voices = [];
  List<String> _chunks = [];
  int _currentChunk = 0;
  String? _selectedText; // from user's text selection

  Future<void> _pick() async {
    final res = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (res == null) return;
    final f = File(res.files.single.path!);
    setState(() => status = 'Extracting…');
    final chunks = await extractChunks(f);
    setState(() {
      _pdfFile = f;
      _chunks = chunks;
      status = 'Ready: ${chunks.length} parts';
    });
  }

  Future<void> _start() async {
    if (_chunks.isEmpty) { setState(() => status = 'Pick a PDF first'); return; }
    if (!reading) {
      handler = await AudioService.init(
        builder: () => _Handler()..chunks = _chunks,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'pdf.read',
          androidNotificationChannelName: 'PDF Read Aloud',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        ),
      );
      await handler.init();
      handler.onIndexChanged = (i) {
        if (mounted) setState(() => _currentChunk = i);
        // Auto-scroll viewer to follow speech (best-effort)
        try { _viewerCtrl.jumpToPage(1); } catch (_) {}
      };
      reading = true;
      final v = await handler.voices();
      setState(() {
        voices = v;
        voiceLabel = v.firstWhere(
          (e) => '${e['locale']}'.contains('en-IN'),
          orElse: () => v.firstWhere(
            (e) => '${e['locale']}'.startsWith('en'),
            orElse: () => <String, dynamic>{},
          ),
        )['name'] ?? 'Default';
      });
    }
    await handler.play();
    setState(() { paused = false; status = 'Reading…'; });
  }

  /// Read ONLY the text the user selected on the page.
  Future<void> _readSelection() async {
    if (_selectedText == null || _selectedText!.trim().isEmpty) {
      setState(() => status = 'Select some text first (long-press on the page)');
      return;
    }
    if (!reading) {
      await _start();
    }
    // Insert selection as a one-off chunk and speak it
    handler.chunks = [_selectedText!];
    handler.idx = 0;
    await handler.stop();
    await handler.play();
    setState(() => status = 'Reading selection…');
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: const Text('PDF Read Aloud'),
      actions: [
        if (_pdfFile != null)
          IconButton(
            tooltip: 'Read selected text',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: _readSelection,
          ),
      ],
    ),
    body: Column(children: [
      // ---- toolbar ----
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          ElevatedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.upload_file),
            label: const Text('Pick PDF'),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(status, overflow: TextOverflow.ellipsis)),
        ]),
      ),

      // ---- PDF viewer (with text selection enabled) ----
      Expanded(
        child: _pdfFile == null
            ? const Center(child: Text('Pick a PDF to view and read'))
            : SfPdfViewer.file(
                _pdfFile!,
                key: _viewerKey,
                controller: _viewerCtrl,
                enableTextSelection: true,        // ← THIS is the fix
                onTextSelectionChanged: (details) {
                  if (details.selectedText != null &&
                      details.selectedText!.isNotEmpty) {
                    setState(() => _selectedText = details.selectedText);
                  }
                },
              ),
      ),

      // ---- reader controls (only after Read Aloud pressed) ----
      if (reading)
        Card(
          margin: const EdgeInsets.all(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              if (voices.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: voiceLabel,
                  items: voices.map((v) => DropdownMenuItem(
                    value: v['name'] as String,
                    child: Text('${v['name']} (${v['locale']})'),
                  )).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => voiceLabel = v);
                    handler.setVoice(v);
                  },
                ),
              Row(children: [
                const Text('Speed'),
                Expanded(child: Slider(
                  value: rate, min: 0.5, max: 1.5, divisions: 20,
                  label: rate.toStringAsFixed(2),
                  onChanged: (v) => setState(() => rate = v),
                  onChangeEnd: (v) => handler.setRate(v),
                )),
                Text(rate.toStringAsFixed(2)),
              ]),
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(iconSize: 36, icon: const Icon(Icons.skip_previous),
                    onPressed: () => handler.skipToPrevious()),
                IconButton(
                  iconSize: 48,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  onPressed: () async {
                    if (paused) { await handler.play(); }
                    else { await handler.pause(); }
                    setState(() => paused = !paused);
                  },
                ),
                IconButton(iconSize: 36, icon: const Icon(Icons.skip_next),
                    onPressed: () => handler.skipToNext()),
              ]),
              Text('Part ${_currentChunk + 1} / ${_chunks.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ),

      // ---- Read Aloud button ----
      Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
            ),
            onPressed: _start,
            icon: const Icon(Icons.record_voice_over),
            label: const Text('Read Aloud from start',
                style: TextStyle(fontSize: 16)),
          ),
        ),
      ),
    ]),
  );
}
