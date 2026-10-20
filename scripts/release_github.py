"""Small GitHub REST transport; no automatic retry of ambiguous mutations."""
import json
import os
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler

REPOSITORY = 'ekho/verbemo'
BASE = f'https://api.github.com/repos/{REPOSITORY}'


class ApiError(ValueError):
    def __init__(self, status):
        self.status = status
        super().__init__(f'GitHub request failed ({status}); inspect state before retrying')


class SafeRedirect(HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlparse(newurl).scheme != 'https':
            raise ValueError('non-HTTPS asset redirect rejected')
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            # CDN requests must never receive repository credentials, even when
            # a same-origin first redirect is followed by a different host.
            redirected.remove_header('Authorization')
            redirected.remove_header('Cookie')
        return redirected


class GitHub:
    def __init__(self, token=None, opener=None, sleep=time.sleep):
        self.token = token if token is not None else os.environ.get('GH_TOKEN', '')
        if not self.token:
            raise ValueError('GH_TOKEN is required for release state inspection')
        self.opener = opener or build_opener(SafeRedirect())
        self.sleep = sleep

    def request(self, url, method='GET', data=None, *, public=False, binary=False):
        parsed = urlparse(url)
        if parsed.scheme != 'https' or parsed.username or parsed.password:
            raise ValueError('unsafe GitHub URL')
        if not public and (parsed.netloc not in ('api.github.com', 'uploads.github.com') or
                           not parsed.path.startswith(f'/repos/{REPOSITORY}/') and parsed.path != f'/repos/{REPOSITORY}'):
            raise ValueError('authenticated request outside ekho/verbemo')
        headers = {'User-Agent': 'Verbemo-release', 'X-GitHub-Api-Version': '2026-03-10',
                   'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json'}
        if not public:
            headers['Authorization'] = f'Bearer {self.token}'
        if isinstance(data, dict):
            data = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
        elif data is not None:
            headers['Content-Type'] = 'application/octet-stream'
        if method != 'GET':
            self.sleep(1)  # Serialize mutations; failures stop rather than blind retry.
        try:
            with self.opener.open(Request(url, data=data, headers=headers, method=method), timeout=120) as response:
                content = response.read()
                return (content if binary else json.loads(content)), response.headers
        except HTTPError as error:
            # Never print response bodies or signed redirect URLs.
            raise ApiError(error.code) from None
        except (URLError, TimeoutError, OSError):
            raise ApiError('transport failure') from None

    def api(self, path, method='GET', data=None):
        return self.request(BASE + path, method, data)[0]

    def pages(self, path):
        url, result, visited = BASE + path, [], set()
        while url:
            if url in visited:
                raise ValueError('pagination loop')
            visited.add(url)
            page, headers = self.request(url)
            if not isinstance(page, list):
                raise ValueError('invalid paginated response')
            result.extend(page)
            links = re.findall(r'<([^>]+)>;\s*rel="next"', headers.get('Link', ''))
            url = links[0] if links else None
        return result

    def releases(self):
        return self.pages('/releases?per_page=100')

    def assets(self, release):
        return self.pages(f'/releases/{release["id"]}/assets?per_page=100')

    def latest(self):
        try:
            return self.api('/releases/latest')
        except ApiError as error:
            if error.status != 404:
                raise
            return None

    def tag_commit(self, tag):
        try:
            obj = self.api('/git/ref/tags/' + quote(tag, safe=''))['object']
        except ApiError as error:
            if error.status != 404:
                raise
            return None
        seen = set()
        while obj['type'] == 'tag':
            if obj['sha'] in seen or len(seen) >= 10:
                raise ValueError('invalid annotated tag chain')
            seen.add(obj['sha'])
            obj = self.api('/git/tags/' + obj['sha'])['object']
        if obj['type'] != 'commit':
            raise ValueError('tag does not point to a commit')
        return obj['sha']

    def download(self, asset, public=False):
        url = asset['browser_download_url'] if public else BASE + f'/releases/assets/{asset["id"]}'
        return self.request(url, public=public, binary=True)[0]

    def upload(self, release, name, data):
        url = f'https://uploads.github.com/repos/{REPOSITORY}/releases/{release["id"]}/assets?name={quote(name, safe="")}'
        return self.request(url, 'POST', data)[0]

    def require_repository(self):
        repo = self.api('')
        # User permission flags do not describe installation tokens; GitHub authorizes each write.
        if repo.get('full_name') != REPOSITORY:
            raise ValueError('GitHub repository identity mismatch')
