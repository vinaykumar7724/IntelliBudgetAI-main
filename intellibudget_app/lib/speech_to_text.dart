import 'package:speech_to_text/speech_to_text.dart';

final SpeechToText _speech = SpeechToText();

Future<void> startListening() async {
  bool available = await _speech.initialize(
    onError: (error) => print('Error: ${error.errorMsg}'),
    onStatus: (status) => print('Status: $status'),
  );

  if (available) {
    _speech.listen(
      onResult: (result) {
        print('Recognized: ${result.recognizedWords}');
        // send to your chat input
      },
    );
  } else {
    print("Speech recognition not available or permission denied");
  }
}