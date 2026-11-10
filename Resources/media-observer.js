(() => {
  'use strict';
  if (window.__iMovieObserverInstalled) return;
  window.__iMovieObserverInstalled = true;
  const seen = new Set();
  const send = value => {
    if (typeof value !== 'string' || !value || value.length > 16000) return;
    let url;
    try { url = new URL(value, location.href); } catch { return; }
    if (!['http:', 'https:'].includes(url.protocol)) return;
    if (!/\.(?:m3u8|mp4|m4v|mov|m4a|mp3|aac)(?:$|[?#])/i.test(url.href) && !/\/m3u8(?:$|[?#])/i.test(url.pathname)) return;
    if (seen.has(url.href)) return;
    seen.add(url.href);
    try {
      window.webkit.messageHandlers.iMovieMedia.postMessage({
        url: url.href,
        page: location.href,
        userAgent: navigator.userAgent,
        referrerPolicy: document.querySelector('meta[name="referrer"]')?.content || '',
        title: document.title || ''
      });
    } catch { }
  };
  const scan = () => {
    document.querySelectorAll('video,audio,source').forEach(element => {
      send(element.currentSrc);
      send(element.getAttribute('src'));
      send(element.getAttribute('video-src'));
    });
    document.querySelectorAll('[video-src]').forEach(element => send(element.getAttribute('video-src')));
    performance.getEntriesByType('resource').forEach(entry => send(entry.name));
  };
  const originalFetch = window.fetch;
  if (originalFetch) window.fetch = function (input, options) {
    send(typeof input === 'string' ? input : input?.url);
    return originalFetch.apply(this, arguments).then(response => { send(response.url); return response; });
  };
  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) { send(url); return originalOpen.apply(this, arguments); };
  try {
    const observer = new PerformanceObserver(list => list.getEntries().forEach(entry => send(entry.name)));
    observer.observe({ entryTypes: ['resource'] });
  } catch { }
  const mutations = new MutationObserver(scan);
  const start = () => {
    scan();
    if (document.documentElement) mutations.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'video-src'] });
  };
  if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start, { once: true });
  document.addEventListener('loadedmetadata', scan, true);
  const timer = setInterval(scan, 1500);
  setTimeout(() => clearInterval(timer), 120000);
})();
