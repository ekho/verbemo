// Focused guard for the six proposed palettes; this is not an accessibility audit.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const html = fs.readFileSync(require('node:path').join(__dirname, 'visual-directions.html'), 'utf8');
const css = html.slice(html.indexOf('/* UX71 hypotheses.'), html.indexOf('</style>'));
const declarations = selector => {
  const block = css.slice(css.indexOf(selector + '{') + selector.length + 1).split('}')[0];
  return Object.fromEntries([...block.matchAll(/(--[\w-]+):([^;}]*)/g)].map(m => [m[1], m[2]]));
};
const lum = hex => {
  if (hex.length === 4) hex = "#" + [...hex.slice(1)].map(x => x + x).join("");
  const v = hex.slice(1).match(/../g).map(n => parseInt(n, 16) / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4);
  return v[0] * .2126 + v[1] * .7152 + v[2] * .0722;
};
const contrast = (a,b) => (Math.max(lum(a),lum(b))+.05)/(Math.min(lum(a),lum(b))+.05);
let pairs = 0;
for (const direction of ['focus','paper','studio']) for (const dark of [false,true]) {
  const tokens = {...declarations('body'),...(dark?declarations('body.dark'):{})};
  if (direction !== 'focus') Object.assign(tokens,declarations(`body[data-visual=${direction}]`),dark?declarations(`body[data-visual=${direction}].dark`):{});
  for (const [foreground,background] of [['--ink','--paper'],['--muted','--paper'],['--muted','--surface'],['--accent','--paper'],['--accent','--selected'],['--paper','--accent'],['--ink','--mark']]) {
    const ratio = contrast(tokens[foreground],tokens[background]);
    assert.ok(ratio >= 4.5, `${direction}/${dark?'dark':'light'} ${foreground}/${background}: ${ratio.toFixed(2)}`);
    pairs++;
  }
}
const original = fs.readFileSync(require('node:path').join(__dirname,'prototype-a.html'),'utf8');
const model = text => text.slice(text.indexOf('const UX70 ='),text.indexOf('globalThis.UX70=UX70;'));
assert.equal(model(html),model(original),'visual hypotheses must preserve the accepted state model');
assert.match(html,/data-voice=/,'speaker distinction must retain letter identity as well as color');
console.log(`${pairs} palette pairs >= 4.5:1; accepted state model unchanged.`);

// Exercise the changed presentation logic without replacing the browser checks.
const vm = require('node:vm');
const state = {selected:'short',find:false,localQuery:'',hit:0};
const view = {version:'previous',tab:'transcript',scroll:{}};
const content = {scrollTop:320};
const ctx = vm.createContext({s:state,findOrigin:null,T:(_ru,en)=>en,
  UX70:{view:()=>view,active:j=>['queued','running','cancelling'].includes(j.status)},
  $:()=>content,saveScroll:()=>{view.scroll[view.version+':'+view.tab]=content.scrollTop;},
  render:()=>{content.scrollTop=view.scroll[view.version+':'+view.tab]||0;}});
vm.runInContext(html.slice(html.indexOf('function setLocalQuery('),html.indexOf('function jump(')),ctx);
ctx.setLocalQuery('compass');
assert.equal(ctx.findOrigin.scroll,320);
view.tab='summary';content.scrollTop=50;
ctx.setLocalQuery('beacon');
assert.equal(ctx.findOrigin.tab,'transcript','editing a query must keep the original reading position');
ctx.setLocalQuery('');
assert.equal(view.version,'previous');assert.equal(view.tab,'transcript');
assert.equal(content.scrollTop,320);assert.equal(state.find,false);assert.equal(ctx.findOrigin,null);
ctx.setLocalQuery('another');state.selected='long';view.version='current';view.tab='summary';ctx.endFind();
assert.equal(view.version,'current');assert.equal(view.tab,'summary','clearing must not restore another meeting');
console.log('PASS local search restores the original version/tab/position only for the same meeting.');

vm.runInContext(html.slice(html.indexOf('function meetingStatus('),html.indexOf('function meetingStatusIcon(')),ctx);
const meeting={id:'short',status:'ready'};
for(const [status,icon] of [['queued','waiting'],['running','processing'],['cancelling','processing'],['error','error'],['cancelled','cancelled'],['done','ready']]) {
  state.job={meeting:'short',status};assert.equal(ctx.meetingStatus(meeting)[0],icon);
  assert.ok(ctx.meetingStatus(meeting)[1]);
}
state.recording={id:'short',paused:false};assert.equal(ctx.meetingStatus(meeting)[0],'recording');
state.recording.paused=true;assert.equal(ctx.meetingStatus(meeting)[0],'paused');
state.recording=null;state.job=null;
assert.equal(ctx.meetingStatus({...meeting,status:'failed'})[0],'error');
assert.equal(ctx.meetingStatus({...meeting,status:'deferred'})[0],'waiting');
console.log('PASS meeting icons distinguish recording, pause, queue, processing, error and cancellation.');

ctx.UX70.current=()=>({duration:180});
vm.runInContext(html.slice(html.indexOf('function togglePlayback('),html.indexOf('function syncPlaybackButtons(')),ctx);
state.playing=false;state.time=20;ctx.togglePlayback();
assert.equal(state.playing,true);assert.equal(state.time,20);
ctx.togglePlayback();assert.equal(state.playing,false);assert.equal(state.time,20,'pause keeps position');
ctx.stopPlayback();assert.equal(state.playing,false);assert.equal(state.time,0,'stop resets position');
state.time=180;ctx.togglePlayback();assert.equal(state.playing,true);assert.equal(state.time,0,'play restarts a completed recording');
console.log('PASS playback supports resume, pause, stop and replay after completion.');

ctx.dismissedJobNotice=null;
vm.runInContext(html.slice(html.indexOf('function jobNoticeVisible('),html.indexOf('function jobStatus(')),ctx);
state.job={meeting:'short',kind:'summary',status:'cancelled'};
const preserved=JSON.stringify(state);
assert.equal(ctx.jobNoticeVisible(state.job),true);
ctx.dismissJobNotice();
assert.equal(ctx.jobNoticeVisible(state.job),false);
assert.equal(JSON.stringify(state),preserved,'dismissal must not change the processing or meeting model');
assert.equal(ctx.meetingStatus(meeting)[0],'cancelled','status remains available outside the banner');
state.job={meeting:'short',kind:'summary',status:'cancelled'};
assert.equal(ctx.jobNoticeVisible(state.job),true,'a new job must not inherit dismissal');
state.job.status='running';ctx.dismissJobNotice();
assert.equal(ctx.jobNoticeVisible(state.job),false);
state.job.status='error';assert.equal(ctx.jobNoticeVisible(state.job),true,'a changed status must reappear');
assert.equal(ctx.jobNoticeVisible(null),false);
console.log('PASS notice dismissal preserves results/status and does not hide a new job or outcome.');
