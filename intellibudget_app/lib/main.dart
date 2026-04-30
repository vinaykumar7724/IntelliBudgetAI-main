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
          // Intercept ALL export URLs — prevent browser/webview from handling
          if (url.contains('/export') || url.contains('download')) {
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
      ..loadRequest(Uri.parse(_baseUrl));

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  // ── Permission: only ask WRITE on Android <= 9 (API 28) ──────────────────
  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // Android 10+ (API 29+): app-specific dirs need NO permission
    // Android 9 and below: need WRITE_EXTERNAL_STORAGE
    final androidInfo = await _getAndroidSdkInt();
    if (androidInfo <= 28) {
      final status = await Permission.storage.request();
      return status.isGranted;
    }
    return true;
  }

  Future<int> _getAndroidSdkInt() async {
    try {
      // Read SDK version from system property via dart:io
      final result = await Process.run('getprop', ['ro.build.version.sdk']);
      return int.tryParse(result.stdout.toString().trim()) ?? 29;
    } catch (_) {
      return 29; // assume modern, no permission needed
    }
  }

  // ── Get save directory — reliable across all Android versions ─────────────
  Future<String> _getSaveDir() async {
    try {
      // Primary: app documents dir (no permission needed, survives uninstall)
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {
      try {
        // Fallback: temp dir
        final dir = await getTemporaryDirectory();
        return dir.path;
      } catch (_) {
        // Last resort
        return '/data/local/tmp';
      }
    }
  }

  Future<void> _downloadFile(String url) async {
    final granted = await _requestStoragePermission();
    if (!granted) {
      _showMsg('❌ Storage permission denied');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadMsg = '⬇️ Preparing download...';
    });

    try {
      final isPdf = url.contains('pdf');
      final ext = isPdf ? 'pdf' : 'csv';
      final fileName =
          'IntelliBudget_${DateTime.now().millisecondsSinceEpoch}.$ext';

      final saveDir = await _getSaveDir();
      final savePath = '$saveDir/$fileName';

      // Step 1: Get one-time token via JS (uses existing browser session cookie)
      final tokenResult = await _controller.runJavaScriptReturningResult('''
        (async () => {
          try {
            const params = new URLSearchParams(window.location.search);
            const from = params.get('from_date') || '';
            const to   = params.get('to_date')   || '';
            const r    = await fetch(
              '/generate-download-token?from_date=' + from + '&to_date=' + to,
              { credentials: 'include' }
            );
            if (!r.ok) return '';
            const d = await r.json();
            return d.token || '';
          } catch(e) {
            return '';
          }
        })()
      ''');

      final token = tokenResult.toString().replaceAll('"', '').trim();

      if (token.isEmpty) {
        _showMsg('❌ Session expired — please login again');
        setState(() => _isDownloading = false);
        return;
      }

      // Step 2: Download via token (no cookie/session needed)
      final downloadUrl = isPdf
          ? '$_baseUrl/export/pdf-token/$token'
          : '$_baseUrl/export/csv-token/$token';

      setState(() => _downloadMsg = '⬇️ Downloading...');

      final dio = Dio();
      final response = await dio.download(
        downloadUrl,
        savePath,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 500,
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 10),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final pct = (received / total * 100).toStringAsFixed(0);
            if (mounted) {
              setState(() => _downloadMsg = '⬇️ Downloading... $pct%');
            }
          }
        },
      );

      // Verify not an HTML error page
      final file = File(savePath);
      if (!await file.exists() || await file.length() < 100) {
        _showMsg('❌ Download failed — file empty');
        setState(() => _isDownloading = false);
        return;
      }

      // For PDF: verify PDF header magic bytes
      if (isPdf) {
        final header = await file.openRead(0, 5).first;
        final isPdfFile = String.fromCharCodes(header).startsWith('%PDF');
        if (!isPdfFile) {
          await file.delete();
          _showMsg('❌ Download failed — invalid file received');
          setState(() => _isDownloading = false);
          return;
        }
      }

      setState(() {
        _isDownloading = false;
        _downloadMsg = '✅ Downloaded! Opening...';
      });

      // Open in-app using system PDF/CSV viewer
      final result = await OpenFilex.open(savePath);

      if (result.type == ResultType.noAppToOpen) {
        _showMsg('✅ Saved to: $fileName (no viewer installed)');
      } else if (result.type == ResultType.done) {
        _showMsg('✅ Opened: $fileName');
      } else {
        _showMsg('✅ Saved: $fileName');
      }

      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    } on DioException catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadMsg = '❌ Network error: ${e.message ?? 'check connection'}';
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadMsg = '❌ Download failed: ${e.toString().split('\n').first}';
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    }
  }

  void _showMsg(String msg) {
    setState(() {
      _isDownloading = false;
      _downloadMsg = msg;
    });
    Future.delayed(const Duration(seconds: 3), () {
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
