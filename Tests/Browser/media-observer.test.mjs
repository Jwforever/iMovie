import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { chromium } from '@playwright/test';

test('media observer detects DOM, fetch and iframe media and ignores unsafe schemes', async () => {
  const script = await readFile(new URL('../../Resources/media-observer.js', import.meta.url), 'utf8');
  const server = createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': request.url.endsWith('.m3u8') ? 'application/vnd.apple.mpegurl' : 'text/html' });
    if (request.url.endsWith('.m3u8')) response.end('#EXTM3U\n#EXT-X-ENDLIST\n');
    else response.end('<!doctype html><html><head><title>Fixture</title></head><body></body></html>');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    browser = await chromium.launch({ headless: true, ...(process.env.IMOVIE_BROWSER_CHANNEL ? { channel: process.env.IMOVIE_BROWSER_CHANNEL } : {}) });
    const page = await browser.newPage();
    const events = [];
    await page.exposeFunction('nativeMedia', value => events.push(value));
    await page.addInitScript(() => {
      window.webkit = { messageHandlers: { iMovieMedia: { postMessage: value => window.nativeMedia(value) } } };
    });
    await page.addInitScript(script);
    await page.goto(origin);
    await page.evaluate(async origin => {
      const source = document.createElement('source');
      source.src = origin + '/direct.mp4';
      document.body.append(source);
      const unsafe = document.createElement('source');
      unsafe.src = 'file:///private/no.mp4';
      document.body.append(unsafe);
      await fetch(origin + '/playlist.m3u8');
      await fetch(origin + '/playlist.m3u8');
      const frame = document.createElement('iframe');
      frame.src = origin + '/frame';
      document.body.append(frame);
    }, origin);
    await page.waitForFunction(() => document.querySelector('iframe')?.contentDocument?.readyState === 'complete');
    const frame = page.frames().find(frame => frame.url().endsWith('/frame'));
    assert.ok(frame);
    await frame.evaluate(origin => {
      const video = document.createElement('video');
      video.src = origin + '/embedded.mp4';
      document.body.append(video);
    }, origin);
    await page.waitForTimeout(500);
    assert.ok(events.some(event => event.url === origin + '/direct.mp4'));
    assert.ok(events.some(event => event.url === origin + '/playlist.m3u8'));
    assert.ok(events.some(event => event.url === origin + '/embedded.mp4' && event.page.endsWith('/frame')));
    assert.equal(events.filter(event => event.url === origin + '/playlist.m3u8').length, 1);
    assert.equal(events.filter(event => event.url.startsWith('file:')).length, 0);
    assert.ok(events.every(event => typeof event.userAgent === 'string'));
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
});
