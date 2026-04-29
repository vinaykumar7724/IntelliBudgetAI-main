import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

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
         await _downloadPdf(url);
         return NavigationDecision.prevent;
       }
       if (url.contains('/export/csv') || url.contains('.csv')) {
         final uri = Uri.parse(url);
         if (await canLaunchUrl(uri)) {
           await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
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
      ..loadRequest(Uri.parse(
          'https://intellibudgetai-main-production.up.railway.app'));

    if (_controller.platform is AndroidWebViewController) {
      final androidController =
          _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);

      // Handle file downloads (PDF, CSV)
      androidController.setOnShowFileSelector((_) async => []);
    }
  }

  Future<void> _downloadPdf(String url) async {
  try {
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (!status.isGranted) return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/budget_report.pdf';

    final dio = Dio();
    await dio.download(url, filePath,
        options: Options(responseType: ResponseType.bytes));

    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      debugPrint('Could not open PDF: ${result.message}');
    }
  } catch (e) {
    debugPrint('PDF download error: $e');
  }
}
  Future<void> _startListening() async {
    bool available = await _speech.initialize(
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
            ],
          ),
        ),
      ),
    );
  }
}