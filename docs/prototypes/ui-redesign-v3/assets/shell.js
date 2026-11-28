(function () {
  function icon(id, cls) {
    return `<svg class="ic ${cls || ''}"><use href="#i-${id}"/></svg>`;
  }
  function build() {
    const body = document.body;
    const nav = body.dataset.nav || 'overview';
    const title = body.dataset.windowTitle || 'AppInfoTool — Signal Room';
    const crumb = body.dataset.crumb || 'WORKSPACE / OVERVIEW';
    const state = body.dataset.state || 'LOCAL / STATIC';
    const stateKind = body.dataset.stateKind || '';
    const statusLeft = body.dataset.statusLeft || 'STATIC ONLY · NO SAMPLE EXECUTION';
    const statusRight = body.dataset.statusRight || 'LOCAL CACHE · NO UPLOAD';
    const items = [
      ['overview', 'grid', '概览'],
      ['analysis', 'scan', '分析'],
      ['diff', 'compare', '对比'],
      ['install', 'phone', '安装'],
      ['settings', 'sliders', '设置'],
    ];

    const topbar = document.createElement('header');
    topbar.className = 'topbar';
    topbar.innerHTML = `
      <div class="brand">
        <img src="../assets/logo.png" alt="AppInfoTool"/>
        <div><div class="brand-name">APPINFOTOOL</div><div class="brand-sub">Signal Room / v3</div></div>
      </div>
      <div class="topbar-main">
        <div class="search">${icon('search')}<span>搜索包名、规则、文件…</span><span class="kbd">⌘ K</span></div>
        <div class="crumbs">${crumb.split(' / ').map((s, i) => i === 0 ? s : (i === crumb.split(' / ').length - 1 ? `<b>${s}</b>` : s)).join('<span style="color:#33424c">/</span>')}</div>
        <div class="top-actions">
          <span class="state-pill"><span class="dot ${stateKind}"></span>${state}</span>
          <span class="state-pill">v2.10.6</span>
          <button class="btn primary"><span>打开安装包</span></button>
        </div>
      </div>`;

    const rail = document.createElement('aside');
    rail.className = 'rail';
    rail.innerHTML = `
      ${items.map(([id, ic, label]) => `<a class="rail-btn ${id === nav ? 'active' : ''}" href="#" title="${label}">
        ${icon(ic)}<span>${label}</span>
      </a>`).join('')}
      <div class="rail-spacer"></div>
      <div class="rail-sep"></div>
      <a class="rail-btn" href="#" title="诊断">${icon('terminal')}<span>日志</span></a>
      <div class="rail-avatar">WB</div>`;

    const statusbar = document.createElement('footer');
    statusbar.className = 'statusbar';
    statusbar.innerHTML = `<span>${statusLeft}</span><span class="spacer"></span><span>${statusRight}</span><span>1440×1024</span><span>v2.10.6</span>`;

    body.prepend(topbar);
    body.insertBefore(rail, topbar.nextSibling);
    body.appendChild(statusbar);
    document.title = title;
  }
  document.addEventListener('DOMContentLoaded', build);
})();
