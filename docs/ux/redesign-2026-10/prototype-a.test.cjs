const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const file = path.resolve(__dirname, process.argv[2] || 'prototype-a.html');
assert.ok(fs.existsSync(file), 'offline prototype artifact must exist');
const html = fs.readFileSync(file, 'utf8');
const data = JSON.parse(html.match(/<script id="fixture-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
const code = html.match(/<script id="prototype-code">([\s\S]*?)<\/script>/)[1];
const context = {};
vm.runInNewContext(code, context);
const m = context.UX70;
const s = m.createState(data);
let checks = 0;
function check(name, run) { run(); checks++; console.log('PASS', name); }
check('UX69 corpus includes long meeting and distinct unknown speaker', () => {
  assert.equal(data.find(x => x.id === 'long').versions.current.segments.length, 180);
  assert.ok(data.find(x => x.id === 'assignment').versions.current.segments.some(x => x.speaker === 'them ?'));
});
check('search distinguishes title, transcript, summary and no matches', () => {
  assert.ok(m.search(s, 'Атлас').some(x => x.source === 'title'));
  assert.ok(m.search(s, 'Кварцевый компас').some(x => x.source === 'transcript'));
  assert.ok(m.search(s, 'Сапфировый маяк').every(x => x.source === 'summary'));
  assert.equal(m.search(s, 'Несуществующий термин').length, 0);
});
m.select(s, 'assignment', 'current');
const archiveBefore = JSON.stringify(s.meetings.find(x => x.id === 'assignment').versions.previous);
check('assignment affects selected cluster, preserves archive and other meetings', () => {
  const other = JSON.stringify(s.meetings.find(x => x.id === 'short'));
  assert.equal(m.assign(s, {meeting: 'assignment', version: 'current', speaker: 'them C', name: 'Вера Макетная', participantID: 'ux69-2'}), true);
  assert.equal(s.meetings.find(x => x.id === 'assignment').versions.current.names['them C'].name, 'Вера Макетная');
  assert.equal(JSON.stringify(s.meetings.find(x => x.id === 'assignment').versions.previous), archiveBefore);
  assert.equal(JSON.stringify(s.meetings.find(x => x.id === 'short')), other);
});
check('unknown and stale requests are refused', () => {
  assert.equal(m.assign(s, {meeting:'assignment',version:'current',speaker:'them ?',name:'Вера'}), false);
  m.select(s, 'assignment', 'previous');
  assert.equal(m.assign(s, {meeting:'assignment',version:'current',speaker:'them C',name:'Ошибка'}), false);
  assert.ok(m.search(s, 'Кварцевый компас', true).every(x => x.meeting === 'assignment' && x.version === 'previous'));
});
check('unlink keeps speaker identity and does not change archived result', () => {
  m.select(s, 'assignment', 'current');
  assert.equal(m.assign(s, {meeting:'assignment',version:'current',speaker:'them C',name:'',participantID:null}), true);
  assert.equal(s.meetings.find(x => x.id === 'assignment').versions.current.names['them C'], undefined);
  assert.equal(JSON.stringify(s.meetings.find(x => x.id === 'assignment').versions.previous), archiveBefore);
});
check('busy assignment/deletion refused; error and cancellation preserve ready summary', () => {
  const before = s.meetings.find(x => x.id === s.selected).versions.current.summary;
  for (const outcome of ['error','cancelled']) {
    m.startJob(s, 'summary');
    assert.equal(m.assign(s, {meeting:'assignment',version:'current',speaker:'them C',name:'Ошибка'}), false);
    assert.equal(m.remove(s), false);
    m.finishJob(s, outcome);
    assert.equal(s.meetings.find(x => x.id === 'assignment').versions.current.summary, before);
  }
});
check('job completion is bound to job target, navigation and recording are independent', () => {
  m.startJob(s, 'summary');
  s.recording = {id:'recording-demo',paused:false};
  m.select(s, 'long', 'current');
  s.page = 'settings';
  m.finishJob(s, 'done');
  assert.equal(s.selected, 'long');
  assert.equal(s.page, 'settings');
  assert.equal(s.recording.id, 'recording-demo');
  assert.match(s.meetings.find(x => x.id === 'assignment').versions.current.summary, /Демонстрационный результат/);
});
check('delete and undo restore meeting without changing current selection', () => {
  assert.equal(m.remove(s), true);
  const selected = s.selected;
  m.undo(s);
  assert.equal(s.selected, selected);
  assert.ok(!s.meetings.find(x => x.id === 'long').deleted);
});
check('successful re-transcription preserves old result and selection until explicit switch', () => {
  m.select(s, 'short', 'current');
  const old = JSON.stringify(s.meetings.find(x => x.id === 'short').versions.current);
  m.startJob(s, 'transcript');
  m.finishJob(s, 'done');
  const meeting = s.meetings.find(x => x.id === 'short');
  assert.notEqual(s.views.short.version, 'current');
  assert.equal(JSON.stringify(meeting.versions[s.views.short.version]), old);
  assert.equal(meeting.versions.current.summary, '');
  m.select(s, 'long');
  m.select(s, 'short');
  assert.notEqual(s.views.short.version, 'current');
});

console.log(`${checks} checks passed; browser behavior is checked separately.`);
