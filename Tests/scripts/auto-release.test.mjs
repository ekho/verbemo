import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync, symlinkSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { prepareRelease } from '../../scripts/release-automation/auto-release.mjs';

function fixture(t, version = '0.1.0') {
  const root = mkdtempSync(join(tmpdir(), 'verbemo-version-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  git('init', '-q', '-b', 'master');
  git('config', 'user.name', 'Fixture');
  git('config', 'user.email', 'fixture@example.invalid');
  git('remote', 'add', 'origin', 'https://github.com/ekho/verbemo.git');
  writeFileSync(join(root, 'VERSION'), version + '\n');
  const commit = message => {
    git('add', '-A');
    git('commit', '--allow-empty', '-qm', message);
    return git('rev-parse', 'HEAD');
  };
  commit('chore: independent product version');
  const published = value => {
    const tag_name = `verbemo-v${value}`;
    git('tag', tag_name);
    return { tag_name, name: `Verbemo ${value}`, draft: false, prerelease: false };
  };
  return { root, git, commit, published };
}

for (const [message, expected] of [
  ['fix: preserve recording', '0.1.1'],
  ['feat(macos): copy summaries', '0.2.0'],
  ['feat!: change session format', '1.0.0'],
  ['refactor: new format\n\nBREAKING CHANGE: old format removed', '1.0.0'],
  ['perf: reduce allocations', '0.1.1'],
]) {
  test(`versions ${message.split('\n')[0]} as ${expected}`, async t => {
    const f = fixture(t);
    const releases = [f.published('0.1.0')];
    f.commit(message);
    const plan = await prepareRelease(f.root, releases);
    assert.equal(plan.version, expected);
    assert.equal(plan.created, true);
    assert.equal(readFileSync(join(f.root, 'VERSION'), 'utf8'), expected + '\n');
    assert.equal(plan.source_commit, f.git('rev-parse', 'HEAD'));
    assert.equal(f.git('status', '--porcelain'), '');
    assert.deepEqual(f.git('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD').split('\n'),
      ['CHANGELOG.md', 'VERSION', `docs/release-notes-verbemo-v${expected}.md`]);
    assert.ok(readFileSync(join(f.root, 'CHANGELOG.md'), 'utf8').includes(message.split('\n')[0].split(': ')[1]));
  });
}

test('takes the largest change since the last own release, ignoring historical tags', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.git('tag', 'v99.0.0');
  f.git('tag', 'windows-v99.0.0');
  f.commit('feat: import audio');
  f.commit('fix: preserve names');
  assert.equal((await prepareRelease(f.root, releases)).version, '0.2.0');
});

test('bootstraps from the own VERSION change instead of inherited commit history', async t => {
  const f = fixture(t, '0.6.6');
  f.commit('feat!: inherited format change');
  f.git('tag', 'windows-v0.6.6');
  writeFileSync(join(f.root, 'VERSION'), '0.1.0\n');
  f.commit('chore: adopt the independent product version');
  f.commit('feat: own feature');
  const plan = await prepareRelease(f.root, [{ tag_name: 'windows-v0.6.6', draft: false, prerelease: false }]);
  assert.equal(plan.version, '0.2.0');
});

test('does not release documentation, test or maintenance commits', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.commit('docs: describe setup');
  f.commit('test: check setup');
  const before = f.commit('chore: update tooling');
  assert.deepEqual(await prepareRelease(f.root, releases), { release: false });
  assert.equal(f.git('rev-parse', 'HEAD'), before);
});

test('reuses an unpublished version commit after build failure, even with newer changes', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.commit('fix: preserve audio');
  const first = await prepareRelease(f.root, releases);
  const newer = f.commit('feat: another feature');
  const retry = await prepareRelease(f.root, releases);
  assert.deepEqual(retry, { ...first, created: false });
  assert.equal(f.git('rev-parse', 'HEAD'), newer);
});

test('includes queued newer changes after the pending version has been published', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.commit('fix: preserve audio');
  const first = await prepareRelease(f.root, releases);
  releases.push(f.published(first.version));
  f.commit('feat: another feature');
  const next = await prepareRelease(f.root, releases);
  assert.equal(next.version, '0.2.0');
  assert.ok(readFileSync(join(f.root, 'CHANGELOG.md'), 'utf8').includes('preserve audio'));
  assert.ok(readFileSync(join(f.root, 'CHANGELOG.md'), 'utf8').includes('another feature'));
  assert.ok(!readFileSync(join(f.root, 'docs/release-notes-verbemo-v0.2.0.md'), 'utf8').includes('preserve audio'));
});

test('draft publication requires retained artifacts rather than rebuilding signed bytes', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.commit('fix: preserve audio');
  const plan = await prepareRelease(f.root, releases);
  releases.push({ tag_name: `verbemo-v${plan.version}`, draft: true, prerelease: false });
  await assert.rejects(prepareRelease(f.root, releases), /retained artifacts/);
});

test('refuses untracked files without committing or changing VERSION', async t => {
  const f = fixture(t);
  f.commit('feat: feature');
  writeFileSync(join(f.root, 'private.txt'), 'must not be committed');
  await assert.rejects(prepareRelease(f.root, []), /dirty/);
  assert.equal(readFileSync(join(f.root, 'VERSION'), 'utf8'), '0.1.0\n');
});

test('refuses a manually changed VERSION after a published release', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  writeFileSync(join(f.root, 'VERSION'), '0.5.0\n');
  f.commit('chore: change version manually');
  f.commit('fix: fix audio');
  await assert.rejects(prepareRelease(f.root, releases), /VERSION/);
});

test('refuses an existing unaccounted tag instead of moving it', async t => {
  const f = fixture(t);
  const releases = [f.published('0.1.0')];
  f.commit('fix: audio');
  const first = await prepareRelease(f.root, releases);
  f.git('tag', `verbemo-v${first.version}`);
  await assert.rejects(prepareRelease(f.root, releases), /tag/);
  assert.equal(f.git('rev-parse', `verbemo-v${first.version}`), first.source_commit);
});

test('refuses a published release outside this branch history', async t => {
  const f = fixture(t);
  f.git('checkout', '-qb', 'other');
  writeFileSync(join(f.root, 'VERSION'), '0.2.0\n');
  f.commit('feat: other branch');
  const releases = [f.published('0.2.0')];
  f.git('checkout', '-q', 'master');
  f.commit('fix: current branch');
  await assert.rejects(prepareRelease(f.root, releases), /ancestor/);
});

test('refuses an upstream repository and shallow history', async t => {
  const f = fixture(t);
  f.commit('feat: feature');
  f.git('remote', 'set-url', 'origin', 'https://github.com/gsamat/amanu.git');
  await assert.rejects(prepareRelease(f.root, []), /origin/);
  f.git('remote', 'set-url', 'origin', 'https://github.com/ekho/verbemo.git');
  writeFileSync(join(f.root, '.git/shallow'), f.git('rev-parse', 'HEAD') + '\n');
  await assert.rejects(prepareRelease(f.root, []), /shallow/);
});

test('does not follow a broken changelog symlink outside the checkout', async t => {
  const f = fixture(t);
  const outside = join(tmpdir(), `verbemo-no-write-${process.pid}.md`);
  t.after(() => rmSync(outside, { force: true }));
  symlinkSync(outside, join(f.root, 'CHANGELOG.md'));
  f.commit('feat: feature');
  await assert.rejects(prepareRelease(f.root, []), /unsafe release path/);
  assert.equal(existsSync(outside), false);
});
