import 'dart:convert';
import 'dart:io';
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
            _triggerDownload(url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..addJavaScriptChannel(
        'FlutterSpeech',
        onMessageReceived: (msg) async {
          if (msg.message == 'start') await _startListening();
          if (msg.message == 'stop') await _stopListening();
        },
      )
      // Receives: "OK|<base64>" or "ERR|<reason>"
      ..addJavaScriptChannel(
        'FlutterDownload',
        onMessageReceived: (msg) => _handleDownloadMessage(msg.message),
      )
      ..loadRequest(Uri.parse(_baseUrl));

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  // Step 1: intercept export nav → inject JS fetch inside WebView
  Future<void> _triggerDownload(String interceptedUrl) async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadMsg = '⬇️ Fetching file...';
    });

    final isPdf = interceptedUrl.contains('pdf');
    final type = isPdf ? 'pdf' : 'csv';
    final accept = isPdf ? 'application/pdf' : 'text/csv';

    // Get date params from current page URL
    String exportUrl = isPdf ? '/export/pdf' : '/export';
    try {
      final currentUrl = await _controller.currentUrl() ?? '';
      final uri = Uri.parse(currentUrl);
      final p = uri.queryParameters;
      final params = <String>[];
      if (p['from_date'] != null) params.add('from_date=${p['from_date']}');
      if (p['to_date'] != null) params.add('to_date=${p['to_date']}');
      if (params.isNotEmpty) exportUrl += '?${params.join('&')}';
    } catch (_) {}

    // JS fetch with credentials → converts bytes to base64 → posts to Flutter
    // Uses Uint8Array → reduce approach to avoid btoa string size limits
    await _controller.runJavaScript('''
      (async function() {
        try {
          const resp = await fetch('$exportUrl', {
            credentials: 'include',
            headers: { 'Accept': '$accept' }
          });
          if (!resp.ok) {
            FlutterDownload.postMessage('ERR|status:' + resp.status);
            return;
          }
          const ct = resp.headers.get('content-type') || '';
          if (ct.includes('text/html')) {
            FlutterDownload.postMessage('ERR|html');
            return;
          }
          const buf = await resp.arrayBuffer();
          const bytes = new Uint8Array(buf);
          // Convert to base64 in chunks to avoid call stack overflow
          let binary = '';
          const chunkSize = 8192;
          for (let i = 0; i < bytes.length; i += chunkSize) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
          }
          const b64 = btoa(binary);
          FlutterDownload.postMessage('$type|' + b64);
        } catch(e) {
          FlutterDownload.postMessage('ERR|' + e.toString());
        }
      })();
    ''');
  }

  // Step 2: receive base64 from JS → decode → save → open
  Future<void> _handleDownloadMessage(String message) async {
    if (message.startsWith('ERR|')) {
      final reason = message.substring(4);
      if (reason.contains('html') || reason.contains('401') || reason.contains('403')) {
        _showMsg('❌ Session expired — please login again');
      } else {
        _showMsg('❌ Download failed: $reason');
      }
      return;
    }

    final sep = message.indexOf('|');
    if (sep < 0) {
      _showMsg('❌ Invalid response');
      return;
    }

    final type = message.substring(0, sep);
    final b64 = message.substring(sep + 1);
    final isPdf = type == 'pdf';

    try {
      setState(() => _downloadMsg = '⬇️ Saving file...');

      // dart:convert base64 decode — correct and handles padding automatically
      final bytes = base64Decode(b64);

      if (bytes.isEmpty) {
        _showMsg('❌ Empty file received');
        return;
      }

      // Verify PDF magic bytes %PDF-
      if (isPdf && bytes.length > 4) {
        final magic = String.fromCharCodes(bytes.sublist(0, 5));
        if (!magic.startsWith('%PDF')) {
          _showMsg('❌ Invalid PDF — server returned wrong content');
          return;
        }
      }

      final dir = await getApplicationDocumentsDirectory();
      final ext = isPdf ? 'pdf' : 'csv';
      final fileName = 'IntelliBudget_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final savePath = '${dir.path}/$fileName';

      await File(savePath).writeAsBytes(bytes, flush: true);

      setState(() {
        _isDownloading = false;
        _downloadMsg = '✅ Downloaded! Opening...';
      });

      final result = await OpenFilex.open(savePath);
      if (result.type == ResultType.noAppToOpen) {
        _showMsg('✅ Saved: $fileName\n(Install PDF viewer to open)');
      } else {
        _showMsg('✅ Opened successfully');
      }

      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    } catch (e) {
      _showMsg('❌ Decode error: ${e.toString().split('\n').first}');
    }
  }

  Future<bool> _requestPermissionIfNeeded() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await Process.run('getprop', ['ro.build.version.sdk']);
      final sdk = int.tryParse(r.stdout.toString().trim()) ?? 29;
      if (sdk <= 28) {
        final s = await Permission.storage.request();
        return s.isGranted;
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
      onError: (e) =>
          _controller.runJavaScript("window.onSpeechError('${e.errorMsg}')"),
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
      _controller.runJavaScript("window.onSpeechError('Microphone not available')");
    }
  }

  Future<void> _stopListening() async => _speech.stop();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (await _controller.canGoBack()) _controller.goBack();
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
