/*
 * V4 shell · Paper & Signal
 * UI prototype only.
 * Ported Lucian UX/UI Prompt #417 Collapsible sidebar
 * MIT License (c) 2026 Seokwoooo · https://lucianlabs.dev/uxui-prompt/#417
 */
(function () {
  var app = document.querySelector('.app');
  if (!app) return;
  var main = app.querySelector('.main');
  var nav = app.dataset.nav || 'overview';
  var crumb = app.dataset.crumb || 'WORKSPACE / OVERVIEW';
  var state = app.dataset.state || 'READY';
  var kind = app.dataset.stateKind || '';
  var title = app.dataset.windowTitle || 'AppInfoTool';

  var NAV = [
    ['overview', '概览', 'i-grid', '01-overview-empty.html'],
    ['analysis', '分析', 'i-scan', '03-analysis-apk.html'],
    ['diff', '版本对比', 'i-compare', '05-diff.html'],
    ['install', '安装', 'i-phone', '06-install.html'],
    ['settings', '设置', 'i-settings', '07-settings.html']
  ];

  var navHTML = NAV.map(function (n) {
    var active = n[0] === nav ? ' aria-current="page"' : '';
    var count = n[0] === 'analysis' ? '<span class="nav-count">1</span>' : '';
    return '<li><a class="nav-item" href="' + n[3] + '"' + active + '><svg class="ic nav-ic"><use href="#' + n[2] + '"/></svg><span class="nav-label">' + n[1] + '</span>' + count + '</a></li>';
  }).join('');

  var aside = document.createElement('aside');
  aside.className = 'sidebar';
  aside.setAttribute('aria-label', '主导航');
  aside.innerHTML =
    '<div class="brand">' +
      '<span class="brand-mark"><img src="../assets/logo.png" alt="" style="width:26px;height:26px;border-radius:8px;object-fit:cover"></span>' +
      '<span class="brand-text"><b>AppInfoTool</b><span>Package Inspector</span></span>' +
    '</div>' +
    '<button class="collapse-btn" type="button" aria-expanded="true" aria-label="收起侧栏"><svg viewBox="0 0 12 12"><path d="M7.5 2.5 4 6l3.5 3.5"/></svg></button>' +
    '<ul class="nav"><li class="nav-pill" aria-hidden="true"></li>' + navHTML + '</ul>' +
    '<div class="side-section">' +
      '<div class="side-label">最近分析 <span>LOCAL</span></div>' +
      '<div class="recent">' +
        '<div class="recent-item"><span class="recent-thumb">APK</span><span class="recent-meta"><b>Aurora Notes</b><small>3.20.0 · ANDROID</small></span></div>' +
        '<div class="recent-item"><span class="recent-thumb ipa">IPA</span><span class="recent-meta"><b>SUN</b><small>1.8.3 · IOS</small></span></div>' +
        '<div class="recent-item"><span class="recent-thumb" style="background:var(--surface-3);color:var(--ink-3)">—</span><span class="recent-meta"><b>打开文件后显示</b><small>最多 10 条</small></span></div>' +
      '</div>' +
    '</div>' +
    '<div class="side-grow"></div>' +
    '<div class="side-foot">' +
      '<div class="local"><i class="local-dot"></i><span>LOCAL ONLY</span><span style="margin-left:auto">NO UPLOAD</span></div>' +
      '<div class="row"><span>STATIC INSPECTOR</span><span>v2.10.6</span></div>' +
    '</div>';

  app.insertBefore(aside, main);

  var top = document.createElement('header');
  top.className = 'topbar';
  var crumbParts = crumb.split('/').map(function (s) { return s.trim(); }).filter(Boolean);
  var crumbHTML = crumbParts.map(function (s, i) {
    if (i === crumbParts.length - 1) return '<b>' + s + '</b>';
    return '<span>' + s + '</span><span class="sep">/</span>';
  }).join('');
  top.innerHTML =
    '<div class="crumbs">' + crumbHTML + '</div>' +
    '<div class="search"><svg class="ic"><use href="#i-search"/></svg><span>搜索包名、规则、报告…</span><span class="kbd"><kbd>⌘</kbd><kbd>K</kbd></span></div>' +
    '<div class="top-actions">' +
      '<span class="state-pill ' + kind + '"><i class="state-dot"></i>' + state + '</span>' +
      '<span class="mono" style="font-size:8px;color:var(--ink-3);letter-spacing:.04em">v2.10.6</span>' +
      '<button class="btn grad" type="button"><svg class="ic"><use href="#i-upload"/></svg>打开安装包</button>' +
      '<span class="avatar">WB</span>' +
    '</div>';
  main.insertBefore(top, main.firstChild);

  // Sidebar collapse + sliding highlight, ported from #417.
  var pill = aside.querySelector('.nav-pill');
  var items = Array.prototype.slice.call(aside.querySelectorAll('.nav-item'));
  var active = aside.querySelector('.nav-item[aria-current="page"]') || items[0];
  function slide() {
    if (!active) return;
    pill.style.setProperty('--py', active.parentNode.offsetTop + 'px');
  }
  items.forEach(function (a) {
    a.addEventListener('keydown', function (e) {
      var i = items.indexOf(a);
      var to = e.key === 'ArrowDown' ? i + 1 : e.key === 'ArrowUp' ? i - 1 : null;
      if (to === null || !items[to]) return;
      e.preventDefault();
      items[to].focus();
    });
    a.addEventListener('click', function () {
      active.removeAttribute('aria-current');
      active = a;
      a.setAttribute('aria-current', 'page');
      slide();
    });
  });
  var tg = aside.querySelector('.collapse-btn');
  tg.addEventListener('click', function () {
    var collapsed = app.classList.toggle('is-collapsed');
    tg.setAttribute('aria-expanded', String(!collapsed));
    tg.setAttribute('aria-label', collapsed ? '展开侧栏' : '收起侧栏');
    setTimeout(slide, 620);
  });
  pill.style.transition = 'none';
  slide();
  void pill.offsetWidth;
  pill.style.transition = '';
  window.addEventListener('resize', slide);

  // Sliding pill tabs, ported from #039. Every .tabs component on the page.
  Array.prototype.forEach.call(document.querySelectorAll('.tabs'), function (tabs) {
    var pillTab = tabs.querySelector('.tab-pill');
    var btns = Array.prototype.slice.call(tabs.querySelectorAll('.tab'));
    if (!pillTab || !btns.length) return;
    function move(animate) {
      var t = tabs.querySelector('.tab[aria-selected="true"]') || btns[0];
      if (!animate) pillTab.style.transition = 'none';
      pillTab.style.setProperty('--x', t.offsetLeft + 'px');
      pillTab.style.setProperty('--w', t.offsetWidth + 'px');
      if (!animate) { void pillTab.offsetWidth; pillTab.style.transition = ''; }
    }
    btns.forEach(function (t, i) {
      t.addEventListener('click', function () {
        btns.forEach(function (x, k) { x.setAttribute('aria-selected', String(k === i)); x.tabIndex = k === i ? 0 : -1; });
        move(true);
      });
      t.addEventListener('keydown', function (e) {
        var d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
        if (!d) return;
        e.preventDefault();
        var n = (i + d + btns.length) % btns.length;
        btns[n].click();
        btns[n].focus();
      });
    });
    btns.forEach(function (t, i) { t.tabIndex = i === 0 ? 0 : -1; });
    move(false);
  });
})();
