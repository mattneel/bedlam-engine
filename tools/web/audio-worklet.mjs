// The Web audio device. `ARCHITECTURE.md` §17, M0 criterion 3 on the Web.
//
// **This is the device, not the mixer.** The mixer is `src/audio/mixer.zig`, compiled into
// the same wasm module the simulation uses — so the browser runs the *same* voice budget,
// panning, clipping and degradation behaviour as the WASAPI and PulseAudio backends, rather
// than a JavaScript reimplementation that drifts. Verified on s390x and mips by the cross
// gate, which is not a claim any JS mixer could make.
//
// What this file owns is what a device owns everywhere: the deadline and the format.
// `process` is called with a 128-frame quantum — 2.67 ms at 48 kHz, the tightest budget of
// any target Bedlam ships — and converts the mixer's interleaved i16 to the planar f32 the
// Web Audio graph wants, at the boundary, exactly where the other two backends convert to
// theirs.
//
// **The module is compiled synchronously.** An `AudioWorkletProcessor` constructor cannot
// await, and the 4 KB synchronous-compile limit applies to the main thread rather than to a
// worklet. Deferring instantiation to the first `process` call is the alternative and it is
// worse: the first quantum would then be silence, on every stream start, forever.

class BedlamMixer extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ready = false;
    this.blocks = 0;
    this.silentBlocks = 0;

    try {
      const bytes = options.processorOptions.wasm;
      const module = new WebAssembly.Module(bytes);
      this.wasm = new WebAssembly.Instance(module, {}).exports;
      this.wasm.bedlamAudioInit();
      this.wasm.bedlamAudioPlay(0, 0xffff);
      this.ready = true;
    } catch (e) {
      // Reported rather than thrown. A throw in this constructor kills the node with no
      // diagnostic reaching the page, and "no sound" is then indistinguishable from a
      // dozen other causes.
      this.port.postMessage({ type: 'failed', error: String(e) });
      return;
    }

    this.port.onmessage = (e) => {
      if (e.data.type === 'report') {
        this.port.postMessage({
          type: 'report',
          blocks: this.blocks,
          silentBlocks: this.silentBlocks,
          voices: this.wasm.bedlamAudioVoices(),
          clipped: this.wasm.bedlamAudioClipped(),
        });
      } else if (e.data.type === 'pan') {
        this.wasm.bedlamAudioPan(0, e.data.x | 0);
      }
    };
  }

  process(_inputs, outputs) {
    if (!this.ready) return true;

    const out = outputs[0];
    const frames = out[0].length;
    const ptr = this.wasm.bedlamAudioRender(frames);
    if (ptr === 0) return true;

    // A fresh view every quantum. The wasm memory can be resized, and a cached view over a
    // detached buffer reads zeros silently — which on an audio device is not a crash, it is
    // an hour spent looking for a mixer bug that is not there.
    const src = new Int16Array(this.wasm.memory.buffer, ptr, frames * 2);

    let nonzero = 0;
    const left = out[0];
    const right = out.length > 1 ? out[1] : out[0];
    for (let i = 0; i < frames; i += 1) {
      const l = src[i * 2];
      const r = src[i * 2 + 1];
      // Divide by 32768, not 32767: the i16 range is asymmetric, and scaling by the
      // positive maximum makes full-scale negative samples exceed -1.0, which the graph
      // clips a second time.
      left[i] = l / 32768;
      right[i] = r / 32768;
      nonzero |= l | r;
    }

    this.blocks += 1;
    // Counted because "the worklet ran" and "the worklet produced audio" are different
    // claims, and only the second one is criterion 3.
    if (nonzero === 0) this.silentBlocks += 1;
    return true;
  }
}

registerProcessor('bedlam-mixer', BedlamMixer);
