#!/usr/bin/env python3
"""Automated checks for the bilingual Verbemo landing page.

Observable structure and behaviour only: English is the default, Russian lives
at /ru/, language metadata and switching are reciprocal, releases are real,
resources stay local, and accessibility plus colour/motion preferences hold.
"""

import hashlib
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

LANDING = Path(__file__).resolve().parent.parent
ROOT = LANDING.parent
EN_INDEX = LANDING / "index.html"
RU_INDEX = LANDING / "ru" / "index.html"
EN_PRIVACY = LANDING / "privacy" / "index.html"
RU_PRIVACY = LANDING / "ru" / "privacy" / "index.html"
failures = []


def check(name, ok, detail=""):
    mark = "ok  " if ok else "FAIL"
    print(f"{mark} {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.html_lang = None
        self.h1_count = 0
        self.title = ""
        self._in_title = False
        self.meta_description = None
        self.links = []
        self.anchors = []
        self.resources = []
        self.imgs = []
        self.forms = []
        self.script_srcs = []
        self.inline_scripts = []
        self._in_script = False
        self.onclick_count = 0
        self.positive_tabindex = 0
        self.stylesheets = []
        self.alternates = []
        self.canonicals = []
        self.meta = {}

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if any(k.startswith("on") for k in a):
            self.onclick_count += 1
        ti = a.get("tabindex")
        if ti and ti.lstrip("-").isdigit() and int(ti) > 0:
            self.positive_tabindex += 1
        if tag == "html":
            self.html_lang = a.get("lang")
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content")
            if a.get("name") == "description":
                self.meta_description = a.get("content")
        elif tag == "a":
            self.links.append(a.get("href", ""))
            self.anchors.append(a)
        elif tag == "img":
            self.imgs.append(a)
            if a.get("src"):
                self.resources.append(("img", a["src"]))
        elif tag == "source":
            for part in a.get("srcset", "").split(","):
                url = part.strip().split()[0] if part.strip() else ""
                if url:
                    self.resources.append(("source", url))
        elif tag == "link":
            href = a.get("href", "")
            rel = a.get("rel", "").split()
            if "stylesheet" in rel:
                self.stylesheets.append(href)
            if any(item in rel for item in ("stylesheet", "icon", "apple-touch-icon")):
                self.resources.append(("link", href))
            if "alternate" in rel:
                self.alternates.append((a.get("hreflang"), href))
            if "canonical" in rel:
                self.canonicals.append(href)
        elif tag == "script":
            self._in_script = True
            if a.get("src"):
                self.script_srcs.append(a["src"])
                self.resources.append(("script", a["src"]))
        elif tag == "form":
            self.forms.append(a.get("action", ""))

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "script":
            self._in_script = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data
        if self._in_script:
            self.inline_scripts.append(data)


def parse_page(path):
    html = path.read_text(encoding="utf-8")
    parser = PageParser()
    parser.feed(html)
    return html, parser


def is_external(url):
    s = urlsplit(url)
    return s.scheme in ("http", "https") or url.startswith("//")


def resolves_locally(page_path, url):
    s = urlsplit(url)
    if s.scheme or url.startswith("//"):
        return False
    path = unquote(s.path)
    if not path:
        return True
    if path.startswith("/"):
        return (LANDING / path.lstrip("/")).is_file()
    return (page_path.parent / path).resolve().is_file()


def valid_download_policy(pages):
    """Both languages use Releases, or one exact own common-release asset set.

    The updater verifies release evidence before writing; this offline gate
    checks the resulting public URL policy without making network requests.
    """
    releases = "https://github.com/ekho/verbemo/releases"
    if len(pages) != 2:
        return False
    marked_pages = [[anchor for anchor in page.anchors if "data-download" in anchor] for page in pages]
    if any(len(anchors) != 4 or any(sum(anchor.get("data-download") == platform for anchor in anchors) != 2
                                  for platform in ("macOS", "Windows")) for anchors in marked_pages):
        return False
    first = next(anchor.get("href", "") for anchor in marked_pages[0] if anchor["data-download"] == "macOS")
    expected = dict.fromkeys(("macOS", "Windows"), releases)
    if first != releases:
        component = r"(?:0|[1-9][0-9]*)"
        version = rf"({component}\.{component}\.{component})"
        match = re.fullmatch(re.escape(releases) + rf"/download/verbemo-v{version}/Verbemo-\1-macos-universal\.dmg", first)
        if not match:
            return False
        version = match[1]
        base = f"{releases}/download/verbemo-v{version}/Verbemo-{version}-"
        expected = {"macOS": base + "macos-universal.dmg", "Windows": base + "windows-x64-Setup.exe"}
    return all(anchor.get("href") == expected[anchor["data-download"]]
               for anchors in marked_pages for anchor in anchors)


def main():
    download_pages = []
    for relative, language, alternate in (("index.html", "en", "/ru/"), ("ru/index.html", "ru", "/"),
                                           ("privacy/index.html", "en", "/ru/privacy/"), ("ru/privacy/index.html", "ru", "/privacy/")):
        path = LANDING / relative
        html, page = parse_page(path)
        check(f"{relative}: product and language", "Verbemo" in page.title and page.html_lang == language)
        check(f"{relative}: one h1 and description", page.h1_count == 1 and bool(page.meta_description))
        check(f"{relative}: own source/support", any(url.startswith("https://github.com/ekho/verbemo") for url in page.links))
        check(f"{relative}: reciprocal language link", alternate in page.links)
        check(f"{relative}: no unconfigured public domain", not page.canonicals and all(not is_external(url) for _, url in page.alternates))
        check(f"{relative}: local resources", all(not is_external(url) and resolves_locally(path, url) for _, url in page.resources))
        check(f"{relative}: accessible images", all("alt" in img and "width" in img and "height" in img for img in page.imgs))
        check(f"{relative}: no inline scripts/handlers or positive tabindex", not "".join(page.inline_scripts).strip() and not page.onclick_count and not page.positive_tabindex)
        check(f"{relative}: no forms", not page.forms)
        check(f"{relative}: shared local script", page.script_srcs == ["/script.js"])
        check(f"{relative}: no inherited signing claims", not re.search(r"Signed by Apple|подписан Apple|apps are signed", html, re.I))
        if "privacy" not in relative:
            download_pages.append(page)
            check(f"{relative}: no historical screenshots", not any("/shots/" in url for _, url in page.resources) and "data-windows-" not in html)
    check("EN/RU: consistent own Releases or common versioned platform assets", valid_download_policy(download_pages))
    css = (LANDING / "style.css").read_text()
    check("CSS preserves motion and color preferences", "prefers-reduced-motion" in css and "prefers-color-scheme: dark" in css)
    check("CSS has no external imports", not re.search(r"url\(\s*['\"]?(https?:)?//|@import\s+['\"]?(https?:)?//", css))
    script = (LANDING / "script.js").read_text()
    check("site has no analytics transport", not re.search(r"fetch\(|XMLHttpRequest|new\s+Image|sendBeacon|location\.origin", script))
    check("no inherited server or appcast", not (LANDING / "appcast.xml").exists() and not list((LANDING / "deploy").rglob("*.conf")))
    check("robots/sitemap wait for real domain", "https://" not in (LANDING / "robots.txt").read_text() and "<loc>" not in (LANDING / "sitemap.xml").read_text())
    print(f"{len(failures)} failed" if failures else "PASS: all landing checks")
    return bool(failures)

if __name__ == "__main__":
    sys.exit(main())
