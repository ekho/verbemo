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
