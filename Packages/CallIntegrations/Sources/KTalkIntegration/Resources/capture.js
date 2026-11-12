(async function install(config) {
  /* verbemo participant capture */
  const conference = window.$conf;
  if (!conference?.joined || (conference.roomInfo?.conferenceId || conference.roomInfo?.roomName) !== config.conference
      || typeof window[config.binding] !== 'function' || window[config.control]) throw new Error('Capture unavailable');
  const context = new AudioContext({ sampleRate: 48000 });
  const tracks = new Map(), generations = new Map();
  let closed = false, timer, lease = performance.now() + 5000, lastHeartbeat = -Infinity;
  const send = value => {
    if (!closed) window[config.binding](JSON.stringify({ run: config.run, ...value }));
  };
  const detach = entry => {
    entry.node.port.onmessage = null;
    entry.source.disconnect(); entry.node.disconnect(); entry.silent.disconnect();
    entry.clone.stop();
  };
  const state = {
    renew() { if (closed) return false; lease = performance.now() + 5000; return true; },
    async cleanup() {
      if (closed) return;
      closed = true; clearInterval(timer);
      for (const entry of tracks.values()) detach(entry);
      tracks.clear();
      delete window[config.binding];
      try { await context.close(); } finally {
        if (window[config.control] === state) delete window[config.control];
      }
    },
  };
  window[config.control] = state;
  const muted = person => person.local ? conference.isAudioMuted !== false : person.audioMuted === true;
  const describe = person => ({
    id: person.id,
    name: [person.userInfo?.firstName, person.userInfo?.lastName].filter(x => typeof x === 'string' && x.trim()).join(' ') || person.name,
    isLocal: person.local, isGuest: person.isAnonymous,
    microphoneMuted: typeof person.audioMuted === 'boolean' ? person.audioMuted : null,
    cameraMuted: typeof person.cameraMuted === 'boolean' ? person.cameraMuted : null,
  });
  function reconcile() {
    if (closed) return;
    if (performance.now() > lease) { void state.cleanup(); return; }
    if (window.$conf !== conference || conference.joined === false) {
      send({ type: 'ended' }); void state.cleanup(); return;
    }
    if (conference.joined !== true || !Array.isArray(conference.participants) || context.state !== 'running') throw new Error('Unsupported capture state');
    const people = [...conference.participants];
    if (conference.localParticipant && !people.includes(conference.localParticipant)) people.push(conference.localParticipant);
    if (people.length > 256) throw new Error('Too many tracks');
    const seen = new Set();
    for (const person of people) {
      if (!person || typeof person.id !== 'string' || !person.id || typeof person.name !== 'string'
          || typeof person.local !== 'boolean' || typeof person.isAnonymous !== 'boolean' || seen.has(person.id)) throw new Error('Unsupported participant');
      seen.add(person.id);
      const original = person.audioTrack?.jitsiTrack?.track;
      let entry = tracks.get(person.id);
      if (!original || original.kind !== 'audio' || original.readyState !== 'live') {
        if (entry) { detach(entry); tracks.delete(person.id); send({ type: 'removed', id: person.id }); }
        continue;
      }
      const metadata = describe(person), encoded = JSON.stringify(metadata);
      if (!entry || entry.original !== original) {
        if (entry) detach(entry);
        const generation = (generations.get(person.id) || 0) + 1;
        generations.set(person.id, generation);
        const clone = original.clone();
        clone.enabled = !muted(person);
        const source = context.createMediaStreamSource(new MediaStream([clone]));
        const node = new AudioWorkletNode(context, 'verbemo-participant', { processorOptions: { muted: muted(person) } });
        const silent = context.createGain(); silent.gain.value = 0;
        entry = { original, clone, source, node, silent, generation, person, metadata: encoded };
        tracks.set(person.id, entry);
        node.port.onmessage = message => {
          if (closed || tracks.get(person.id) !== entry || window.$conf !== conference || !conference.joined) return;
          const bytes = new Uint8Array(message.data.samples);
          // A mute invalidates audio still queued for delivery from the worklet.
          if (muted(entry.person)) bytes.fill(0);
          let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
          send({ type: 'audio', id: person.id, generation, frame: message.data.frame,
            rate: context.sampleRate, pcm: btoa(binary) });
        };
        send({ type: 'track', id: person.id, generation, rate: context.sampleRate, participant: metadata });
        source.connect(node); node.connect(silent); silent.connect(context.destination);
      } else {
        entry.person = person;
        if (entry.metadata !== encoded) {
          entry.metadata = encoded;
          send({ type: 'track', id: person.id, generation: entry.generation, rate: context.sampleRate, participant: metadata });
        }
      }
      entry.clone.enabled = !muted(person);
      entry.node.port.postMessage({ muted: muted(person) });
    }
    for (const [id, entry] of tracks) if (!seen.has(id)) {
      detach(entry); tracks.delete(id); send({ type: 'removed', id });
    }
    if (performance.now() - lastHeartbeat >= 500) {
      lastHeartbeat = performance.now();
      send({ type: 'heartbeat', frame: Math.round(context.currentTime * context.sampleRate), rate: context.sampleRate });
    }
  }
  timer = setInterval(() => {
    try {
      if (performance.now() > lease) void state.cleanup();
      else if (state.ready) reconcile();
    } catch { send({ type: 'error' }); void state.cleanup(); }
  }, 100);
  try {
    const module = `class ParticipantProcessor extends AudioWorkletProcessor {
      constructor(options) {
        super(); this.samples = new Float32Array(4096); this.used = 0; this.frame = 0;
        this.muted = options.processorOptions.muted;
        this.port.onmessage = event => {
          this.muted = event.data.muted;
          if (this.muted) this.samples.fill(0);
        };
      }
      process(inputs) {
        const channels = inputs[0] || [], length = channels[0]?.length || 128;
        for (let i = 0; i < length; i++) {
          if (!this.used) this.frame = currentFrame + i;
          let value = 0;
          if (!this.muted && channels.length) {
            for (const channel of channels) value += channel[i] || 0;
            value /= channels.length;
          }
          this.samples[this.used++] = Number.isFinite(value) ? value : 0;
          if (this.used === 4096) {
            this.port.postMessage({ frame: this.frame, samples: this.samples.buffer }, [this.samples.buffer]);
            this.samples = new Float32Array(4096); this.used = 0;
          }
        }
        return true;
      }
    }
    registerProcessor('verbemo-participant', ParticipantProcessor);`;
    const url = URL.createObjectURL(new Blob([module], { type: 'text/javascript' }));
    try { await context.audioWorklet.addModule(url); } finally { URL.revokeObjectURL(url); }
    if (closed) throw new Error('Capture stopped');
    await context.resume();
    state.ready = true;
    reconcile();
    return true;
  } catch (error) {
    await state.cleanup(); throw error;
  }
})
