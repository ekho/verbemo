// Run against a local preview: VERBEMO_PREVIEW_URL=http://127.0.0.1:8765 node tests/browser.cjs
// Requires Playwright and its Chromium browser.
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

(async () => {
    const base = process.env.VERBEMO_PREVIEW_URL || 'http://127.0.0.1:8765';
    const browser = await chromium.launch({ headless: true });
    try {
        for (const [platform, userAgent] of [
            ['mac', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'],
            ['mac', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1'],
            ['windows', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36'],
        ]) {
            for (const [language, colorScheme] of ['en', 'ru'].flatMap(lang => ['light', 'dark'].map(theme => [lang, theme]))) {
                const context = await browser.newContext({ userAgent, colorScheme, deviceScaleFactor: platform === 'windows' || userAgent.includes('iPhone') ? 3 : 2,
                    viewport: userAgent.includes('iPhone') ? { width: 390, height: 844 } : { width: 1280, height: 900 } });
                const page = await context.newPage();
                const telemetry = [];
                page.on('request', request => {
                    const url = new URL(request.url());
                    if (url.pathname === '/m' || /stats|analytics|goatcounter/i.test(url.hostname)) telemetry.push(request.url());
                });
                await page.goto(`${base}/${language === 'en' ? '' : 'ru/'}`);
                assert.match(await page.title(), /Verbemo/);
                for (const platform of ['macOS', 'Windows']) {
                    const links = page.locator(`a[data-download="${platform}"]`);
                    assert.equal(await links.count(), 2);
                    assert.equal(await links.first().getAttribute('href'), 'https://github.com/ekho/verbemo/releases');
                    await links.first().evaluate(el => el.addEventListener('click', e => e.preventDefault()));
                    await links.first().click();
                }
                await page.waitForTimeout(100);
                assert.deepEqual(telemetry, [], `${language}: no telemetry on page view or clicks`);
                assert.equal(await page.locator('picture, img[data-windows-src]').count(), 0, 'old screenshots stay inactive until final capture');
                assert.equal(await page.locator('img').evaluateAll(images => images.every(img => img.complete && img.naturalWidth > 0)), true);
                assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true,
                    `${language}/${platform}: no horizontal page overflow`);
                await context.close();
            }
        }
        console.log('PASS: macOS/iPhone/Windows layouts, own release links, no telemetry; EN/RU light/dark');
    } finally {
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
