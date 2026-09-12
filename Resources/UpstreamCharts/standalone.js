'use strict';
(function (root) {
  const api = root.TokenMonitorUsageCharts;
  const $ = id => document.getElementById(id);
  const amount = v => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= Number.MAX_SAFE_INTEGER ? v : null;
  const day = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) && Number.isFinite(Date.parse(v + 'T00:00:00Z')) && new Date(v + 'T00:00:00Z').toISOString().slice(0, 10) === v;
  // Do not display raw metadata. Engine remains responsible for sanitizing the full response.
  const publicText = v => String(v ?? '').replace(/(?:https?:\/\/\S+|\b[^\s@]+@[^\s@]+\b|(?:\/(?:Users|home|private|tmp|var|Volumes|opt)\/|[A-Z]:\\)\S*|\b(?:sk-|Bearer\s+)\S+)/gi, t('[已隐藏]', '[redacted]')).slice(0,200);
  const dimension = (row, key) => {
    const map = row && row[key];
    if (!map || typeof map !== 'object' || Array.isArray(map)) return null;
    const entries = Object.entries(map).filter(([k]) => !['__proto__', 'constructor', 'prototype'].includes(k));
    return entries.length ? entries : null;
  };
  let state, installedSnapshot, language = 'zh';
  const t = (zh, en) => language === 'en' ? en : zh;
  const missing = () => t('未提供', 'Not provided');
  const number = v => amount(v) === null ? missing() : v.toLocaleString(language === 'en' ? 'en-US' : 'zh-CN');
  const labelStatus = s => s === 'known' ? t('已确认', 'known') : s === 'partial' ? t('部分覆盖', 'partial coverage') : t('完整性未确认', 'completeness unconfirmed');
  const labels = {overview:['概览','Overview'],trends:['趋势','Trends'],details:['明细','Details'],group:['分组','Group'],from:['起始日期','From'],to:['结束日期','To'],date:['日期','Date'],period:['期间','Period'],day:['所选日','Selected day'],today:['今天','Today'],month:['本月','This month'],allTime:['全部时间','All time'],client:['工具','Tool'],model:['模型','Model']};
  function localize() {
    document.documentElement.lang = language;
    document.querySelector('nav').setAttribute('aria-label', t('用量视图','Usage view'));
    document.querySelectorAll('[data-mode], [data-label], option').forEach(el => {
      const key = el.getAttribute('data-mode') || el.getAttribute('data-label') || el.value;
      if (labels[key]) el.textContent = t(...labels[key]);
    });
  }
  function cost(value, ...contexts) {
    // Only cost-specific evidence applies; token/day status is not price evidence.
    const coverage = contexts.map(x => x?.coverage?.cost ?? x?.costCoverage).find(x => x != null) ?? state.input.coverage?.cost;
    const available = amount(value) !== null && (coverage === 'known' || coverage === 'partial');
    const label = coverage === 'partial' && available ? t('已观察费用（美元）','Observed cost (USD)') : t('费用（美元）','Cost (USD)');
    return `${label}: ${available ? number(value) : missing()} · ${available && coverage === 'known' ? labelStatus('known') : labelStatus('unknown')}`;
  }
  function costContext(period, key) {
    const coverage = state.input.coverage;
    const scoped = period === 'day' ? (Array.isArray(coverage?.days) ? coverage.days.find(x => x?.date === key) : coverage?.days?.[key]) : coverage?.periods?.[period];
    return {coverage:{cost:scoped?.cost ?? scoped?.coverage?.cost}};
  }
  function normalize(input, annotations) {
    const legacy = Array.isArray(input);
    if (!legacy && (!input || input.schemaVersion !== 1 || !input.payload)) throw Error(t('仪表盘数据格式无效','Invalid dashboard schema'));
    const payload = legacy ? {} : input.payload;
    const canonical = payload.aggregate ?? payload.usage ?? {};
    const history = canonical.history ?? payload.history ?? payload.usage?.history;
    const rows = legacy ? input : history?.daily;
    if (rows != null && !Array.isArray(rows)) throw Error(t('历史记录无效','Invalid history'));
    if ((rows || []).length > 10000) throw Error(t('历史记录过大','History too large'));
    const byDate = new Map();
    for (const row of rows || []) {
      if (!row || !day(row.date)) continue;
      if (byDate.has(row.date)) throw Error(t('汇总日期重复','Duplicate canonical date'));
      byDate.set(row.date, row);
    }
    const rawCoverage = legacy ? [] : input.coverage?.days;
    const dayCoverage = Array.isArray(rawCoverage) ? rawCoverage : rawCoverage && typeof rawCoverage === 'object' ? Object.entries(rawCoverage).map(([date,value]) => ({date,status:value?.status})) : [];
    const coverage = new Map(dayCoverage.filter(x => x && day(x.date)).map(x => [x.date, x.status]));
    let end = canonical.periodWindows?.today?.key ?? payload.usage?.periodWindows?.today?.key;
    if (!day(end) && !legacy && typeof input.collectedAt === 'string' && typeof input.timezone === 'string') {
      const instant = new Date(input.collectedAt);
      if (Number.isFinite(instant.getTime())) {
        const parts = new Intl.DateTimeFormat('en-US', {timeZone: input.timezone, year:'numeric', month:'2-digit', day:'2-digit'}).formatToParts(instant);
        const get = type => parts.find(p => p.type === type).value;
        end = `${get('year')}-${get('month')}-${get('day')}`;
      }
    }
    if (!day(end)) end = [...byDate.keys()].sort().at(-1);
    if (!day(end)) throw Error(t('统计日期未提供','Statistics day unavailable'));
    const resets = new Map();
    for (const r of (annotations || []).slice(0, 500)) {
      if (r && day(r.date) && ['regular', 'banked'].includes(r.kind)) {
        resets.set(r.date, [...(resets.get(r.date) || []), `${r.kind === 'regular' ? t('公开公告 · 常规重置','Public regular reset') : t('公开公告 · 储备重置','Public banked reset')}: ${publicText(r.text)}`]);
      }
    }
    return {input, canonical, history, byDate, coverage, resets, end, legacy};
  }
  function status(key) {
    const row = state.byDate.get(key), tokens = amount(row?.tokens);
    const coverage = state.coverage.get(key);
    if (tokens === null || (!state.legacy && coverage !== 'known' && coverage !== 'partial')) return 'unknown';
    return coverage === 'partial' ? 'partial' : 'known';
  }
  function describe(key) {
    const row = state.byDate.get(key), value = amount(row?.tokens), c = status(key);
    const lines = [`${key} · ${value === null ? t('Token 未提供','Tokens unavailable') : number(value) + ' Token'} · ${labelStatus(c)}${value !== null && c !== 'known' ? t(' · 已观察值，完整性未确认',' · observed value, completeness unconfirmed') : ''}`, cost(row?.costUsd ?? row?.cost, row, costContext('day', key))];
    for (const [field, label] of [['perClient',t('工具','Tools')],['perModel',t('模型','Models')]]) {
      const entries = dimension(row, field);
      lines.push(`${label}: ` + (entries ? entries.slice(0,30).map(([k,v]) => `${publicText(k)}: ${number(v?.tokens)}`).join(', ') + omitted(entries.length,30) : missing()));
    }
    return [...lines, ...(state.resets.get(key) || [])].join('\n');
  }
  function omitted(count, limit) { return count > limit ? t(`；另有 ${count-limit} 项未显示`, `; ${count-limit} more entries omitted`) : ''; }
  const fields = [['inputTokens','输入 Token','Input tokens'],['outputTokens','输出 Token','Output tokens'],['cacheReadTokens','缓存读取 Token','Cache read tokens'],['cacheWriteTokens','缓存写入 Token','Cache write tokens'],['reasoningTokens','推理 Token','Reasoning tokens'],['unclassifiedTokens','未分类 Token','Unclassified tokens'],['messageCount','消息数','Message count']];
  function details() {
    const period = $('period').value || 'day';
    const data = period === 'day' ? state.byDate.get(state.selected) : (state.canonical.periods ? state.canonical.periods[period] : state.canonical[period]);
    const box = $('dimensions'); box.textContent = '';
    const add = (tag, text, parent = box) => { const el = document.createElement(tag); el.textContent = text; parent.appendChild(el); return el; };
    add('p', period === 'day' ? describe(state.selected) : `${t(...labels[period])} · ${t('已提供 Token 值','Supplied token value')}: ${number(data?.totalTokens)} · ${t('期间完整性未确认','Period completeness unconfirmed')}\n${cost(data?.costUsd ?? data?.cost, data, costContext(period, state.selected))}`);
    add('p', fields.map(([key,zh,en]) => `${t(zh,en)}: ${number(data?.[key])}`).join(' · '));
    for (const [key,zh,en,daily,prefix] of [['clients','工具','Tools','perClient','client'],['models','模型','Models','perModel','model'],['sessions','会话','Sessions','sessions'],['projects','项目','Projects','projects'],['accounts','账号','Accounts','perAccount']]) {
      add('h3', t(zh,en));
      const entries = dimension(data, period === 'day' ? daily : key);
      if (!entries) { add('p',missing()); continue; }
      const table = add('table','');
      const head = add('tr','',table);
      for (const title of [t('名称 / 标识','Name / ID'),'Token',t('费用及属性','Cost and properties')]) add('th',title,head);
      for (const [id,value] of entries.slice(0,40)) {
        const obj = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
        const row = add('tr','',table);
        add('td',publicText(typeof obj.label === 'string' && obj.label ? obj.label : id),row);
        add('td',number(typeof value === 'number' ? value : obj.totalTokens ?? obj.tokens),row);
        const attrs = [cost(prefix && period !== 'day' ? data?.[prefix+'Costs']?.[id] : obj.costUsd ?? obj.cost, obj, data, costContext(period, state.selected))];
        for (const [field,zh,en] of fields) {
          const suffix = {outputTokens:'Outputs',cacheReadTokens:'CacheReads',cacheWriteTokens:'CacheWrites',unclassifiedTokens:'UnclassifiedTokens'}[field];
          attrs.push(`${t(zh,en)}: ${number(prefix && period !== 'day' && suffix ? data?.[prefix+suffix]?.[id] : obj[field])}`);
        }
        if (key === 'sessions' || key === 'projects' || key === 'accounts') {
          for (const [field,zh,en] of [['client','工具','Tool'],['sessionId','会话标识','Session ID'],['projectId','项目标识','Project ID'],['projectLabel','项目名称','Project label']]) {
            attrs.push(`${t(zh,en)}: ${typeof obj[field] === 'string' && obj[field] ? publicText(obj[field]) : missing()}`);
          }
          for (const [field,zh,en] of [['models','模型','Models'],['clients','工具','Tools']]) {
            const sub = dimension(obj,field);
            attrs.push(`${t(zh,en)}: ${sub ? sub.slice(0,20).map(([k,v]) => `${publicText(k)}: ${number(v)}`).join(', ') + omitted(sub.length,20) : missing()}`);
          }
        }
        add('td',attrs.join(' · '),row);
      }
      add('p',omitted(entries.length,40));
    }
  }
  function select(key) {
    if (!day(key) || key > state.end) { $('selection').textContent = t('日期无效或晚于统计日期','Invalid date or after statistics date'); return; }
    state.selected = key; $('date').value = key;
    $('selection').textContent = describe(key); details();
    const month = key.slice(0,7);
    const cells = state.calendar.cells.filter(c => c.date.startsWith(month));
    const known = cells.filter(c => status(c.date) === 'known');
    const values = cells.map(c => amount(state.byDate.get(c.date)?.tokens)).filter(v => v !== null);
    const sum = values.reduce((a,b) => a+b, 0);
    $('month').textContent = `${month}: ${values.length ? number(sum) : missing()} ${t('已观察 Token','observed tokens')} · ${known.length}/${cells.length} ${t('天已确认','days known')}${known.length !== cells.length ? t(' · 部分或未知覆盖，完整性未确认',' · partial/unknown coverage, completeness unconfirmed') : ''}`;
  }
  function bindDate(element, key) {
    element.setAttribute('tabindex','0'); element.setAttribute('role','button');
    element.setAttribute('aria-label',describe(key));
    element.addEventListener('click', () => select(key));
    element.addEventListener('focus', () => { $('selection').textContent = describe(key); });
    element.addEventListener('mouseenter', () => { $('selection').textContent = describe(key); });
    element.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(key); } });
  }
  function bars() {
    const field = $('group').value === 'model' ? 'perModel' : 'perClient';
    const start = $('from').value, end = $('to').value;
    if (!day(start) || !day(end) || start > end || end > state.end) { $('bars').textContent = t('日期范围无效','Invalid date range'); $('legend').textContent = ''; return; }
    const available = [...state.byDate.values()].filter(r => r.date >= start && r.date <= end).sort((a,b) => a.date.localeCompare(b.date));
    const rows = available.filter(r => dimension(r, field)?.some(([,v]) => amount(v?.tokens) !== null)).map(r => ({date:r.date, [field]:Object.fromEntries(dimension(r, field).filter(([,v]) => amount(v?.tokens) !== null).map(([k,v]) => [k,{tokens:v.tokens}]))}));
    if (!rows.length) { $('bars').textContent = t('此范围未提供该维度','Dimension unavailable in this range'); $('legend').textContent = t('无法从每日总量推断模型或工具分组。','No model/tool grouping inferred from daily totals.'); return; }
    const model = api.dailyBarsChart(rows,{width:650,height:150,stackBy:$('group').value,metric:'tokens'});
    const colorFor = k => `hsl(${(model.keys.indexOf(k)*67+205)%360},65%,52%)`;
    $('bars').innerHTML = api.barsChartSvg(model,{colorFor,titleOf:b => describe(b.label),axisLabel:b => b.label.slice(5),yTicks:3});
    $('legend').textContent = `${start} – ${end} · ${t('已观察 Token；未提供的维度已略过，完整性未确认','observed tokens; unavailable dimensions omitted, completeness unconfirmed')}\n`;
    for (const k of model.keys) { const item = document.createElement('span'); item.textContent = `● ${publicText(k)}  `; item.style.color = colorFor(k); $('legend').appendChild(item); }
    $('bars').querySelectorAll('[data-i]').forEach(el => bindDate(el,rows[Number(el.getAttribute('data-i'))].date));
  }
  function mode(name) {
    state.mode = name;
    for (const key of ['overview','trends','details']) $(key).hidden = key !== name;
    document.querySelectorAll('[data-mode]').forEach(el => el.setAttribute('aria-pressed',String(el.getAttribute('data-mode') === name)));
    if (name === 'trends') bars();
  }
  root.__renderTrend = function (input, options = {}) {
    language = options.language === 'en' ? 'en' : 'zh'; localize();
    // Native sends the bounded JSON once per snapshot/navigation. Presentation
    // updates carry only its identity and options, reusing this realm's object.
    const snapshotID = options.snapshotID;
    if (snapshotID != null && (typeof snapshotID !== 'string' || !snapshotID || snapshotID.length > 128)) throw Error(t('快照标识无效','Invalid snapshot identity'));
    if (snapshotID != null && input === null) {
      if (installedSnapshot?.id !== snapshotID) throw Error(t('图表快照尚未加载','Dashboard snapshot unavailable'));
      input = installedSnapshot.input;
    } else if (snapshotID != null && typeof input !== 'string') {
      throw Error(t('仪表盘数据格式无效','Invalid dashboard schema'));
    }
    if (typeof input === 'string') { if (input.length > 16*1024*1024 || new TextEncoder().encode(input).byteLength > 16*1024*1024) throw Error(t('仪表盘数据过大','Dashboard too large')); try { input = JSON.parse(input); } catch { throw Error(t('仪表盘数据格式无效','Invalid dashboard schema')); } }
    if (Array.isArray(input)) {
      const rows = input.filter(r => r && day(r.date) && amount(r.tokens) !== null);
      if (!rows.length) throw Error(t('旧版数据未提供','Legacy data unavailable'));
      document.querySelectorAll('[data-mode]').forEach(el => { el.hidden = true; });
      for (const id of ['context','month','trends','details','selection']) $(id).hidden = true;
      $('overview').hidden = false;
      const svg = api.areaLineSvg(api.areaLineChart(rows,{width:options.width || 650,height:options.height || 40,metric:'tokens',curve:true}));
      $('calendar').innerHTML = svg;
      installedSnapshot = undefined;
      return svg;
    }
    document.querySelectorAll('[data-mode]').forEach(el => { el.hidden = false; });
    for (const id of ['context','month','selection']) $(id).hidden = false;
    const previous = state;
    state = normalize(input,options.resetAnnotations);
    $('context').textContent = `${t('年度活动','Annual activity')} · ${publicText(input.timezone)} · ${t('总量由原生统计提供','Total supplied by native statistics')} · ${t('公开重置公告不代表个人窗口重置','Public reset announcements do not establish personal resets')}`;
    const rows = [...state.byDate.values()].filter(r => amount(r.tokens) !== null);
    const intensities = api.computeHeatmapIntensities(rows).map(r => ({...r,intensity:r.tokenIntensity}));
    state.calendar = api.rollingYearHeatmap(intensities,{endDate:state.end,cell:8,gap:3});
    const svg = api.heatmapSvg(state.calendar,{titleOf:c => describe(c.date)});
    $('calendar').innerHTML = svg;
    if (language === 'zh') $('calendar').querySelectorAll('.heat-month').forEach(el => { const i = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'].indexOf(el.textContent); if (i >= 0) el.textContent = `${i+1}月`; });
    $('calendar').querySelectorAll('[data-d]').forEach(el => {
      const key = el.getAttribute('data-d');
      el.classList.add(status(key));
      if (state.resets.has(key)) el.classList.add('reset');
      if (status(key) === 'unknown') { el.removeAttribute('data-t'); el.removeAttribute('data-cost'); }
      bindDate(el,key);
    });
    $('from').value = state.calendar.cells[0].date; $('to').value = state.end;
    select(previous?.selected && day(previous.selected) && previous.selected <= state.end ? previous.selected : state.end);
    mode(previous?.mode || 'overview');
    installedSnapshot = snapshotID != null ? {id:snapshotID,input} : undefined;
    return svg;
  };
  document.querySelectorAll('[data-mode]').forEach(el => el.addEventListener('click', () => mode(el.getAttribute('data-mode'))));
  for (const id of ['group','from','to']) $(id).addEventListener('change',bars);
  $('period').addEventListener('change',details);
  $('date').addEventListener('change', () => select($('date').value));
})(window);
