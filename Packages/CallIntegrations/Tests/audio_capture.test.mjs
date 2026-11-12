import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const script = fs.readFileSync(new URL('../Sources/KTalkIntegration/Resources/capture.js', import.meta.url), 'utf8');

async function fixture({ muted = false } = {}) {
  const events = [], nodes = [], copies = [], intervals = new Set(), blobs = new Map();
  let now = 0, processorType;
  const original = {
    id: 'original', kind: 'audio', readyState: 'live', enabled: !muted, stops: 0,
    clone() { const copy = { enabled: this.enabled, stop() { this.stopped = true; } }; copies.push(copy); return copy; },
    stop() { this.stops++; },
  };
  const person = { id: 'self', name: 'Synthetic host', local: true, isAnonymous: false, audioMuted: muted,
    audioTrack: { jitsiTrack: { track: original } } };
  const conf = { joined: true, roomInfo: { roomName: 'room', conferenceId: 'conference' },
    isAudioMuted: muted, participants: [person], localParticipant: person };
  const processorSandbox = { Float32Array, sampleRate: 48000, currentFrame: 0,
    registerProcessor(name, type) { processorType = type; },
    AudioWorkletProcessor: class { constructor() { this.port = {}; } } };
  const context = {
    sampleRate: 48000, state: 'running', destination: {},
    get currentTime() { return now / 1000; },
    audioWorklet: { async addModule(url) { vm.runInNewContext(await blobs.get(url).text(), processorSandbox); } },
    async resume() {}, async close() { this.state = 'closed'; },
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; },
    createGain() { return { gain: { value: 1 }, connect() {}, disconnect() {} }; },
  };
  const window = { $conf: conf, __verbemoAudio_test: payload => events.push(JSON.parse(payload)) };
  const sandbox = { window, Float32Array, Uint8Array, ArrayBuffer, Blob, JSON, Map, Set, Error,
    AudioContext: function() { return context; },
    AudioWorkletNode: class {
      constructor(ctx, name, options) {
        this.processor = new processorType(options);
        this.port = { postMessage: data => this.processor.port.onmessage?.({ data }) };
        this.processor.port.postMessage = data => this.port.onmessage?.({ data });
        nodes.push(this);
      }
      connect() {} disconnect() {}
    },
    MediaStream: class { constructor(tracks) { this.tracks = tracks; } },
    URL: { createObjectURL(blob) { const key = `blob:${blobs.size}`; blobs.set(key, blob); return key; }, revokeObjectURL(url) { blobs.delete(url); } },
    performance: { now: () => now },
    btoa: binary => Buffer.from(binary, 'binary').toString('base64'),
    setInterval(fn) { intervals.add(fn); return fn; }, clearInterval(fn) { intervals.delete(fn); },
    navigator: { mediaDevices: { getUserMedia() { throw new Error('Must reuse existing tracks'); } } },
  };
  const install = vm.runInNewContext(script, sandbox);
  await install({ run: 'test', binding: '__verbemoAudio_test', control: '__verbemoCapture_test', conference: 'conference' });
  return { events, original, conf, copies, context, window,
    async tick(milliseconds = 100) { now += milliseconds; for (const fn of [...intervals]) await fn(); },
    pcm() {
      const before = events.length;
      for (let n = 0; n < 32; n++) {
        for (const node of nodes) node.processor.process([[new Float32Array(128).fill(0.5)]]);
        processorSandbox.currentFrame += 128;
      }
      return events.slice(before).filter(x => x.type === 'audio');
    },
  };
}

test('a clone born muted becomes audible after unmute; pause gates buffered frames', async () => {
  const f = await fixture({ muted: true });
  assert.equal(f.copies.length, 1);
  const muted = f.pcm();
  assert.equal(muted.length, 1);
  assert.ok(Buffer.from(muted[0].pcm, 'base64').every(x => x === 0));
  f.conf.isAudioMuted = false;
  f.conf.localParticipant.audioMuted = false;
  f.original.enabled = true;
  await f.tick();
  assert.equal(f.copies[0].enabled, true);
  const audible = f.pcm();
  assert.equal(Buffer.from(audible[0].pcm, 'base64').readFloatLE(0), 0.5);
  assert.equal(audible[0].frame, 4096);
  f.conf.isAudioMuted = true;
  await f.tick();
  assert.ok(Buffer.from(f.pcm()[0].pcm, 'base64').every(x => x === 0));
  await f.window.__verbemoCapture_test.cleanup();
  assert.equal(f.original.stops, 0);
  assert.ok(f.copies.every(c => c.stopped));
  assert.equal(f.context.state, 'closed');
  assert.equal(f.window.__verbemoCapture_test, undefined);
  assert.equal(f.window.__verbemoAudio_test, undefined);
});

test('lease expiry cleans up an abandoned capture without ending original audio', async () => {
  const f = await fixture();
  await f.tick(6000);
  assert.ok(f.copies.every(c => c.stopped));
  assert.equal(f.original.stops, 0);
  assert.equal(f.context.state, 'closed');
  assert.equal(f.window.__verbemoAudio_test, undefined);
});

test('call exit is explicit and replacing a track advances its generation', async () => {
  const f = await fixture();
  f.conf.localParticipant.audioTrack.jitsiTrack.track = { ...f.original, id: 'replacement' };
  await f.tick();
  const tracks = f.events.filter(e => e.type === 'track');
  assert.deepEqual(tracks.map(t => t.generation), [1, 2]);
  assert.ok(tracks.every(t => t.participant.id === 'self'));
  assert.equal(f.copies[0].stopped, true);
  f.conf.joined = false;
  await f.tick();
  assert.equal(f.events.at(-1).type, 'ended');
  assert.equal(f.original.stops, 0);
});
