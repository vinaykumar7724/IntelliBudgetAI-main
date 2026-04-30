import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_cookie_manager/webview_cookie_manager.dart';

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
  final _cookieManager = WebviewCookieManager();
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
      ..loadRequest(Uri.parse(_baseUrl));

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  // ── Extract session cookie string from WebView ────────────────────────────
  Future<String?> _getSessionCookieHeader() async {
    try {
      final cookies = await _cookieManager.getCookies(_baseUrl);
      if (cookies.isEmpty) return null;
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (e) {
      debugPrint('Cookie error: $e');
      return null;
    }
  }

  // ── Parse date params from dashboard URL ──────────────────────────────────
  Map<String, String> _parseDateParams(String url) {
    try {
      final uri = Uri.parse(url);
      final p = uri.queryParameters;
      return {
        if (p['from_date'] != null) 'from_date': p['from_date']!,
        if (p['to_date'] != null) 'to_date': p['to_date']!,
      };
    } catch (_) {
      return {};
    }
  }

  // ── Storage permission only needed Android <= 9 ───────────────────────────
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

  Future<void> _downloadFile(String interceptedUrl) async {
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
      final isPdf = interceptedUrl.contains('pdf');
      final ext = isPdf ? 'pdf' : 'csv';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'IntelliBudget_$ts.$ext';

      // App documents dir — works all Android versions without permission
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/$fileName';

      // Get date params from current webview page URL
      final currentUrl = await _controller.currentUrl() ?? _baseUrl;
      final dateParams = _parseDateParams(currentUrl);

      // Build download URL (same endpoints Flask already has)
      final downloadUri = isPdf
          ? Uri.parse('$_baseUrl/export/pdf')
              .replace(queryParameters: dateParams.isEmpty ? null : dateParams)
          : Uri.parse('$_baseUrl/export');

      // Get session cookies from WebView (user already logged in)
      final cookieHeader = await _getSessionCookieHeader();
      if (cookieHeader == null || cookieHeader.isEmpty) {
        _showMsg('❌ Not logged in — please login first');
        setState(() => _isDownloading = false);
        return;
      }

      setState(() => _downloadMsg = '⬇️ Downloading...');

      // Dio GET with cookie header — Flask sees authenticated user
      final dio = Dio();
      final response = await dio.get<List<int>>(
        downloadUri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 15),
          headers: {
            'Cookie': cookieHeader,
            'Accept': isPdf ? 'application/pdf' : 'text/csv',
          },
        ),
      );

      // Validate response code
      if (response.statusCode == 401 || response.statusCode == 302) {
        _showMsg('❌ Session expired — please login again');
        setState(() => _isDownloading = false);
        return;
      }

      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) {
        _showMsg('❌ Server returned empty response');
        setState(() => _isDownloading = false);
        return;
      }

      // Check not HTML error page
      final contentType = response.headers['content-type']?.first ?? '';
      if (contentType.contains('text/html')) {
        _showMsg('❌ Session expired — please login again');
        setState(() => _isDownloading = false);
        return;
      }

      // Verify PDF magic bytes %PDF-
      if (isPdf && bytes.length > 4) {
        final magic = String.fromCharCodes(bytes.sublist(0, 5));
        if (!magic.startsWith('%PDF')) {
          _showMsg('❌ Invalid PDF from server');
          setState(() => _isDownloading = false);
          return;
        }
      }

      // Write to disk
      await File(savePath).writeAsBytes(bytes, flush: true);

      setState(() {
        _isDownloading = false;
        _downloadMsg = '✅ Downloaded! Opening...';
      });

      // Open in-app with system viewer (no browser)
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
