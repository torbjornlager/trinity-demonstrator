/** Browser speech transport. Dialogue decisions belong to the statechart. */
export class BrowserVoice {
  constructor({ onTranscript, onNotice, onChange }) {
    this.onTranscript = onTranscript;
    this.onNotice = onNotice;
    this.onChange = onChange;
    this.Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    this.synthesis = window.speechSynthesis;
    this.canListen = Boolean(this.Recognition);
    this.canSpeak = Boolean(this.synthesis && window.SpeechSynthesisUtterance);
    this.spoken = this.canSpeak;
    this.listening = false;
    this.speaking = false;
    this.recognition = null;
    this.utterance = null;
  }

  setSpoken(enabled) {
    this.spoken = enabled && this.canSpeak;
    if (!this.spoken) this.cancelSpeech();
  }

  cancelSpeech() {
    // Clear the identity first: cancel() may dispatch an old utterance's callback.
    this.utterance = null;
    this.speaking = false;
    this.synthesis?.cancel();
    this.onChange();
  }

  speak(text) {
    if (!this.spoken || this.listening) return;
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
    this.speaking = true;
    const finish = (event) => {
      if (this.utterance !== utterance) return;
      this.utterance = null;
      this.speaking = false;
      this.onChange();
      if (
        event.type === 'error' &&
        !['interrupted', 'canceled'].includes(event.error)
      ) {
        this.onNotice(
          'Spoken replies are unavailable right now. Every reply is also shown below.'
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
        this.onNotice('Hearing: “' + transcript + '”');
      }
    };
    recognition.onerror = (event) => {
      if (this.recognition !== recognition) return;
      this.stopListening();
      const messages = {
        'not-allowed':
          'Microphone access was denied. You can type or use the choices instead.',
        'service-not-allowed':
          'Speech recognition is blocked in this browser. You can still type or use the choices.',
        'audio-capture':
          'No microphone was found. You can type or use the choices instead.',
        network:
          'The browser speech service could not connect. Try typing or the choices.',
        'no-speech': 'No speech was detected. Tap the microphone to try again.',
      };
      this.onNotice(
        messages[event.error] ||
          'Listening stopped. You can try again or type your reply.'
      );
    };
    recognition.onend = () => {
      if (this.recognition !== recognition) return;
      this.recognition = null;
      this.listening = false;
      this.onChange();
      this.onNotice('Microphone off. Tap to speak again, or type a reply.');
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
        'Speech recognition could not start. You can still type or use the choices.'
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
