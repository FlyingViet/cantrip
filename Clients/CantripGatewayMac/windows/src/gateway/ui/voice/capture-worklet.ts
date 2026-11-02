// Microphone capture (an AudioWorklet module, bundled to voice-capture.js): mixes the input to mono
// and posts ~50 ms blocks to the page, which resamples them to 16 kHz for the recognizer.

declare const sampleRate: number;
declare function registerProcessor(name: string, processor: unknown): void;
declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}

class CaptureProcessor extends AudioWorkletProcessor {
  private block = new Float32Array(Math.max(128, Math.round(sampleRate / 20)));
  private count = 0;
  private running = true;

  constructor() {
    super();
    this.port.onmessage = (event: MessageEvent) => {
      if (event.data === "stop") this.running = false;
    };
  }

  process(inputs: Float32Array[][]): boolean {
    const channels = inputs[0];
    if (channels && channels.length) {
      const frames = channels[0].length;
      for (let i = 0; i < frames; i++) {
        let sum = 0;
        for (let c = 0; c < channels.length; c++) sum += channels[c][i];
        this.block[this.count++] = sum / channels.length;
        if (this.count === this.block.length) {
          this.port.postMessage(this.block, [this.block.buffer]);
          this.block = new Float32Array(this.block.length);
          this.count = 0;
        }
      }
    }
    return this.running;
  }
}

registerProcessor("cantrip-voice-capture", CaptureProcessor);
