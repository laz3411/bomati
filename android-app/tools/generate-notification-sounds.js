const fs = require('fs');
const path = require('path');

const sampleRate = 44100;
const outputDir = path.resolve(__dirname, '../app/src/main/res/raw');

function envelope(t, duration) {
  const attack = Math.min(1, t / 0.012);
  const release = Math.min(1, Math.max(0, (duration - t) / 0.16));
  return attack * release * Math.exp(-1.7 * t);
}

function render(notes, totalDuration) {
  const samples = Math.ceil(totalDuration * sampleRate);
  const pcm = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i += 1) {
    const time = i / sampleRate;
    let value = 0;
    for (const note of notes) {
      const local = time - note.start;
      if (local < 0 || local >= note.duration) continue;
      const phase = 2 * Math.PI * note.frequency * local;
      const shimmer = Math.sin(phase * 2.01) * 0.18 + Math.sin(phase * 3.99) * 0.06;
      value += (Math.sin(phase) + shimmer) * envelope(local, note.duration) * note.gain;
    }
    const softClipped = Math.tanh(value * 1.25) * 0.72;
    pcm.writeInt16LE(Math.round(softClipped * 32767), i * 2);
  }
  return pcm;
}

function writeWav(filename, notes, duration) {
  const pcm = render(notes, duration);
  const wav = Buffer.alloc(44 + pcm.length);
  wav.write('RIFF', 0);
  wav.writeUInt32LE(36 + pcm.length, 4);
  wav.write('WAVE', 8);
  wav.write('fmt ', 12);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(sampleRate, 24);
  wav.writeUInt32LE(sampleRate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write('data', 36);
  wav.writeUInt32LE(pcm.length, 40);
  pcm.copy(wav, 44);
  fs.writeFileSync(path.join(outputDir, filename), wav);
}

fs.mkdirSync(outputDir, { recursive: true });

writeWav('bumati_classic.wav', [
  { start: 0.00, duration: 0.28, frequency: 1046.50, gain: 0.48 },
  { start: 0.20, duration: 0.30, frequency: 1318.51, gain: 0.50 },
  { start: 0.42, duration: 0.32, frequency: 1567.98, gain: 0.52 },
  { start: 0.66, duration: 0.50, frequency: 2093.00, gain: 0.56 }
], 1.30);

writeWav('bumati_gentle.wav', [
  { start: 0.00, duration: 0.62, frequency: 783.99, gain: 0.40 },
  { start: 0.42, duration: 0.78, frequency: 1174.66, gain: 0.46 }
], 1.38);

writeWav('bumati_urgent.wav', [
  { start: 0.00, duration: 0.25, frequency: 987.77, gain: 0.53 },
  { start: 0.22, duration: 0.30, frequency: 1567.98, gain: 0.57 },
  { start: 0.58, duration: 0.25, frequency: 987.77, gain: 0.53 },
  { start: 0.80, duration: 0.44, frequency: 1760.00, gain: 0.60 }
], 1.40);

console.log(`Generated BUMATI notification sounds in ${outputDir}`);
