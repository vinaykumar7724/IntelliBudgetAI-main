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
        onNavigationRequest: (NavigationRequest request) async {
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

  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    var status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;
    status = await Permission.storage.request();
    return status.isGranted;
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
      final fileName =
          isPdf ? 'IntelliBudget_Report.pdf' : 'IntelliBudget_Export.csv';

      final dir = await getExternalStorageDirectory();
      final savePath = '${dir!.path}/$fileName';

      // Step 1: Get one-time token via JS fetch (uses browser session)
      final tokenResult =
          await _controller.runJavaScriptReturningResult('''
        (async () => {
          try {
            const params = new URLSearchParams(window.location.search);
            const from = params.get('from_date') || '';
            const to   = params.get('to_date') || '';
            const url  = '/generate-download-token?from_date=' + from + '&to_date=' + to;
            const r    = await fetch(url, { credentials: 'include' });
            const d    = await r.json();
            return d.token || '';
          } catch(e) {
            return '';
          }
        })()
      ''');

      final token =
          tokenResult.toString().replaceAll('"', '').trim();

      if (token.isEmpty) {
        _showMsg('❌ Session expired — please login again');
        setState(() => _isDownloading = false);
        return;
      }

      // Step 2: Download using token (no cookie needed)
      final downloadUrl = isPdf
          ? '$_baseUrl/export/pdf-token/$token'
          : '$_baseUrl/export/csv-token/$token';

      setState(() => _downloadMsg = '⬇️ Downloading...');

      final dio = Dio();
      final response = await dio.get(
        downloadUrl,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (status) => status! < 500,
        ),
      );

      // Verify we got actual file not HTML error page
      final contentType =
          response.headers['content-type']?.first ?? '';
      if (contentType.contains('text/html')) {
        _showMsg('❌ Download failed — try again');
        setState(() => _isDownloading = false);
        return;
      }

      final file = File(savePath);
      await file.writeAsBytes(response.data);

      setState(() {
        _isDownloading = false;
        _downloadMsg = '✅ Saved: $fileName';
      });

      await OpenFilex.open(savePath);

      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _downloadMsg = '');
      });
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadMsg = '❌ Download failed';
      });
    }
  }

  void _showMsg(String msg) {
    setState(() => _downloadMsg = msg);
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
      _controller.runJavaScript(
          "window.onSpeechError('Microphone not available')");
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
                      CircularProgressIndicator(
                          color: Color(0xFF6C63FF)),
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
                        if (_isDownloading)
                          const SizedBox(width: 10),
                        Text(
                          _downloadMsg,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
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
