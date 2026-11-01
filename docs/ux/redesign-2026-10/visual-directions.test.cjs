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

const importCtx=vm.createContext({structuredClone,Date:{now:()=>123},T:(ru)=>ru,announce:()=>{},render:()=>{}});
vm.runInContext(model(html)+';globalThis.UX70=UX70;',importCtx);
importCtx.s=importCtx.UX70.createState(JSON.parse(html.match(/<script id="fixture-data" type="application\/json">([\s\S]*?)<\/script>/)[1]));
vm.runInContext(html.slice(html.indexOf('function addMeeting('),html.indexOf("document.addEventListener('click'")),importCtx);
const beforeImport=JSON.stringify(importCtx.s);
importCtx.importFiles([]);assert.equal(JSON.stringify(importCtx.s),beforeImport,'cancel creates no meeting');
const count=importCtx.s.meetings.length;
const fakeFile=name=>({name,get size(){throw Error('metadata beyond name is not needed');},text(){throw Error('file must not be read');},arrayBuffer(){throw Error('file must not be read');}});
importCtx.importFiles([fakeFile('sample-a.wav'),fakeFile('sample-b.mp4')]);
const added=importCtx.s.meetings.slice(count);
assert.equal(added.length,2);assert.equal(new Set(added.map(m=>m.id)).size,2,'batch IDs must be distinct even in the same millisecond');
assert.deepEqual(Array.from(added,m=>m.title),['sample-a.wav','sample-b.mp4']);
assert.ok(added.every(m=>m.status==='deferred'&&m.versions.current.segments.length===0));
assert.equal(importCtx.s.page,'meeting');assert.equal(importCtx.s.selected,added[1].id);
console.log('PASS file selection uses names only, supports a batch and leaves cancellation unchanged.');

const filterHandlers={};let filterFocus,filterOpen=false,clearedFind=false;
const filterState={filter:'all',query:'Атлас',localQuery:'решение',find:true,selected:'short',playing:true,time:42};
const filterCtx=vm.createContext({s:filterState,document:{addEventListener:(type,handler)=>{filterHandlers[type]=handler;}},
  $:id=>id==='editor'?{open:false}:{matches:()=>filterOpen},render:id=>{filterFocus=id;},
  endFind:()=>{clearedFind=true;}});
vm.runInContext(html.slice(html.indexOf("document.addEventListener('change'"),html.indexOf("document.addEventListener('beforetoggle'")),filterCtx);
const preservedFilterContext=JSON.stringify({...filterState,filter:undefined});
for(const value of ['attention','processing','all']){
  filterHandlers.change({target:{name:'meeting-filter',value,matches:()=>false}});
  assert.equal(filterState.filter,value);assert.equal(filterFocus,'filter-button');
  assert.equal(JSON.stringify({...filterState,filter:undefined}),preservedFilterContext,'filtering must preserve search, selection and playback');
}
vm.runInContext(html.slice(html.indexOf("document.addEventListener('keydown'"),html.indexOf("$('editor').addEventListener('cancel'")),filterCtx);
const escape={key:'Escape',target:{getAttribute:()=>null,matches:()=>false}};
filterOpen=true;filterHandlers.keydown(escape);assert.equal(clearedFind,false,'Escape in the filter must not also clear meeting search');
filterOpen=false;filterHandlers.keydown(escape);assert.equal(clearedFind,true,'existing search Escape works after the filter closes');
console.log('PASS filtering preserves the meeting context; popover Escape does not clear meeting search.');

const now=1_000_000,minute=60_000;
const event=(id,start,end,extra={})=>({id,title:id,start:now+start*minute,end:now+end*minute,looksLikeCall:true,calendarSelected:true,...extra});
const match=(events,enabled=true)=>importCtx.recordingCalendar(events,now,enabled);
const ongoing=event('ongoing',-30,30),upcoming=event('upcoming',2,32);
assert.equal(match([ongoing]).suggested.id,'ongoing');
assert.equal(match([event('ended',-30,0)]).suggested,null);
assert.equal(match([event('eight',8,38)]).suggested.id,'eight');
assert.equal(match([event('later',8.01,38)]).suggested,null);
assert.equal(match([event('solo',0,30,{looksLikeCall:false}),upcoming]).suggested.id,'upcoming');
assert.equal(match([event('earlier',-2,30),upcoming]).suggested.id,'upcoming');
assert.equal(match([ongoing,event('nearest',-1,30),upcoming]).suggested.id,'nearest');
assert.equal(match([ongoing],false).events.length,0);assert.equal(match([]).suggested,null);
assert.equal(match([event('hidden',0,30,{calendarSelected:false}),event('cancelled',0,30,{cancelled:true})]).events.length,0);
const allDay=match([event('day',-100,100,{allDay:true})]);assert.equal(allDay.events.length,1);assert.equal(allDay.suggested,null);
console.log('PASS calendar matching respects access, selected calendars, ongoing events, eight-minute early joins and call priority.');

importCtx.Date=Date;importCtx.demoCalendarState='granted';importCtx.s.platform='mac';
importCtx.E=String;importCtx.B=()=>'';importCtx.icon=()=>'';let recordingSubmit,recordingBody;
const recordingFields={'record-title':{value:'custom'},'record-event':{value:'demo-calendar-current'}};
importCtx.$=id=>recordingFields[id];importCtx.closeDialog=()=>{};
importCtx.dialog=(body,submit)=>{recordingBody=body;recordingSubmit=submit;};
const beforeDraft=JSON.stringify(importCtx.s);
importCtx.openRecordingDialog();assert.equal(JSON.stringify(importCtx.s),beforeDraft,'opening/cancelling a draft must not create a recording');
assert.match(recordingBody,/value="Атлас — планирование пилота"/);
recordingFields['record-event'].value='demo-calendar-next';recordingFields['record-event'].onchange();
assert.equal(recordingFields['record-title'].value,'Атлас — обзор материалов','explicit event selection replaces the draft title');
recordingFields['record-title'].value='Моё название';recordingSubmit();
const linked=importCtx.UX70.current(importCtx.s);assert.equal(linked.title,'Моё название');assert.equal(linked.calendarEvent.id,'demo-calendar-next');
recordingFields['record-event'].value='';recordingFields['record-event'].onchange();assert.equal(recordingFields['record-title'].value,'Моё название','unlink preserves the title');
importCtx.startDemoRecording('Без события',null);assert.equal(importCtx.UX70.current(importCtx.s).calendarEvent,null);
console.log('PASS recording drafts prefill and replace event titles, preserve later edits and retain the chosen event when started.');

vm.runInContext(html.slice(html.indexOf('function clampedLibraryWidth('),html.indexOf('function resizeLibrary(')),ctx);
assert.equal(ctx.clampedLibraryWidth(180,1100),220);
assert.equal(ctx.clampedLibraryWidth(600,1100),480);
assert.equal(ctx.clampedLibraryWidth(480,850),430);
assert.equal(ctx.clampedLibraryWidth(320,1100),320);
console.log('PASS library resize preserves minimum content width and clamps both bounds.');

vm.runInContext(html.slice(html.indexOf('function applyInlinePerson('),html.indexOf('function clampedLibraryWidth(')),importCtx);
importCtx.s.selected='short';const inlineMeeting=importCtx.UX70.current(importCtx.s),inlineVersion=importCtx.UX70.view(importCtx.s);
const input={value:'Ручное имя'},choice={value:''},row={dataset:{meeting:'short',version:'current',speaker:'them C'},querySelector:selector=>selector==='[data-person-name]'?input:choice};
const control=linked=>({closest:()=>row,hasAttribute:()=>linked});
const archive=JSON.stringify(inlineMeeting.versions.previous);
choice.value='ux69-2';importCtx.applyInlinePerson(control(true));
assert.equal(inlineMeeting.versions.current.names['them C'].participantID,'ux69-2');
assert.equal(input.value,'Вера Макетная');
importCtx.applyInlinePerson(control(false));assert.equal(choice.value,'ux69-2','leaving an unchanged name must retain its link');
input.value='Моё имя';importCtx.applyInlinePerson(control(false));
assert.equal(inlineMeeting.versions.current.names['them C'].name,'Моё имя');assert.equal(choice.value,'');
assert.equal(inlineMeeting.versions.current.names['them C'].participantID,null);
assert.equal(JSON.stringify(inlineMeeting.versions.previous),archive);
row.dataset.version='previous';input.value='Устаревший ввод';importCtx.applyInlinePerson(control(false));
assert.equal(inlineMeeting.versions.current.names['them C'].name,'Моё имя');
row.dataset.version='current';row.dataset.speaker='them ?';importCtx.applyInlinePerson(control(false));assert.equal(inlineMeeting.versions.current.names['them ?'],undefined);
console.log('PASS inline matching and manual names preserve version scope and reject stale/unknown voices.');
