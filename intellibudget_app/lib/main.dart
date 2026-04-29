import 'dart:io';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isAndroid) {
    WebViewPlatform.instance = AndroidWebViewPlatform();
  }
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

          if (url.contains('/export/pdf') || url.contains('.pdf')) {
            final apiUrl = url.contains('/api/export/pdf')
                ? url
                : url.replaceFirst('/export/pdf', '/api/export/pdf');
            await _downloadFile(apiUrl, 'budget_report.pdf', 'application/pdf');
            return NavigationDecision.prevent;
          }

          if (url.contains('/export/csv') || url.contains('.csv')) {
            await _downloadFile(url, 'budget_report.csv', 'text/csv');
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        },
      ))
      ..addJavaScriptChannel(
        'FlutterSpeech',
        onMessageReceived: (JavaScriptMessage msg) async {
          if (msg.message == 'start') {
            await _startListening();
          } else if (msg.message == 'stop') {
            await _stopListening();
          }
        },
      )
      ..loadRequest(Uri.parse(
          'https://intellibudgetai-main-production.up.railway.app'));

    if (_controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setOnShowFileSelector((_) async => []);
    }
  }

  Future<void> _downloadFile(
      String url, String fileName, String mime) async {
    try {
      if (Platform.isAndroid) {
        final status = await Permission.storage.request();
        if (!status.isGranted) {
          debugPrint('DEBUG: Storage permission denied');
          return;
        }
      }

      String cookieHeader = '';
      try {
        final result = await _controller.runJavaScriptReturningResult(
          'document.cookie',
        );
        cookieHeader = result.toString().replaceAll('"', '');
        debugPrint('DEBUG: Cookies = $cookieHeader');
      } catch (e) {
        debugPrint('DEBUG: Cookie fetch failed = $e');
      }

      debugPrint('DEBUG: Downloading URL = $url');

      final dio = Dio();
      final response = await dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          headers: {
            if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
            'Accept': mime,
            'X-Requested-With': 'XMLHttpRequest',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );

      debugPrint('DEBUG: Status = ${response.statusCode}');
      debugPrint('DEBUG: Content-Type = ${response.headers.value('content-type')}');
      debugPrint('DEBUG: Content-Length = ${response.headers.value('content-length')}');

      final contentType = response.headers.value('content-type') ?? '';
      if (contentType.contains('text/html')) {
        debugPrint('DEBUG: Got HTML — not authenticated or wrong URL');
        await _controller.reload();
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(response.data as List<int>);
      debugPrint('DEBUG: File saved = $filePath');

      final openResult = await OpenFilex.open(filePath);
      debugPrint('DEBUG: OpenFilex result = ${openResult.type} ${openResult.message}');
    } catch (e) {
      debugPrint('DEBUG ERROR: $e');
    }
  }

  Future<void> _startListening() async {
    final bool available = await _speech.initialize(
      onError: (error) {
        _controller.runJavaScript(
            "window.onSpeechError('${error.errorMsg}')");
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
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
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
            ],
          ),
        ),
      ),
    );
  }
}
