import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'IntelliBudget AI',
      debugShowCheckedModeBanner: false,
      home: BudgetWebView(),
    );
  }
}

class BudgetWebView extends StatefulWidget {
  const BudgetWebView({super.key});
  @override
  State<BudgetWebView> createState() => _BudgetWebViewState();
}

class _BudgetWebViewState extends State<BudgetWebView> {
  late final WebViewController _controller;
  final SpeechToText _speech = SpeechToText();
  bool _isLoading = true;
  bool _isDownloading = false;
  String _downloadMsg = '';

  static const String _baseUrl =
      'https://intellibudgetai-main-production.up.railway.app';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _isLoading = true),
        onPageFinished: (_) => setState(() => _isLoading = false),
        onWebResourceError: (_) => setState(() => _isLoading = false),
        onNavigationRequest: (NavigationRequest request) {
          final url = request.url;
          if (url.contains('/export')) {
            _downloadFile(url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..addJavaScriptChannel(
        'FlutterSpeech',
        onMessageReceived: (msg) async {
          if (msg.message == 'start') {
            await _startListening();
          } else if (msg.message == 'stop') {
            await _stopListening();
          }
        },
      )
      // Channel to receive download request WITH cookie from JS side
      ..addJavaScriptChannel(
        'FlutterDownload',
        onMessageReceived: (msg) {
          // msg.message = "pdf|cookieString" or "csv|cookieString"
          final parts = msg.message.split('|');
          if (parts.length >= 2) {
            final type = parts[0];
            final cookie = parts.sublist(1).join('|'); // cookie may contain |
            _downloadWithCookie(type, cookie);
          }
        },
      )
      ..loadRequest(Uri.parse(_baseUrl));

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  // ── Intercept /export navigation → trigger JS to grab cookie + call back ──
  Future<void> _downloadFile(String interceptedUrl) async {
    final isPdf = interceptedUrl.contains('pdf');
    final type = isPdf ? 'pdf' : 'csv';

    // Inject JS: read document.cookie and send back via FlutterDownload channel
    await _controller.runJavaScript('''
      (function() {
        var cookie = document.cookie || '';
        FlutterDownload.postMessage('$type|' + cookie);
      })();
    ''');
  }

  // ── Actual download using cookie passed from JS ────────────────────────────
  Future<void> _downloadWithCookie(String type, String cookie) async {
    final granted = await _requestPermissionIfNeeded();
    if (!granted) {
      _showMsg('❌ Storage permission denied');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadMsg = '⬇️ Preparing download...';
    });

    try {
      final isPdf = type == 'pdf';
      final ext = isPdf ? 'pdf' : 'csv';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'IntelliBudget_$ts.$ext';

      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/$fileName';

      // Get date params from current URL
      final currentUrl = await _controller.currentUrl() ?? _baseUrl;
      Map<String, String> dateParams = {};
      try {
        final uri = Uri.parse(currentUrl);
        final p = uri.queryParameters;
        if (p['from_date'] != null) dateParams['from_date'] = p['from_date']!;
        if (p['to_date'] != null) dateParams['to_date'] = p['to_date']!;
      } catch (_) {}

      final downloadUri = isPdf
          ? Uri.parse('$_baseUrl/export/pdf')
              .replace(queryParameters: dateParams.isEmpty ? null : dateParams)
          : Uri.parse('$_baseUrl/export');

      // Flask session is HttpOnly — document.cookie won't have it.
      // So we use JS fetch (which DOES send HttpOnly cookies automatically)
      // and receive the file bytes via base64 back to Flutter.
      setState(() => _downloadMsg = '⬇️ Downloading...');

      final b64Result = await _controller.runJavaScriptReturningResult('''
        (async function() {
          try {
            const url = '${downloadUri.toString()}';
            const resp = await fetch(url, {
              credentials: 'include',
              headers: { 'Accept': '${isPdf ? 'application/pdf' : 'text/csv'}' }
            });
            if (!resp.ok) return 'ERROR:' + resp.status;
            const ct = resp.headers.get('content-type') || '';
            if (ct.includes('text/html')) return 'ERROR:html';
            const buf = await resp.arrayBuffer();
            const bytes = new Uint8Array(buf);
            let binary = '';
            for (let i = 0; i < bytes.byteLength; i++) {
              binary += String.fromCharCode(bytes[i]);
            }
            return btoa(binary);
          } catch(e) {
            return 'ERROR:' + e.toString();
          }
        })()
      ''');

      final b64 = b64Result.toString().replaceAll('"', '').trim();

      if (b64.startsWith('ERROR:')) {
        final reason = b64.substring(6);
        if (reason == 'html' || reason == '401' || reason == '302') {
          _showMsg('❌ Session expired — please login again');
        } else {
          _showMsg('❌ Download failed: $reason');
        }
        setState(() => _isDownloading = false);
        return;
      }

      if (b64.isEmpty) {
        _showMsg('❌ Empty response from server');
        setState(() => _isDownloading = false);
        return;
      }

      // Decode base64 → bytes
      final bytes = _base64ToBytes(b64);

      // Verify PDF magic bytes
      if (isPdf && bytes.length > 4) {
        final magic = String.fromCharCodes(bytes.sublist(0, 5));
        if (!magic.startsWith('%PDF')) {
          _showMsg('❌ Invalid PDF received');
          setState(() => _isDownloading = false);
          return;
        }
      }

      // Write file
      await File(savePath).writeAsBytes(bytes, flush: true);

      setState(() {
        _isDownloading = false;
        _downloadMsg = '✅ Downloaded! Opening...';
      });

      final openResult = await OpenFilex.open(savePath);
      if (openResult.type == ResultType.noAppToOpen) {
        _showMsg('✅ Saved: $fileName\n(Install a PDF viewer to open)');
      } else {
        _showMsg('✅ Opened: $fileName');
      }

      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    } on DioException catch (e) {
      _showMsg('❌ Network error: ${e.type.name}');
    } catch (e) {
      _showMsg('❌ Error: ${e.toString().split('\n').first}');
    }
  }

  // ── Pure Dart base64 decode (no extra package) ────────────────────────────
  List<int> _base64ToBytes(String b64) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final clean = b64.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
    final bytes = <int>[];
    for (var i = 0; i < clean.length; i += 4) {
      final a = chars.indexOf(clean[i]);
      final b = chars.indexOf(clean[i + 1]);
      final c = i + 2 < clean.length ? chars.indexOf(clean[i + 2]) : 0;
      final d = i + 3 < clean.length ? chars.indexOf(clean[i + 3]) : 0;
      bytes.add((a << 2) | (b >> 4));
      if (c != -1 && clean[i + 2] != '=') bytes.add(((b & 0xF) << 4) | (c >> 2));
      if (d != -1 && i + 3 < clean.length && clean[i + 3] != '=') {
        bytes.add(((c & 0x3) << 6) | d);
      }
    }
    return bytes;
  }

  Future<bool> _requestPermissionIfNeeded() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await Process.run('getprop', ['ro.build.version.sdk']);
      final sdk = int.tryParse(result.stdout.toString().trim()) ?? 29;
      if (sdk <= 28) {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  void _showMsg(String msg) {
    setState(() {
      _isDownloading = false;
      _downloadMsg = msg;
    });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _downloadMsg = '');
    });
  }

  Future<void> _startListening() async {
    bool available = await _speech.initialize(
      onError: (error) {
        _controller
            .runJavaScript("window.onSpeechError('${error.errorMsg}')");
      },
    );
    if (available) {
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            final text = result.recognizedWords
                .replaceAll("'", "\\'")
                .replaceAll('"', '\\"');
            _controller.runJavaScript("window.onSpeechResult('$text')");
            _speech.stop();
          }
        },
        localeId: 'en_IN',
      );
    } else {
      _controller
          .runJavaScript("window.onSpeechError('Microphone not available')");
    }
  }

  Future<void> _stopListening() async {
    await _speech.stop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (await _controller.canGoBack()) {
          _controller.goBack();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_isLoading)
                const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('💰', style: TextStyle(fontSize: 48)),
                      SizedBox(height: 16),
                      CircularProgressIndicator(color: Color(0xFF6C63FF)),
                      SizedBox(height: 12),
                      Text('Loading IntelliBudget AI...'),
                    ],
                  ),
                ),
              if (_downloadMsg.isNotEmpty)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: _downloadMsg.contains('✅')
                        ? Colors.green
                        : _downloadMsg.contains('❌')
                            ? Colors.red
                            : const Color(0xFF6C63FF),
                    padding: const EdgeInsets.symmetric(
                        vertical: 12, horizontal: 16),
                    child: Row(
                      children: [
                        if (_isDownloading)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        if (_isDownloading) const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _downloadMsg,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
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
