(() => {
  const root = document.documentElement;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.add('loaded')));

  /* ---------- the headline is a tiny live Markdown editor ---------- */
  const words = [
    { t: 'Markdown', post: ',', b: true,  i: false, u: false },
    { t: 'rendered', post: '',  b: false, i: false, u: false },
    { t: 'while',    post: '',  b: false, i: false, u: false },
    { t: 'you',      post: '',  b: false, i: true,  u: false },
    { t: 'type.',    post: '',  b: false, i: false, u: false },
  ];
  let active = -1;
  const demo = document.getElementById('headline');
  const src = document.getElementById('src');
  const lines = [[0, 1], [2, 3, 4]];
  const chips = [...document.querySelectorAll('.chip')];

  const open = w => (w.u ? '<ins>' : '') + (w.b ? '**' : '') + (w.i ? '*' : '');
  const close = w => (w.i ? '*' : '') + (w.b ? '**' : '') + (w.u ? '</ins>' : '');
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  function render() {
    lines.forEach((ids, li) => {
      const el = demo.querySelector(`.line[data-line="${li}"]`);
      el.innerHTML = ids.map(id => {
        const w = words[id], on = id === active;
        const cls = ['w', w.b && 'b', w.i && 'i', w.u && 'u', on && 'active'].filter(Boolean).join(' ');
        const inner = on ? `<span class="mk">${esc(open(w))}</span>${w.t}<span class="mk">${esc(close(w))}</span>` : w.t;
        return `<span class="${cls}" data-w="${id}">${inner}</span>${w.post}`;
      }).join(' ');
    });
    src.textContent = lines.map(ids => ids.map(id => open(words[id]) + words[id].t + close(words[id]) + words[id].post).join(' ')).join('\n');
    const w = words[active < 0 ? 0 : active];
    chips.forEach(c => {
      const on = !!w[c.dataset.fmt];
      c.setAttribute('aria-pressed', on ? 'true' : 'false');
      c.querySelector('.chip-state').textContent = on ? 'on' : 'off';
    });
    demo.setAttribute('aria-label', words.map(x => x.t + x.post).join(' '));
  }

  function setActive(i) { active = Math.max(0, Math.min(words.length - 1, i)); render(); }
  function toggle(f) { const w = words[active < 0 ? 0 : active]; if (active < 0) active = 0; w[f] = !w[f]; render(); }

  demo.addEventListener('click', e => {
    const el = e.target.closest('.w'); if (!el) return;
    setActive(+el.dataset.w);
  });
  demo.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey) {
      const k = e.key.toLowerCase();
      if (['b', 'i', 'u'].includes(k)) { e.preventDefault(); toggle(k); }
      return;
    }
    if (e.key === 'ArrowRight') { e.preventDefault(); setActive(active + 1); }
    if (e.key === 'ArrowLeft') { e.preventDefault(); setActive(active < 0 ? 0 : active - 1); }
  });
  demo.addEventListener('focus', () => { if (active < 0) setActive(0); });
  chips.forEach(c => c.addEventListener('click', () => toggle(c.dataset.fmt)));
  render();

  /* ---------- command list ---------- */
  const rows = [...document.querySelectorAll('#rows li')];
  function openRow(li) {
    rows.forEach(r => { const on = r === li; r.classList.toggle('open', on); r.querySelector('.row').setAttribute('aria-expanded', on ? 'true' : 'false'); });
  }
  rows[0].classList.add('open');
  rows.forEach(li => li.querySelector('.row').addEventListener('click', () => openRow(li)));
  const find = document.getElementById('find'), none = document.getElementById('none');
  find.addEventListener('input', () => {
    const q = find.value.trim().toLowerCase();
    let shown = 0;
    rows.forEach(li => {
      const hit = !q || (li.dataset.k + ' ' + li.querySelector('.row-name').textContent).toLowerCase().includes(q);
      li.hidden = !hit; if (hit) shown++;
    });
    none.hidden = shown !== 0;
    const visible = rows.filter(r => !r.hidden);
    if (visible.length && !visible.some(r => r.classList.contains('open'))) openRow(visible[0]);
  });

  /* ---------- output index ---------- */
  const tabs = [...document.querySelectorAll('.names [role="tab"]')];
  function selectTab(t) {
    tabs.forEach(x => {
      const on = x === t;
      x.setAttribute('aria-selected', on ? 'true' : 'false'); x.tabIndex = on ? 0 : -1;
      document.getElementById(x.getAttribute('aria-controls')).hidden = !on;
    });
  }
  tabs.forEach((t, i) => {
    t.addEventListener('click', () => selectTab(t));
    t.addEventListener('keydown', e => {
      const n = e.key === 'ArrowDown' || e.key === 'ArrowRight' ? 1 : e.key === 'ArrowUp' || e.key === 'ArrowLeft' ? -1 : 0;
      if (n) { e.preventDefault(); const nx = tabs[(i + n + tabs.length) % tabs.length]; nx.focus(); selectTab(nx); }
    });
  });

  /* ---------- stages ---------- */
  const clauses = ['First, it opens rendered.', 'Click, and markers appear.', 'Tables turn back to pipes.', 'Last, plain Markdown on disk.'];
  const stage = document.getElementById('stage'), clause = document.getElementById('clause');
  const frags = [...document.querySelectorAll('#frag .f')], steps = [...document.querySelectorAll('.stages li')];
  function setStage(n) {
    clause.textContent = clauses[n];
    frags.forEach((f, i) => f.classList.toggle('on', i === n));
    steps.forEach((s, i) => s.classList.toggle('on', i === n));
    stage.parentElement.style.setProperty('--pn', n / 3);
  }
  stage.addEventListener('input', () => setStage(+stage.value));
  setStage(0);

  /* ---------- entrances ---------- */
  const targets = [...document.querySelectorAll('[data-in]')];
  if (reduce || !('IntersectionObserver' in window)) targets.forEach(t => t.classList.add('in'));
  else {
    const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
    targets.forEach((t, i) => { t.style.setProperty('--d', ((i % 3) * 70) + 'ms'); io.observe(t); });
  }
})();
