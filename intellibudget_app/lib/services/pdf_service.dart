import 'dart:io';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class PdfService {
  final String baseUrl;
  final int userId;

  PdfService({required this.baseUrl, required this.userId});

  Future<void> downloadAndOpenPdf({
    String? fromDate,
    String? toDate,
  }) async {
    // 1. Ask for storage permission on Android < 13
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      if (!status.isGranted) throw Exception('Storage permission denied');
    }

    // 2. Build URL
    final query = <String, String>{};
    if (fromDate != null) query['from_date'] = fromDate;
    if (toDate != null)   query['to_date']   = toDate;
    final uri = Uri.parse('$baseUrl/api/export/pdf')
        .replace(queryParameters: query.isEmpty ? null : query);

    // 3. Download with Dio (sends X-User-Id header for backend auth)
    final dir = await getApplicationDocumentsDirectory();
    final filePath = '${dir.path}/expenses_report.pdf';

    final dio = Dio();
    await dio.download(
      uri.toString(),
      filePath,
      options: Options(
        headers: {'X-User-Id': userId.toString()},
        responseType: ResponseType.bytes,
      ),
    );

    // 4. Open the PDF
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      throw Exception('Could not open PDF: ${result.message}');
    }
  }
}