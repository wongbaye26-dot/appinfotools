(function () {
  function icon(id, cls) {
    return `<svg class="ic ${cls || ''}"><use href="#i-${id}"/></svg>`;
  }
  function build() {
    const body = document.body;
    const nav = body.dataset.nav || 'overview';
    const title = body.dataset.windowTitle || 'AppInfoTool — 应用包分析';
    const state = body.dataset.windowState || '本地分析 · 静态模式';
    const items = [
      ['overview', 'grid', '概览'],
      ['analysis', 'scan', '分析'],
      ['diff', 'compare', '版本对比'],
      ['install', 'phone', '安装'],
      ['settings', 'settings', '设置'],
    ];

    const titlebar = document.createElement('div');
    titlebar.className = 'titlebar';
    titlebar.innerHTML = `<div class="traffic"><i></i><i></i><i></i></div>
      <div class="window-title">${title}</div>
      <div class="window-state"><span class="dot-live"></span>${state}</div>`;

    const sidebar = document.createElement('aside');
    sidebar.className = 'sidebar';
    sidebar.innerHTML = `
      <div class="brand">
        <img src="../assets/logo.png" alt="AppInfoTool"/>
        <div><div class="brand-name">AppInfoTool</div><div class="brand-sub">Package Inspector</div></div>
      </div>
      <div class="command">${icon('search')}<span>快速打开或搜索…</span><span class="kbd">⌘ K</span></div>
      <div class="nav-label">工作区</div>
      <nav class="nav">
        ${items.map(([id, ic, label]) => `<a class="nav-item ${id === nav ? 'active' : ''}" href="#">
          ${icon(ic)}<span>${label}</span>
          ${id === 'analysis' ? '<span class="count">1</span>' : ''}
        </a>`).join('')}
      </nav>
      <div class="sidebar-spacer"></div>
      <div class="side-recent">
        <div class="mini-label">最近分析</div>
        <div class="side-file"><span class="file-dot">APK</span><span>Aurora Notes</span></div>
        <div class="side-file"><span class="file-dot">IPA</span><span>SUN</span></div>
        <div class="side-file muted"><span class="file-dot">—</span><span>打开文件后显示</span></div>
      </div>
      <div class="sidebar-footer">
        <span class="plat">${icon('android')}</span>
        <span class="plat">${icon('apple')}</span>
        <span class="ver">v2.10.6</span>
      </div>`;
    body.prepend(titlebar);
    body.insertBefore(sidebar, titlebar.nextSibling);
  }
  document.addEventListener('DOMContentLoaded', build);
})();
