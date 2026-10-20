import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { analyzeCommits } from '@semantic-release/commit-analyzer';
import { generateNotes } from '@semantic-release/release-notes-generator';
import semver from 'semver';

const repository = 'https://github.com/ekho/verbemo';

export async function prepareRelease(root, releases, prerelease = false) {
  const git = (...args) => execFileSync('git', args, {
    cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'],
  }).trim();
  const stable = value => semver.valid(value) === value && !semver.prerelease(value) && !value.includes('+');
  const readLog = (...args) => {
    const fields = git('log', '-z', '--format=%H%x00%B', ...args).split('\0');
    const commits = [];
    for (let i = 0; i + 1 < fields.length; i += 2) commits.push({ hash: fields[i], message: fields[i + 1] });
    return commits;
  };
  const tagExists = tag => git('tag', '--list', tag) === tag;
  const ancestor = sha => {
    try { git('merge-base', '--is-ancestor', sha, 'HEAD'); }
    catch { throw new Error('release tag must be an ancestor of the source branch'); }
  };
  if (![`${repository}.git`, repository, 'git@github.com:ekho/verbemo.git',
    'ssh://git@github.com/ekho/verbemo.git'].includes(git('remote', 'get-url', 'origin'))) {
    throw new Error('origin must be ekho/verbemo');
  }
  if (git('rev-parse', '--is-shallow-repository') !== 'false') throw new Error('shallow history is not allowed');
  if (git('status', '--porcelain', '--untracked-files=all')) throw new Error('working tree is dirty');
  for (const name of ['VERSION', 'CHANGELOG.md', 'docs']) {
    if (lstatSync(join(root, name), { throwIfNoEntry: false })?.isSymbolicLink()) {
      throw new Error(`unsafe release path: ${name}`);
    }
  }
  const version = readFileSync(join(root, 'VERSION'), 'utf8').trim();
  if (!stable(version)) throw new Error('VERSION must be stable three-component SemVer');
  const own = releases.filter(r => r.tag_name.startsWith('verbemo-v'));
  for (const release of own) {
    if (!stable(release.tag_name.slice('verbemo-v'.length))) throw new Error('invalid own release tag');
  }
  const published = own.filter(r => !r.draft).sort((a, b) =>
    semver.rcompare(a.tag_name.slice('verbemo-v'.length), b.tag_name.slice('verbemo-v'.length)));
  const previous = published[0];
  const lastVersion = previous?.tag_name.slice('verbemo-v'.length);
  if (previous) {
    ancestor(previous.tag_name);
    if (git('show', `${previous.tag_name}:VERSION`) !== lastVersion) throw new Error('published tag VERSION mismatch');
  }

  const versions = readLog('--first-parent', '--', 'VERSION');
  let candidate = readLog('--first-parent', '--fixed-strings', `--grep=chore(release): ${version}`)
    .find(commit => commit.message.split('\n')[0] === `chore(release): ${version}`) || versions[0];
  if (git('merge-base', candidate.hash, versions[0].hash) !== versions[0].hash) candidate = versions[0];
  const versionCommit = candidate.hash;
  const message = candidate.message.trim();
  const channel = prerelease ? 'preview' : 'signed';
  let migrating = false;
  if (version !== lastVersion && message.split('\n')[0] === `chore(release): ${version}`) {
    const parent = git('rev-parse', `${versionCommit}^`);
    if (!message.split('\n').includes(`Release-Source: ${parent}`)) throw new Error('invalid pending version commit');
    const tag = `verbemo-v${version}`;
    if (own.some(r => r.tag_name === tag && r.draft)) {
      throw new Error('draft already exists: rerun failed publication with retained artifacts; do not rebuild');
    }
    if (tagExists(tag)) throw new Error('pending version already has a tag; inspect publication before retrying');
    if (lastVersion && !semver.gt(version, lastVersion)) throw new Error('pending VERSION is behind the published version');
    const previousChannel = message.split('\n').includes('Release-Channel: preview') ? 'preview' : 'signed';
    if (channel === previousChannel) return { release: true, created: false, version, source_commit: versionCommit };
    migrating = true;
  }
  if (!migrating && previous && version !== lastVersion) throw new Error('VERSION differs from the last published release without a pending release commit');

  // The VERSION adoption commit excludes inherited Amanu history before the first own release.
  const adoption = versions.find(commit => !commit.message.startsWith('chore(release): '));
  const base = previous?.tag_name || adoption.hash;
  const commits = readLog(`${base}..HEAD`);
  const context = {
    cwd: root, commits, logger: { log() {} },
    options: { repositoryUrl: repository },
    lastRelease: previous ? { version: lastVersion, gitTag: base } : { gitHead: base },
  };
  const config = { preset: 'conventionalcommits', presetConfig: {} };
  const type = await analyzeCommits(config, context);
  if (!type) return { release: false };
  const floor = migrating ? lastVersion || git('show', `${adoption.hash}:VERSION`) : version;
  let nextVersion = semver.inc(floor, type);
  if (migrating && semver.lt(nextVersion, version)) nextVersion = version;
  if (tagExists(`verbemo-v${nextVersion}`)) throw new Error('next version tag already exists; inspect publication');
  context.nextRelease = { version: nextVersion, gitTag: `verbemo-v${nextVersion}` };
  const notes = (await generateNotes(config, context)).trim() + '\n';
  const notesName = `docs/release-notes-verbemo-v${nextVersion}.md`;
  if (lstatSync(join(root, notesName), { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error('unsafe release notes path');
  mkdirSync(join(root, 'docs'), { recursive: true });
  writeFileSync(join(root, notesName), notes, { flag: migrating && nextVersion === version ? 'w' : 'wx' });
  const changelog = join(root, 'CHANGELOG.md');
  let existing = existsSync(changelog) ? readFileSync(changelog, 'utf8') : '';
  if (migrating) existing = git('ls-tree', '--name-only', base, '--', 'CHANGELOG.md') ? git('show', `${base}:CHANGELOG.md`) + '\n' : '';
  writeFileSync(changelog, notes + '\n' + existing);
  writeFileSync(join(root, 'VERSION'), nextVersion + '\n');
  const parent = git('rev-parse', 'HEAD');
  git('add', '--', 'VERSION', 'CHANGELOG.md', notesName);
  git('-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    'commit', '--allow-empty', '-qm', `chore(release): ${nextVersion}\n\nRelease-Source: ${parent}\nRelease-Channel: ${channel}`);
  return { release: true, created: true, version: nextVersion, source_commit: git('rev-parse', 'HEAD') };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const releases = JSON.parse(execFileSync('gh', ['api', '--paginate', '--slurp',
      'repos/ekho/verbemo/releases?per_page=100'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })).flat();
    const plan = await prepareRelease(process.cwd(), releases, process.argv.includes('--prerelease'));
    if (process.env.GITHUB_OUTPUT) {
      appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(plan).map(([key, value]) => `${key}=${value}\n`).join(''));
    }
    console.log(JSON.stringify(plan));
  } catch (error) {
    console.error(`auto-release: ${error.status ? 'command failed; inspect repository and GitHub state before retrying' : error.message}`);
    process.exitCode = 1;
  }
}
