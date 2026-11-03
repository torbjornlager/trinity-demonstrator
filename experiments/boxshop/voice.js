/** Browser speech transport. Dialogue decisions belong to the statechart. */
export class BrowserVoice {
  constructor({ onTranscript, onUnconfirmed, onNotice, onChange }) {
    this.onTranscript = onTranscript;
    this.onUnconfirmed = onUnconfirmed;
    this.onNotice = onNotice;
    this.onChange = onChange;
    this.Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    this.synthesis = window.speechSynthesis;
    this.canListen = Boolean(this.Recognition);
    this.canSpeak = Boolean(this.synthesis && window.SpeechSynthesisUtterance);
    this.listening = false;
    this.recognition = null;
    this.utterance = null;
  }

  cancelSpeech() {
    // Clear the identity first: cancel() may dispatch an old utterance's callback.
    this.utterance = null;
    this.synthesis?.cancel();
    this.onChange();
  }

  speak(text) {
    if (!this.canSpeak || this.listening) return;
    this.cancelSpeech();
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = 'en-US';
    utterance.rate = 0.96;
    const voices = this.synthesis.getVoices();
    utterance.voice =
      voices.find((voice) => voice.lang.startsWith('en') && voice.localService) ||
      voices.find((voice) => voice.lang.startsWith('en')) ||
      null;
    this.utterance = utterance;
    const finish = (event) => {
      if (this.utterance !== utterance) return;
      this.utterance = null;
      this.onChange();
      if (
        event.type === 'error' &&
        !['interrupted', 'canceled'].includes(event.error)
      ) {
        this.onNotice(
          'Spoken replies are unavailable right now. Check your browser’s speech synthesis settings.'
        );
      }
    };
    utterance.onend = finish;
    utterance.onerror = finish;
    this.onChange();
    try {
      this.synthesis.speak(utterance);
    } catch {
      finish({ type: 'error', error: 'service-unavailable' });
    }
  }

  listen() {
    if (!this.canListen || this.listening) return;
    // Push-to-talk permits barge-in and prevents the assistant hearing itself.
    this.cancelSpeech();
    const recognition = new this.Recognition();
    recognition.lang = 'en-US';
    recognition.continuous = false;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;
    this.recognition = recognition;
    // Starting the service is different from capturing audio or detecting speech.
    // Preserve those milestones so a silent onend does not hide the useful clue.
    let audioStarted = false,
      speechDetected = false,
      interimText = '';
    recognition.onaudiostart = () => {
      if (this.recognition !== recognition) return;
      audioStarted = true;
      this.onNotice('Microphone active. Say “blue” or “small” in English, then pause.');
    };
    recognition.onspeechstart = () => {
      if (this.recognition !== recognition) return;
      speechDetected = true;
      this.onNotice('Speech detected. Waiting for recognised words…');
    };
    recognition.onnomatch = () => {
      if (this.recognition !== recognition) return;
      this.stopListening();
      this.onNotice(
        'The speech service returned no match. Tap to speak and try “blue” in English.'
      );
    };
    recognition.onstart = () => {
      if (this.recognition !== recognition) return;
      this.listening = true;
      this.onChange();
      this.onNotice('Listening… say a colour or a size.');
    };
    recognition.onresult = (event) => {
      if (this.recognition !== recognition) return;
      for (let index = event.resultIndex; index < event.results.length; index++) {
        const result = event.results[index];
        const transcript = result[0].transcript.trim();
        if (result.isFinal) {
          this.stopListening();
          this.onTranscript(transcript);
          return;
        }
        interimText = transcript;
        this.onNotice('Hearing: “' + transcript + '”');
      }
    };
    recognition.onerror = (event) => {
      if (this.recognition !== recognition) return;
      this.stopListening();
      const messages = {
        'not-allowed':
          'Microphone unavailable: access was denied. Allow microphone access for this site in your browser and for the browser in system settings.',
        'service-not-allowed':
          'Microphone unavailable: speech recognition is blocked. Check browser permissions or open the page directly in Chrome.',
        'audio-capture':
          'Microphone unavailable: no audio input was found. Connect a microphone or select one in your sound settings.',
        network:
          'The speech service could not connect. Check your internet connection and try again.',
        'no-speech':
          'No speech was detected. Check the selected microphone and input level, then tap to speak again.',
      };
      this.onNotice(
        messages[event.error] || 'Listening stopped. Tap to speak again.',
        true
      );
    };
    recognition.onend = () => {
      if (this.recognition !== recognition) return;
      this.recognition = null;
      this.listening = false;
      this.onChange();
      if (interimText) this.onUnconfirmed(interimText);
      else if (speechDetected)
        this.onNotice(
          'Chrome detected speech but returned no recognised words. Tap to speak and try “blue” in English.'
        );
      else if (audioStarted)
        this.onNotice(
          'Microphone capture started, but Chrome reported no speech. Check the selected microphone and input level.'
        );
      else
        this.onNotice(
          'Recognition ended before Chrome reported microphone capture. Check Chrome and macOS microphone access.'
        );
    };
    try {
      // Mark the request immediately, including time spent in a permission prompt.
      this.listening = true;
      this.onChange();
      this.onNotice('Requesting the microphone… allow access if your browser asks.');
      recognition.start();
    } catch {
      this.stopListening();
      this.onNotice(
        'Microphone unavailable: recognition could not start. Check microphone permissions and try again.',
        true
      );
    }
  }

  stopListening() {
    const recognition = this.recognition;
    this.recognition = null;
    this.listening = false;
    recognition?.abort();
    this.onChange();
  }

  cancel() {
    this.stopListening();
    this.cancelSpeech();
  }
}
