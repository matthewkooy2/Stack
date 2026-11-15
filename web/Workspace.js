import React, {useEffect, useId, useRef, useState} from 'react';
import {rpc, errorText, downloadPDF} from './transport.js';
const h = React.createElement;
const tabs = ['Jobs', 'Applications', 'Network', 'Resume', 'Prep'];
const modes = ['Remote', 'Hybrid', 'On-site'];
const employment = ['Full-time', 'Part-time', 'Contract', 'Temporary', 'Internship'];
const levels = ['Internship', 'Entry-level', 'Mid-level', 'Senior', 'Leadership'];
const date = value => value ? new Date(value * 1000).toLocaleString() : 'Not scheduled';
export function safeURL(value) { try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) ? url.href : ''; } catch { return ''; } }
const button = (label, onClick, props = {}) => h('button', {type: 'button', onClick, ...props}, label);
const link = (label, url) => safeURL(url) ? h('a', {href: safeURL(url), target: '_blank', rel: 'noopener noreferrer', className: 'button-link'}, label, h('span', {'aria-hidden': true}, ' ↗')) : null;
function Field({label, value, onChange, options, multiline, ...props}) {
 const id = useId();
 return h('div', {className: 'field'}, h('label', {htmlFor: id}, label), h(options ? 'select' : multiline ? 'textarea' : 'input', {id, value: value ?? '', onChange: e => onChange(e.target.value), ...props}, options ? options.map(x => h('option', {key: typeof x === 'string' ? x : x.value, value: typeof x === 'string' ? x : x.value}, typeof x === 'string' ? x : x.label)) : undefined));
}
function Choices({label, options, value = [], onChange}) {
 return h('fieldset', {className: 'choices'}, h('legend', {}, label), ...options.map(x => button(x, () => onChange(value.includes(x) ? value.filter(v => v !== x) : [...value, x]), {key: x, 'aria-pressed': value.includes(x), className: value.includes(x) ? 'active' : ''})));
}
function Empty({title, detail, action}) { return h('div', {className: 'empty-state'}, h('h2', {}, title), h('p', {}, detail), action); }
function useTask() {
 const [busy, setBusy] = useState(false), [error, setError] = useState(''), [notice, setNotice] = useState('');
 const lock = useRef(false), alive = useRef(true);
 useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
 async function perform(fn, message = '') {
  if (lock.current) return;
  lock.current = true; setBusy(true); setError(''); setNotice('');
  try { const result = await fn(); if (alive.current) setNotice(message); return result; }
  catch (e) { if (alive.current) setError(errorText(e)); }
  finally { lock.current = false; if (alive.current) setBusy(false); }
 }
 return {busy, error, notice, perform};
}
function Messages({task}) { return h('div', {'aria-live': 'polite'}, task.error && h('p', {className: 'error', role: 'alert'}, task.error), task.notice && h('p', {className: 'notice', role: 'status'}, task.notice)); }
function Icon({name}) {
 const paths = {
  Jobs: 'M4 6h16v15H4z M9 6V3h6v3 M4 11h16 M10 11v3h4v-3',
  Applications: 'M7 3h10v3H7z M6 5H4v16h16V5h-2 M8 11h8 M8 16h5',
  Network: 'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M19 15a4 4 0 0 1 3 4v2 M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M16 3a4 4 0 0 1 0 8',
  Resume: 'M14 2H4v20h16V8z M14 2v6h6 M8 13h8 M8 17h6',
  Prep: 'M12 3 2 8l10 5 10-5z M6 10v7l6 4 6-4v-7 M22 8v8'
 };
 return h('svg', {width: 22, height: 22, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': true}, h('path', {d: paths[name]}));
}
const groupFor = page => ['Practice', 'Interview'].includes(page) ? 'Prep' : page === 'Bullet bank' ? 'Resume' : ['Activity', 'Features'].includes(page) ? 'Agents' : page;
const destination = label => ({Prep: 'Practice', Agents: 'Activity'})[label] || label;
export function Navigation({page, onNavigate, snapshot, busy, onRefresh}) {
 const group = groupFor(page), callback = useRef(onNavigate), first = useRef(true), title = useRef(null);
 callback.current = onNavigate;
 useEffect(() => {
  const read = () => { let route; try { route = decodeURIComponent(location.hash.slice(1)); } catch { return; } if ([...tabs, 'Practice', 'Interview', 'Bullet bank', 'Activity', 'Features', 'Account'].includes(route)) callback.current(destination(route)); };
  read(); window.addEventListener('hashchange', read); return () => window.removeEventListener('hashchange', read);
 }, []);
 useEffect(() => { if (first.current) { first.current = false; return; } title.current?.focus(); }, [page]);
 function go(next) { if (next === page) return; location.hash = encodeURIComponent(next); callback.current(next); }
 const attention = snapshot.agents?.attention || snapshot.agents?.needs_input || 0;
 return h(React.Fragment, {},
  h('a', {href: '#workspace-content', className: 'skip-link'}, 'Skip to content'),
  h('header', {className: 'app-header'}, h('span', {className: 'brand', 'aria-label': 'Stack'}, 'stack'), h('div', {className: 'header-actions'},
   button('Refresh', onRefresh, {disabled: busy, 'aria-label': 'Refresh account data'}),
   button('Agents' + (attention ? ' · ' + attention : ''), () => go('Activity'), {'aria-current': group === 'Agents' ? 'page' : undefined}),
   button(snapshot.profile?.name?.split(' ')[0] || 'Profile', () => go('Account'), {className: 'profile-button', 'aria-label': 'Open profile and settings', 'aria-current': page === 'Account' ? 'page' : undefined}))),
  h('nav', {className: 'main-nav', 'aria-label': 'Main navigation'}, ...tabs.map(label => button(h(React.Fragment, {}, h(Icon, {name: label}), h('span', {}, label)), () => go(destination(label)), {key: label, className: group === label ? 'active' : '', 'aria-current': group === label ? 'page' : undefined}))),
  h('div', {className: 'page-heading', id: 'workspace-content', tabIndex: -1, ref: title}, h('p', {className: 'eyebrow'}, 'Your next chapter'), h('h1', {}, group === 'Account' ? 'Your profile' : group), h('p', {}, ({Jobs: 'Find your next move.', Applications: 'Every opportunity, in one place.', Network: 'Your presence. Your people.', Resume: 'Your experience, ready to share.', Prep: 'A little practice. A lot more confidence.', Agents: 'Progress, with you in control.', Account: 'Preferences that follow you across devices.'})[group])),
  group === 'Prep' && h('nav', {className: 'subnav', 'aria-label': 'Prep tools'}, ...['Practice', 'Interview'].map(p => button(p === 'Interview' ? 'Mock interview' : p, () => go(p), {key: p, className: page === p ? 'active' : '', 'aria-current': page === p ? 'page' : undefined}))),
  group === 'Agents' && h('nav', {className: 'subnav', 'aria-label': 'Agent tools'}, ...['Activity', 'Features'].map(p => button(p === 'Activity' ? 'Tasks & activity' : 'Available features', () => go(p), {key: p, className: page === p ? 'active' : ''}))),
  group === 'Resume' && h('nav', {className: 'subnav', 'aria-label': 'Resume tools'}, button('Your resumes', () => go('Resume'), {className: page === 'Resume' ? 'active' : ''}), button('Experience bank', () => go('Bullet bank'), {className: page === 'Bullet bank' ? 'active' : ''})));
}
export function WorkspacePages({page, snapshot, onSnapshot, onNavigate, onRun, onSession, refreshTick}) {
 const [visited, setVisited] = useState(new Set());
 useEffect(() => { setVisited(v => new Set([...v, page])); }, [page]);
 const panels = {Jobs, Applications, Resume, Account: Profile};
 return h(React.Fragment, {}, ...Object.entries(panels).filter(([p]) => p === page || visited.has(p)).map(([p, Component]) => h('div', {key: p, hidden: p !== page}, h(Component, {snapshot, onSnapshot, onNavigate, onRun, onSession, refreshTick, active: p === page}))));
}
function Jobs({snapshot, onSnapshot, onNavigate, active, refreshTick}) {
 const saved = snapshot.saved_search || {}, [query, setQuery] = useState(saved.query || ''), [filters, setFilters] = useState(saved.filters || {});
 const [feed, setFeed] = useState(null), [detail, setDetail] = useState(null), [loaded, setLoaded] = useState(false), [searchOpen, setSearchOpen] = useState(false);
 const applied = useRef({query: saved.query || '', filters: saved.filters || {}}), task = useTask();
 const configuration = JSON.stringify([saved, snapshot.profile?.preferences]), observed = useRef(configuration), refreshed = useRef(refreshTick);
 const dirty = useRef(false), changeQuery = value => { dirty.current = true; setQuery(value); };
 async function search({reset = false, more = false} = {}) {
  await task.perform(async () => {
   let chosen = applied.current;
   if (!more) {
    chosen = reset ? await rpc('reset_search', {}) : await rpc('save_search', {query, filters});
    chosen = {query: chosen.query || '', filters: chosen.filters || {}};
    applied.current = chosen; setQuery(chosen.query); setFilters(chosen.filters); dirty.current = false;
    const account = await rpc('bootstrap', {}); observed.current = JSON.stringify([account.saved_search || {}, account.profile?.preferences]); onSnapshot(account);
   }
   const result = await rpc('search_jobs', {...chosen, cursor: more ? feed?.next_cursor || '' : '', refresh: false});
   setFeed(previous => more ? {...result, jobs: [...(previous?.jobs || []), ...result.jobs.filter(j => !(previous?.jobs || []).some(old => old.id === j.id))]} : result);
   setDetail(null); setLoaded(true); setSearchOpen(false);
  });
 }
 useEffect(() => {
  if (!active || (loaded && observed.current === configuration && refreshed.current === refreshTick)) return;
  refreshed.current = refreshTick;
  if (observed.current !== configuration) {
   applied.current = {query: saved.query || '', filters: saved.filters || {}};
   observed.current = configuration;
   if (!dirty.current) { setQuery(applied.current.query); setFilters(applied.current.filters); }
  }
  task.perform(async () => { const result = await rpc('search_jobs', {...applied.current, cursor: '', refresh: false}); setFeed(result); setDetail(null); setLoaded(true); });
 }, [active, configuration, refreshTick]);
 const decisions = new Set((snapshot.decisions || []).map(x => x.job_id));
 const jobs = (feed?.jobs || []).filter(j => !decisions.has(j.id));
 const job = jobs[0];
 const update = (key, value) => { dirty.current = true; setFilters(f => ({...f, [key]: value})); };
 async function decide(action) { await task.perform(async () => { onSnapshot(await rpc('swipe', {job_id: job.id, action})); setDetail(null); }, action === 'apply' ? 'Saved to Applications. Apply on the employer site when you’re ready.' : 'Passed. Your next role is ready.'); }
 const effective = feed?.criteria || {};
 return h('section', {'aria-label': 'Find jobs', className: 'jobs-layout'},
  h('form', {className: 'search-panel' + (searchOpen ? ' expanded' : ''), onSubmit: e => { e.preventDefault(); search(); }}, h('h2', {}, 'Your search'), button(h(React.Fragment, {}, h('span', {}, 'Search & filters'), h('span', {className: 'caption'}, effective.roles || 'All professions')), () => setSearchOpen(v => !v), {className: 'mobile-search-toggle', 'aria-expanded': searchOpen}), h('div', {className: 'search-fields'}, h(Field, {label: 'Role or keywords', value: query, placeholder: effective.roles || 'Use your profile preferences', maxLength: 160, onChange: changeQuery}),
   h(Field, {label: 'Location', value: filters.location ?? '', placeholder: effective.location || 'United States', maxLength: 160, onChange: v => update('location', v)}),
   h('details', {}, h('summary', {}, 'Filters & preferences'), h(Choices, {label: 'Work arrangement', options: modes, value: filters.modes ?? effective.modes, onChange: v => update('modes', v)}), h(Choices, {label: 'Level', options: levels, value: filters.levels, onChange: v => update('levels', v)}), h(Choices, {label: 'Employment type', options: employment, value: filters.employment_types ?? effective.employment_types, onChange: v => update('employment_types', v)}),
    h(Field, {label: 'Minimum pay', type: 'number', min: 0, max: 10000000, value: filters.salary_min ?? '', onChange: v => update('salary_min', v === '' ? null : Number(v))}),
    h(Field, {label: 'Pay period', value: filters.salary_period || effective.salary_period || 'year', options: [{value: 'year', label: 'Per year'}, {value: 'hour', label: 'Per hour'}], onChange: v => update('salary_period', v)}),
    h(Field, {label: 'Posted within', value: filters.posted_days || 0, options: [{value: 0, label: 'Any time'}, {value: 1, label: '24 hours'}, {value: 7, label: '7 days'}, {value: 30, label: '30 days'}], onChange: v => update('posted_days', Number(v))}),
    h(Field, {label: 'Start date fit', value: filters.timeline || 'all', options: [{value: 'all', label: 'All start dates'}, {value: 'compatible', label: 'Compatible with my timeline'}, {value: 'confirmed', label: 'Confirmed timeline only'}], onChange: v => update('timeline', v)})),
   h(Field, {label: 'Sort by', value: filters.sort || 'relevance', options: [{value: 'relevance', label: 'Best match'}, {value: 'newest', label: 'Newest first'}], onChange: v => update('sort', v)}),
   h('div', {className: 'toolbar'}, h('button', {type: 'submit', className: 'primary', disabled: task.busy}, task.busy ? 'Loading…' : 'Find jobs'), button('Reset to profile', () => search({reset: true}), {disabled: task.busy})), button('Edit profile preferences', () => onNavigate('Account'), {className: 'text-button'}))),
  h('div', {className: 'job-deck', 'aria-busy': task.busy}, h(Messages, {task}),
   !loaded && !task.error && h('p', {role: 'status'}, 'Loading jobs…'),
   feed && h('p', {className: 'eyebrow'}, `${feed.total || 0} matching roles · ${jobs.length} left on this page`),
   ...(effective.notices || []).map((text, i) => h('p', {key: i}, text)),
   job ? h('article', {className: 'job-card'}, h('p', {className: 'eyebrow'}, job.company), h('h2', {}, job.title), h('p', {className: 'job-meta'}, [job.location, job.mode, job.salary].filter(Boolean).join(' · ')), h('div', {className: 'tags'}, ...(job.tags || []).map(t => h('span', {key: t}, t))),
    ...['responsibilities', 'requirements'].map(key => job.highlights?.[key]?.length ? h('div', {key}, h('h3', {}, key === 'requirements' ? 'What you bring' : 'The role'), ...job.highlights[key].map((text, i) => h('p', {key: i}, text))) : null),
    button(detail?.id === job.id ? 'Hide description' : 'Full description', () => detail?.id === job.id ? setDetail(null) : task.perform(async () => setDetail(await rpc('get_job', {id: job.id}))), {disabled: task.busy, 'aria-expanded': detail?.id === job.id}),
    detail?.id === job.id && h('div', {className: 'job-description'}, h('p', {}, detail.description || 'No description supplied.'), detail.qualifications && h('p', {}, detail.qualifications)),
    link('Employer listing', job.listing_url || job.url), h('p', {className: 'caption'}, [job.posted, job.source].filter(Boolean).join(' · ')),
    h('div', {className: 'job-actions'}, button('Pass', () => decide('pass'), {disabled: task.busy}), button('Save role', () => decide('apply'), {className: 'primary', disabled: task.busy}))) : loaded && h(Empty, {title: feed?.total ? 'You’re all caught up.' : 'No matching roles yet.', detail: 'Adjust your search or check back after the next jobs update.', action: button('View applications', () => onNavigate('Applications'))}),
   feed?.next_cursor && button('Load more roles', () => search({more: true}), {disabled: task.busy}), task.error && !loaded && button('Retry loading jobs', () => search(), {disabled: task.busy})));
}
function Applications({snapshot, onSnapshot, onNavigate, onRun, onSession}) {
 const [filter, setFilter] = useState('All'), [selected, setSelected] = useState(''), [query, setQuery] = useState(''), [view, setView] = useState('Applications');
 const all = [...(snapshot.applications || [])].sort((a, b) => b.created_at - a.created_at), app = all.find(a => a.id === selected);
 const rows = all.filter(a => (filter === 'All' || a.status === filter) && `${a.job.title} ${a.job.company}`.toLowerCase().includes(query.toLowerCase()));
 return h('section', {'aria-label': 'Your applications'}, h('div', {className: 'toolbar'}, ...['Applications', 'Calendar', 'Follow-ups'].map(v => button(v, () => setView(v), {key: v, className: view === v ? 'active' : '', 'aria-pressed': view === v}))),
  view === 'Follow-ups' ? h(Reminders, {snapshot, onSnapshot}) : view === 'Calendar' ? h(Calendar, {snapshot}) : h('div', {className: 'split-view'}, h('div', {}, h(Field, {label: 'Search applications', type: 'search', value: query, onChange: setQuery}), h(Field, {label: 'Status', value: filter, options: ['All', ...new Set(all.map(a => a.status).filter(Boolean))], onChange: setFilter}),
   rows.length ? h('div', {className: 'row-list'}, ...rows.map(a => button(h(React.Fragment, {}, h('strong', {}, a.job.title), h('span', {}, `${a.job.company} · ${a.status}${a.demo ? ' · Demo' : ''}`)), () => setSelected(a.id), {key: a.id, className: 'list-row' + (selected === a.id ? ' selected' : ''), 'aria-pressed': selected === a.id}))) : h(Empty, {title: all.length ? 'No matches.' : 'Nothing saved yet.', detail: 'Roles you save from Jobs appear here.', action: button('Find jobs', () => onNavigate('Jobs'))})),
   app ? h(ApplicationDetail, {key: app.id, app, snapshot, onSnapshot, onRun, onSession, onClose: () => setSelected('')}) : all.length > 0 && h(Empty, {title: 'Choose an application.', detail: 'Review the role, add notes, or plan your follow-up.'})));
}
function ApplicationDetail({app, snapshot, onSnapshot, onRun, onSession, onClose}) {
 const [notes, setNotes] = useState(app.notes || ''), [reminding, setReminding] = useState(false), [plan, setPlan] = useState([]), task = useTask();
 const mutate = (endpoint, args, notice) => task.perform(async () => onSnapshot(await rpc(endpoint, args)), notice);
 return h('section', {className: 'detail-pane', 'aria-label': 'Application details'}, button('← All applications', onClose, {className: 'text-button'}), h('p', {className: 'eyebrow'}, app.status + (app.demo ? ' · Demo' : '')), h('h2', {}, app.job.title), h('p', {}, [app.job.company, app.job.location].filter(Boolean).join(' · ')), h(Messages, {task}),
  link('Apply on employer site', app.job.url), !app.demo && app.status !== 'Submitted' && button('I submitted this application', () => mutate('mark_application_submitted', {id: app.id}, 'Marked as submitted.'), {disabled: task.busy, className: 'primary'}),
  h(Field, {label: 'Resume for this application', value: app.resume_id || '', options: [{value: '', label: 'Use default resume'}, ...(snapshot.resumes || []).map(r => ({value: r.id, label: r.name}))], disabled: task.busy, onChange: resume_id => mutate('select_application_resume', {id: app.id, resume_id}, 'Resume selected.')}),
  h(Field, {label: 'Your notes', multiline: true, value: notes, maxLength: 5000, onChange: setNotes}), button('Save notes', () => mutate('save_application', {id: app.id, notes}, 'Notes saved.'), {disabled: task.busy || notes === app.notes}),
  h('details', {}, h('summary', {}, 'Agent help'), h('p', {}, 'Choose the help you want. Review any external action before it happens.'), ...['jobs', 'resume', 'interview'].map(kind => button(({jobs: 'Analyze fit', resume: 'Tailor resume', interview: 'Build prep plan'})[kind], () => task.perform(async () => kind === 'interview' ? setPlan((await rpc('prep_for_application', {application_id: app.id})).plan) : onRun(await rpc('agent_start', {kind, target_id: app.id})), kind === 'interview' ? 'Your prep plan is ready below.' : ''), {key: kind, disabled: task.busy || app.demo}))),
  ...plan.map(item => h('article', {key: item.session_id}, h('h3', {}, item.title), h('p', {}, item.reason), button('Practice this question', () => onSession(item.session_id), {disabled: task.busy}))),
  button('Add follow-up', () => setReminding(v => !v), {'aria-expanded': reminding}), reminding && h(ReminderForm, {target: app.id, onSnapshot, onDone: () => setReminding(false)}),
  h('details', {}, h('summary', {}, 'Status history'), ...(app.history || []).map((row, i) => h('p', {key: i}, `${row.status} · ${date(row.at)} · ${row.source}`))));
}
function ReminderForm({target, onSnapshot, onDone}) {
 const [title, setTitle] = useState('Follow up'), [due, setDue] = useState(''), task = useTask();
 return h('form', {onSubmit: e => { e.preventDefault(); task.perform(async () => { onSnapshot(await rpc('save_reminder', {id: '', target_type: 'application', target_id: target, title, due_at: new Date(due).getTime() / 1000})); onDone(); }); }}, h(Field, {label: 'Reminder title', value: title, required: true, maxLength: 160, onChange: setTitle}), h(Field, {label: 'Remind me at', type: 'datetime-local', value: due, required: true, onChange: setDue}), h('p', {className: 'caption'}, 'Saved to your account. Browser notifications are not scheduled.'), h(Messages, {task}), h('button', {type: 'submit', disabled: task.busy || !due}, 'Save reminder'));
}
function Reminders({snapshot, onSnapshot}) {
 const task = useTask(), rows = [...(snapshot.reminders || [])].sort((a, b) => a.due_at - b.due_at);
 return h('div', {}, h('h2', {}, 'Follow-ups'), h(Messages, {task}), !rows.length && h(Empty, {title: 'No follow-ups yet.', detail: 'Open an application to add a reminder.'}), ...rows.map(r => h('article', {key: r.id}, h('h3', {}, r.title), h('p', {}, `${date(r.due_at)}${r.done ? ' · Completed' : ''}`), !r.done && button('Mark complete', () => task.perform(async () => onSnapshot(await rpc('change_reminder', {id: r.id, action: 'complete'}))), {disabled: task.busy}), button('Delete reminder', () => task.perform(async () => onSnapshot(await rpc('change_reminder', {id: r.id, action: 'delete'}))), {disabled: task.busy}))));
}
function Calendar({snapshot}) {
 const [events, setEvents] = useState(null), [day, setDay] = useState(''), task = useTask();
 const load = () => task.perform(async () => setEvents((await rpc('agent_events', {})).interviews || []));
 useEffect(() => { load(); }, []);
 const entries = [
  ...(snapshot.applications || []).flatMap(a => [{id: a.id, time: a.created_at * 1000, title: a.job.title, detail: a.job.company + ' · Saved' + (a.demo ? ' · Demo' : '')}, ...(a.history || []).map((event, i) => ({id: a.id + ':' + i, time: event.at * 1000, title: a.job.title, detail: event.status}))]),
  ...(snapshot.reminders || []).map(r => ({id: r.id, time: r.due_at * 1000, title: r.title, detail: r.done ? 'Follow-up · Completed' : 'Follow-up'})),
  ...(events || []).filter(e => e.status !== 'cancelled').map(e => ({id: e.id, time: Date.parse(e.start?.dateTime || e.start?.date || ''), title: e.summary || 'Interview', detail: snapshot.applications?.find(a => a.id === e.application_id)?.job.company || 'Interview'}))
 ].filter(e => Number.isFinite(e.time)).sort((a, b) => b.time - a.time);
 const dayKey = time => { const d = new Date(time); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
 const shown = entries.filter(e => !day || dayKey(e.time) === day);
 return h('section', {}, h('h2', {}, 'Calendar'), h('p', {}, 'Saved applications, status updates, follow-ups, and confirmed interviews.'), h(Field, {label: 'Filter by date', type: 'date', value: day, onChange: setDay}), day && button('Show all dates', () => setDay('')), h(Messages, {task}), task.busy && h('p', {role: 'status'}, 'Loading interviews…'), !shown.length && h(Empty, {title: 'Nothing scheduled here.', detail: 'Save a role or add an application follow-up to get started.'}), ...shown.map(e => h('article', {key: e.id}, h('p', {className: 'eyebrow'}, new Date(e.time).toLocaleString()), h('h3', {}, e.title), h('p', {}, e.detail))), task.error && button('Retry calendar', load));
}
function Resume({snapshot, onSnapshot, onNavigate, onRun, active}) {
 const task = useTask(), [selected, setSelected] = useState(''), [renaming, setRenaming] = useState(''), [name, setName] = useState('');
 const [job, setJob] = useState(''), [score, setScore] = useState(null), [review, setReview] = useState(null);
 const resumes = snapshot.resumes || [];
 const busyProcessing = resumes.some(r => Object.values(r.processing || {}).some(lane => ['queued', 'parsing', 'compiling'].includes(lane?.status)));
 useEffect(() => { if (!active || !busyProcessing) return; let alive = true; const timer = setInterval(async () => { try { const result = await rpc('bootstrap', {}); if (alive) onSnapshot(result); } catch {} }, 4000); return () => { alive = false; clearInterval(timer); }; }, [active, busyProcessing]);
 const mutate = (endpoint, args, notice) => task.perform(async () => onSnapshot(await rpc(endpoint, args)), notice);
 async function upload(file) {
  if (!file) return;
  await task.perform(async () => {
   if (file.size > 10 * 1024 * 1024) throw new Error('Choose a PDF or DOCX up to 10 MB.');
   if (!/\.(pdf|docx)$/i.test(file.name)) throw new Error('Choose a PDF or DOCX resume.');
   const bytes = new Uint8Array(await file.arrayBuffer()); let binary = '';
   for (let at = 0; at < bytes.length; at += 8192) binary += String.fromCharCode(...bytes.subarray(at, at + 8192));
   onSnapshot(await rpc('upload_resume', {name: file.name, content: btoa(binary), transfer_ms: 0}));
  }, 'Resume uploaded privately. Processing progress appears below.');
 }
 return h('section', {'aria-label': 'Your resumes'}, h('label', {className: 'upload-control'}, task.busy ? 'Working…' : 'Upload a resume', h('input', {type: 'file', accept: '.pdf,.docx', disabled: task.busy, onChange: e => { upload(e.target.files?.[0]); e.target.value = ''; }})), h('p', {className: 'caption'}, 'PDF or DOCX · up to 10 MB · private to your account'), h(Messages, {task}),
  !resumes.length && h(Empty, {title: 'Your story starts here.', detail: 'Upload your resume to use it for applications, tailoring, and interview prep.'}),
  ...resumes.map(r => h('article', {key: r.id}, h('div', {className: 'row-heading'}, h('h2', {}, r.name), snapshot.selected_resume === r.id && h('span', {className: 'status-pill'}, 'Default')), h('p', {}, r.details_status + ' · ' + Math.ceil(r.size / 1024) + ' KB'),
   ...Object.entries(r.processing || {}).filter(([, lane]) => lane?.status).map(([kind, lane]) => h('div', {key: kind}, h('p', {role: 'status'}, `${kind === 'source' ? 'Source' : 'Resume details'} · ${lane.status}${lane.error ? ' · ' + lane.error : ''}`), lane.status === 'failed' && button('Retry processing', () => mutate('retry_resume_processing', {id: r.id, kind}, 'Processing restarted.'), {disabled: task.busy}))),
   h('div', {className: 'toolbar'}, button('Download original', () => task.perform(async () => { const pdf = await rpc('read_resume', {id: r.id}); downloadPDF(pdf); }), {disabled: task.busy}), snapshot.selected_resume !== r.id && button('Use as default', () => mutate('change_resume', {id: r.id, action: 'select', name: ''}, 'Default resume updated.'), {disabled: task.busy}), button('Review details', () => task.perform(async () => { setReview(await rpc('agent_extract_resume', {id: r.id})); setSelected(r.id); }), {disabled: task.busy}), button('Rename', () => { setRenaming(r.id); setName(r.name); }, {disabled: task.busy}), button('Delete', () => { if (window.confirm(`Delete ${r.name}? This removes the uploaded file from your account.`)) mutate('change_resume', {id: r.id, action: 'delete', name: ''}, 'Resume deleted.'); }, {disabled: task.busy})),
   renaming === r.id && h('form', {onSubmit: e => { e.preventDefault(); task.perform(async () => { onSnapshot(await rpc('change_resume', {id: r.id, action: 'rename', name})); setRenaming(''); }); }}, h(Field, {label: 'Resume name', value: name, maxLength: 160, required: true, onChange: setName}), h('button', {type: 'submit', disabled: task.busy}, 'Save name'), button('Cancel', () => setRenaming(''))),
   selected === r.id && review && h(ResumeReview, {key: r.id + ':' + review.revision, id: r.id, review, onSnapshot, onClose: () => { setReview(null); setSelected(''); }}))),
  h('details', {}, h('summary', {}, 'Tailor for a job'), h(Field, {label: 'Saved job', value: job, onChange: v => { setJob(v); setScore(null); }, options: [{value: '', label: 'Choose an application'}, ...(snapshot.applications || []).filter(a => !a.demo).map(a => ({value: a.id, label: `${a.job.title} · ${a.job.company}`}))]}), button('Score resume fit', () => task.perform(async () => setScore(await rpc('score_resume', {application_id: job}))), {disabled: task.busy || !job}), button('Tailor resume', () => task.perform(async () => onRun(await rpc('agent_start', {kind: 'resume', target_id: job}))), {disabled: task.busy || !job}), score && h(ResumeScore, {result: score})),
  snapshot.tailored_resumes?.length > 0 && h('details', {}, h('summary', {}, 'Tailored resumes'), ...snapshot.tailored_resumes.map(r => h('article', {key: r.id}, h('h3', {}, r.name), h('p', {}, [r.job_title, r.company].filter(Boolean).join(' · ')), button('Download PDF', () => task.perform(async () => downloadPDF((await rpc('read_tailored_resume', {id: r.id})).pdf)), {disabled: task.busy})))), button('Open experience bank', () => onNavigate('Bullet bank'), {className: 'text-button'}));
}
function ResumeScore({result}) {
 const score = result.score || {};
 return h('article', {}, h('h3', {}, result.resume_name), h('p', {}, `Job match ${score.match ?? '—'}/100 · Resume quality ${score.quality ?? '—'}/100`),
  (score.missing || []).length > 0 && h('div', {}, h('h4', {}, 'Missing keywords'), h('p', {}, score.missing.join(', '))),
  ...(score.issues || []).map((issue, i) => h('p', {key: i}, typeof issue === 'string' ? issue : issue.message || issue.detail || issue.label || 'Review this resume section.')));
}
function ResumeReview({id, review, onSnapshot, onClose}) {
 const [records, setRecords] = useState(review.records || []), task = useTask();
 return h('details', {open: true}, h('summary', {}, 'Imported resume details'), h('p', {}, 'Review the extracted text before confirming facts for tailoring.'),
  records.length ? records.map((r, i) => h('div', {key: r.id, className: 'resume-record'}, h(Field, {label: `Record ${i + 1}`, multiline: true, value: r.text, maxLength: 2000, onChange: text => setRecords(items => items.map(item => item.id === r.id ? {...item, text} : item))}))) : h('p', {role: 'status'}, 'Your resume is still processing. Close and reopen details when processing finishes.'),
  h(Messages, {task}), button('Confirm details', () => task.perform(async () => { await rpc('resume_save_records', {id, revision: review.revision, records, confirm: true, template: review.template || 'classic'}); onSnapshot(await rpc('bootstrap', {})); onClose(); }), {disabled: task.busy || !records.length}), button('Close details', onClose));
}
function Profile({snapshot, onSnapshot}) {
 const [form, setForm] = useState({...snapshot.profile}), task = useTask();
 const set = (key, value) => setForm(f => ({...f, [key]: value}));
 const preferences = Object.fromEntries(Object.entries(form.preferences || {}).filter(([key]) => ['stage', 'years', 'education', 'modes', 'employment_types', 'salary_min', 'salary_period', 'exclude_companies', 'exclude_terms', 'soft'].includes(key))), pref = (key, value) => setForm(f => ({...f, preferences: {...f.preferences, [key]: value}}));
 return h('form', {className: 'profile-form', 'aria-label': 'Profile preferences', onSubmit: e => { e.preventDefault(); task.perform(async () => { const result = await rpc('save_profile', {name: form.name || '', role: form.role || '', location: form.location || '', mode: form.mode || 'Any', notifications: !!form.notifications, graduation_month: form.graduation_month || '', available_from: form.available_from || '', preferences}); onSnapshot(result); setForm(result.profile); }, 'Profile saved. Your preferences apply on both devices.'); }},
  h('h2', {}, 'Matching preferences'), h(Messages, {task}), h('div', {className: 'form-grid'}, h(Field, {label: 'Name', value: form.name, required: true, maxLength: 100, onChange: v => set('name', v)}), h(Field, {label: 'Roles', value: form.role, maxLength: 160, onChange: v => set('role', v)}), h(Field, {label: 'Location', value: form.location, maxLength: 160, onChange: v => set('location', v)}), h(Field, {label: 'Career stage', value: preferences.stage, options: ['', 'Student', 'Recent graduate', 'Early career', 'Experienced', 'Career changer'], onChange: v => pref('stage', v)}), h(Field, {label: 'Years of experience', type: 'number', min: 0, max: 60, value: preferences.years, onChange: v => pref('years', v)}), h(Field, {label: 'Education', value: preferences.education, options: ['', 'High school', 'Associate', "Bachelor's", "Master's", 'Doctorate'], onChange: v => pref('education', v)}), h(Field, {label: 'Graduation month', type: 'month', value: form.graduation_month, onChange: v => set('graduation_month', v)}), h(Field, {label: 'Available from', type: 'month', value: form.available_from, onChange: v => set('available_from', v)})),
  h(Choices, {label: 'Work arrangement', options: modes, value: preferences.modes, onChange: v => pref('modes', v)}), h(Choices, {label: 'Employment type', options: employment, value: preferences.employment_types, onChange: v => pref('employment_types', v)}),
  h('details', {}, h('summary', {}, 'Pay & exclusions'), h(Field, {label: 'Minimum pay', type: 'number', min: 0, value: preferences.salary_min, onChange: v => pref('salary_min', v)}), h(Field, {label: 'Pay period', value: preferences.salary_period || 'year', options: [{value: 'year', label: 'Per year'}, {value: 'hour', label: 'Per hour'}], onChange: v => pref('salary_period', v)}), h(Field, {label: 'Hidden employers (comma separated)', value: Array.isArray(preferences.exclude_companies) ? preferences.exclude_companies.join(', ') : preferences.exclude_companies, onChange: v => pref('exclude_companies', v)}), h(Field, {label: 'Hidden terms (comma separated)', value: Array.isArray(preferences.exclude_terms) ? preferences.exclude_terms.join(', ') : preferences.exclude_terms, onChange: v => pref('exclude_terms', v)})),
  h('label', {className: 'checkbox-label'}, h('input', {type: 'checkbox', checked: !!form.notifications, onChange: e => set('notifications', e.target.checked)}), 'Enable account reminders'), h('button', {type: 'submit', className: 'primary', disabled: task.busy}, task.busy ? 'Saving…' : 'Save preferences'));
}
export function NetworkTools({onRun, active}) {
 const [tab, setTab] = useState('Presence'), [contacts, setContacts] = useState(null), [adding, setAdding] = useState(false), [form, setForm] = useState({name: '', email: '', company: '', relationship: '', source_url: '', selected: false});
 const [platform, setPlatform] = useState('GitHub'), [drafts, setDrafts] = useState({}), task = useTask();
 const load = () => task.perform(async () => setContacts((await rpc('agent_contacts', {})).contacts));
 useEffect(() => { if (active && contacts === null) load(); }, [active]);
 const fields = platform === 'GitHub' ? ['Profile URL', 'Bio', 'Website', 'README introduction', 'Tools and technologies', 'Current focus', 'Pinned repositories'] : ['Website URL', 'Headline', 'About', 'Featured projects', 'Your contribution', 'Outcomes', 'Contact email'];
 return h('section', {'aria-label': 'Network tools'}, h('nav', {className: 'subnav', 'aria-label': 'Network sections'}, ...['Presence', 'Contacts'].map(p => button(p, () => setTab(p), {key: p, className: tab === p ? 'active' : '', 'aria-pressed': tab === p}))), h(Messages, {task}),
  h('div', {hidden: tab !== 'Presence'}, h('h2', {}, 'Public profile drafts'), h('p', {}, 'Draft your GitHub or portfolio copy here. These drafts stay in this signed-in browser session.'), h('nav', {className: 'subnav', 'aria-label': 'Public profile platform'}, ...['GitHub', 'Portfolio'].map(p => button(p, () => setPlatform(p), {key: p, className: platform === p ? 'active' : ''}))), ...fields.map(label => h('details', {key: platform + label}, h('summary', {}, label), h(Field, {label: label + ' draft', multiline: !label.includes('URL'), value: drafts[platform + label] || '', onChange: v => setDrafts(d => ({...d, [platform + label]: v}))}))), h('p', {className: 'caption'}, 'Nothing is published. Signing out or reloading clears these drafts. LinkedIn review is below.')),
  h('div', {hidden: tab !== 'Contacts'}, h('div', {className: 'toolbar'}, button('Add a contact', () => setAdding(v => !v), {'aria-expanded': adding, className: 'primary'}), button('Refresh contacts', load, {disabled: task.busy})),
   contacts === null && !task.error && h('p', {role: 'status'}, 'Loading contacts…'), contacts?.length === 0 && h(Empty, {title: 'Your people, all here.', detail: 'Save a contact to prepare an outreach draft. Saving never sends a message.'}),
   adding && h('form', {onSubmit: e => { e.preventDefault(); task.perform(async () => { setContacts((await rpc('agent_save_contact', {id: '', data: form})).contacts); setAdding(false); setForm({name: '', email: '', company: '', relationship: '', source_url: '', selected: false}); }, 'Contact saved. Nothing was sent.'); }}, ...['name', 'email', 'company', 'relationship', 'source_url'].map(key => h(Field, {key, label: ({name: 'Name', email: 'Email', company: 'Company', relationship: 'Relationship', source_url: 'Source URL'})[key], type: key === 'email' ? 'email' : key === 'source_url' ? 'url' : 'text', required: key === 'name', value: form[key], onChange: v => setForm(f => ({...f, [key]: v}))})), h('button', {type: 'submit', disabled: task.busy}, 'Save contact')),
   ...(contacts || []).map(c => h('article', {key: c.id}, h('h2', {}, c.name), h('p', {}, [c.email, c.company, c.relationship].filter(Boolean).join(' · ')), h('p', {}, c.stopped ? 'Outreach stopped' : c.selected ? 'Selected for outreach' : 'Not selected'), !c.stopped && button(c.selected ? 'Draft outreach' : 'Select for outreach', () => task.perform(async () => { if (c.selected) onRun(await rpc('agent_start', {kind: 'network', target_id: c.id})); else setContacts((await rpc('agent_save_contact', {id: c.id, data: {...c, selected: true}})).contacts); }), {disabled: task.busy}), !c.stopped && button('Stop outreach', () => task.perform(async () => setContacts((await rpc('agent_stop_contact', {id: c.id})).contacts)), {disabled: task.busy})))));
}
export function AgentControls({settings, onSettings, onConnect}) {
 const [policy, setPolicy] = useState(settings.policy || {}), [facts, setFacts] = useState(settings.facts || []), [key, setKey] = useState(''), [value, setValue] = useState(''), [domains, setDomains] = useState((settings.policy?.domains || []).join(', '));
 const task = useTask(), set = (k, v) => setPolicy(p => ({...p, [k]: v}));
 const updateFacts = items => task.perform(async () => { const result = await rpc('agent_save_facts', {facts: items}); setFacts(result.facts); onSettings(result); setKey(''); setValue(''); }, 'Confirmed facts saved.');
 const localTime = value => { if (!value) return ''; const d = new Date(value * 1000); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16); };
 return h('section', {className: 'agent-controls', 'aria-label': 'Agent settings'}, h('h2', {}, 'Agent settings'), h(Messages, {task}),
  h('details', {}, h('summary', {}, 'Model provider'), h('p', {}, settings.activity?.model_provider?.message || 'Choose the model used for your tasks.'), ...(settings.model_options || []).map(option => button(option.selection === 'local' ? 'Local model' : 'Codex CLI', () => task.perform(async () => onSettings(await rpc('agent_save_model', {selection: option.selection})), 'Model selection saved.'), {key: option.selection, disabled: task.busy, 'aria-pressed': settings.model_selection === option.selection}))),
  h('details', {}, h('summary', {}, 'Email & calendar'), h('p', {}, 'Connect only the Google capabilities you want to test. Gmail read access covers your mailbox; Stack processes application and selected-contact messages.'), ...[['Connect Gmail tracking', ['read']], ['Allow Gmail sending', ['send']], ['Connect Google Calendar', ['calendar', 'availability']]].map(([label, capabilities]) => button(label, () => task.perform(() => onConnect(capabilities)), {key: label, disabled: task.busy})), ...(settings.connections || []).map(connection => h('article', {key: connection.id}, h('p', {}, `${connection.provider} · ${connection.state}`), connection.state === 'connected' && button('Disconnect', () => task.perform(async () => onSettings(await rpc('agent_disconnect', {id: connection.id})), 'Disconnected.'), {disabled: task.busy})))),
  h('details', {}, h('summary', {}, 'Rules & follow-up timing'), h('p', {}, 'External messages and calendar changes still wait for your review.'),
   h('form', {onSubmit: e => { e.preventDefault(); task.perform(async () => { const result = await rpc('agent_save_policy', {policy: {...policy, domains: domains.split(',').map(x => x.trim()).filter(Boolean)}}); onSettings(result); setPolicy(result.policy); setDomains(result.policy.domains.join(', ')); }, 'Agent rules saved.'); }},
    h('label', {className: 'checkbox-label'}, h('input', {type: 'checkbox', checked: !!policy.enabled, onChange: e => set('enabled', e.target.checked)}), 'Enable standing permissions'),
    ...[['gmail_read', 'Read connected Gmail'], ['send_email', 'Send reviewed emails'], ['calendar_write', 'Write reviewed calendar events']].map(([action, label]) => h('div', {key: action}, h('label', {className: 'checkbox-label'}, h('input', {type: 'checkbox', checked: (policy.actions || []).includes(action), onChange: e => set('actions', e.target.checked ? [...(policy.actions || []), action] : (policy.actions || []).filter(a => a !== action))}), label), (policy.actions || []).includes(action) && h(Field, {label: label + ' daily limit', type: 'number', min: 1, max: 100, required: true, value: policy.daily_limits?.[action] || '', onChange: v => set('daily_limits', {...policy.daily_limits, [action]: Number(v)})}))),
    h(Field, {label: 'Allowed destination domains (comma separated)', value: domains, onChange: setDomains}),
    h(Field, {label: 'Permission expiration', type: 'datetime-local', value: localTime(policy.expires_at), required: !!policy.enabled, onChange: v => set('expires_at', v ? new Date(v).getTime() / 1000 : 0)}),
    h(Field, {label: 'Follow-ups per contact', type: 'number', min: 0, max: 3, value: policy.followup_limit ?? 0, onChange: v => set('followup_limit', Number(v))}), h(Field, {label: 'Days between follow-ups', type: 'number', min: 3, max: 30, value: policy.followup_days ?? 7, onChange: v => set('followup_days', Number(v))}),
    h('label', {className: 'checkbox-label'}, h('input', {type: 'checkbox', checked: !!policy.analyze_top_matches, onChange: e => set('analyze_top_matches', e.target.checked)}), 'Analyze top job matches automatically'), h('button', {type: 'submit', disabled: task.busy}, 'Save rules'))),
  h('details', {}, h('summary', {}, 'Confirmed facts'), h('p', {}, 'Only confirm information you want agents to reuse.'),
   ...facts.map((fact, i) => h('div', {key: fact.key}, h(Field, {label: fact.key, value: fact.value, multiline: true, maxLength: 8000, onChange: value => setFacts(rows => rows.map((row, index) => i === index ? {...row, value} : row))}), h('label', {className: 'checkbox-label'}, h('input', {type: 'checkbox', checked: !!fact.verified, onChange: e => setFacts(rows => rows.map((row, index) => i === index ? {...row, verified: e.target.checked} : row))}), 'I confirm this fact'))),
   facts.length > 0 && button('Save fact changes', () => updateFacts(facts), {disabled: task.busy}),
   h('form', {onSubmit: e => { e.preventDefault(); updateFacts([{key, value, verified: true, source: 'User confirmed in Stack web'}]); }}, h(Field, {label: 'New fact key', value: key, required: true, maxLength: 100, placeholder: 'For example, email', onChange: setKey}), h(Field, {label: 'Confirmed value', value, required: true, maxLength: 8000, onChange: setValue}), h('button', {type: 'submit', disabled: task.busy}, 'Add confirmed fact'))));
}
