const VoiceInput = (() => {
    let inputEl, btnEl, statusEl;
    let isListening = false;

    // Check if running inside Flutter WebView
    const isFlutter = window.FlutterSpeech !== undefined ||
                      navigator.userAgent.includes('wv');

    function setStatus(msg) {
        if (statusEl) statusEl.textContent = msg;
    }

    function setBtnState(listening) {
        if (!btnEl) return;
        btnEl.textContent = listening ? '🔴' : '🎙️';
        btnEl.title = listening ? 'Listening... click to stop' : 'Click to speak';
    }

    // ── Flutter channel speech (Android WebView) ──────────────
    function startFlutterSpeech() {
        setStatus('🎙️ Listening...');
        setBtnState(true);
        isListening = true;

        // Tell Flutter to start listening
        if (window.FlutterSpeech) {
            window.FlutterSpeech.postMessage('start');
        }
    }

    function stopFlutterSpeech() {
        setStatus('');
        setBtnState(false);
        isListening = false;
        if (window.FlutterSpeech) {
            window.FlutterSpeech.postMessage('stop');
        }
    }

    // Flutter calls this function with the recognized text
    window.onSpeechResult = function(text) {
        if (inputEl) {
            inputEl.value = text;
            setStatus('✅ Got: ' + text);
            setBtnState(false);
            isListening = false;
            // Auto-send after voice input
            setTimeout(() => {
                document.getElementById('chat-form')
                    .dispatchEvent(new Event('submit',
                        { bubbles: true, cancelable: true }));
                setStatus('');
            }, 500);
        }
    };

    window.onSpeechError = function(error) {
        setStatus('❌ ' + error);
        setBtnState(false);
        isListening = false;
    };

    // ── Browser speech (desktop/Chrome) ───────────────────────
    let recognition = null;

    function startBrowserSpeech() {
        const SpeechRecognition = window.SpeechRecognition ||
                                  window.webkitSpeechRecognition;
        if (!SpeechRecognition) {
            setStatus('❌ Speech not supported on this browser');
            return;
        }

        recognition = new SpeechRecognition();
        recognition.lang = 'en-IN';
        recognition.interimResults = false;
        recognition.maxAlternatives = 1;

        recognition.onstart = () => {
            setStatus('🎙️ Listening...');
            setBtnState(true);
            isListening = true;
        };

        recognition.onresult = (e) => {
            const text = e.results[0][0].transcript;
            inputEl.value = text;
            setStatus('✅ Got: ' + text);
            setBtnState(false);
            isListening = false;
            setTimeout(() => {
                document.getElementById('chat-form')
                    .dispatchEvent(new Event('submit',
                        { bubbles: true, cancelable: true }));
                setStatus('');
            }, 500);
        };

        recognition.onerror = (e) => {
            setStatus('❌ Error: ' + e.error);
            setBtnState(false);
            isListening = false;
        };

        recognition.onend = () => {
            if (isListening) {
                setBtnState(false);
                isListening = false;
                setStatus('');
            }
        };

        recognition.start();
    }

    function stopBrowserSpeech() {
        if (recognition) recognition.stop();
        setBtnState(false);
        isListening = false;
        setStatus('');
    }

    // ── Public API ─────────────────────────────────────────────
    function init(options) {
        inputEl  = document.getElementById(options.inputId);
        btnEl    = document.getElementById(options.btnId);
        statusEl = document.getElementById(options.statusId);

        btnEl.addEventListener('click', () => {
            if (isListening) {
                isFlutter ? stopFlutterSpeech() : stopBrowserSpeech();
            } else {
                isFlutter ? startFlutterSpeech() : startBrowserSpeech();
            }
        });

        // Keyboard shortcut Ctrl+Shift+V
        document.addEventListener('keydown', (e) => {
            if (e.ctrlKey && e.shiftKey && e.key === 'V') {
                btnEl.click();
            }
        });
    }

    return { init };
})();