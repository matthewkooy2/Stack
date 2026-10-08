import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import { ResumeScenarios, PdfPreview } from './review-controls';
import React, { useState, useEffect, useRef } from 'react';
import { unzipSync, strFromU8 } from 'fflate';
import { jobs, formatOf, latex, makePdf, readPdf, compareText, score, propose, applyChanges, download, tailorSource } from './resume-model';
import { backend, describeError } from './backend';
import { liveState, refreshLive } from './live-store';
import { scoreFor, setDefault, renameResume, removeFormat, applyTemplate, uploadSource, formatPreview, originalPdf, tailoredFile, checkTailored } from './resume-live';
import { useTailor, scoreView, proposedPdf } from './tailor-live';
import { useRun, startRun, availability } from './agent-live';
const NoScore = () => null;
// Saved jobs that use this resume (its own, the default, or the only one), as the job picker lists them.
const liveJobsFor = resume => (liveState().boot?.applications || []).filter(a => !a.demo && a.tailor?.resume_id === resume.id).map(a => ({
  id: a.id,
  role: a.job.title,
  company: a.job.company,
  skills: []
}));
function Score({
  value,
  before
}) {
  return render("resume_tools_1", {
    "s0": {},
    "s1": {},
    "s2": {},
    "s3": {},
    "s4": before ? before.match + ' → ' : '',
    "s5": value.match,
    "s6": {},
    "s7": {},
    "s8": before ? before.quality + ' → ' : '',
    "s9": value.quality,
    "s10": {},
    "s11": {},
    "s12": value.components.map(([name, n, total]) => render("resume_tools_2", {
      "s0": {
        "key": name
      },
      "s1": name,
      "s2": n,
      "s3": total
    })),
    "s13": {},
    "s14": value.missing.length ? 'Missing from your resume: ' + value.missing.join(', ') : 'All listed skills appear in your resume.',
    "s15": value.issues.map(x => render("resume_tools_3", {
      "s0": {
        "key": x
      },
      "s1": x
    })),
    "s16": {}
  });
}
const pause = () => new Promise(r => setTimeout(r, 700));
export { ResumeScenarios };
export function ResumeTools({
  resume,
  onSave,
  onDelete,
  onTailored,
  onOpenTailored,
  onEdit,
  disabled,
  view,
  setView,
  scenario
}) {
  // Build-time constant: live builds run these tools on the account's resume; mock builds keep the on-device samples.
  const real = backend.live;
  const current = useRef(resume);
  current.current = resume;
  const operation = useRef(0);
  useEffect(() => () => {
    operation.current++;
  }, []);
  const [name, setName] = useState(resume.name),
    [job, setJob] = useState(resume.task?.job?.id || ''),
    [scores, setScores] = useState(null),
    [taskState, setTask] = useState(real ? null : resume.task || null),
    [busy, setBusy] = useState(''),
    [error, setError] = useState(''),
    [notice, setNotice] = useState(''),
    [rejected, setRejected] = useState(resume.task?.rejected || []),
    [pdf, setPdf] = useState(null),
    [checks, setChecks] = useState(null),
    [headline, setHeadline] = useState(resume.profileSuggestions?.headline || ''),
    [about, setAbout] = useState(resume.profileSuggestions?.about || ''),
    [profileReady, setProfileReady] = useState(!!resume.profileSuggestions),
    [approved, setApproved] = useState(!!resume.profileSuggestions),
    [lastAction, setLastAction] = useState(''),
    [pendingFormat, setPendingFormat] = useState(null),
    [deleting, setDeleting] = useState(false);
  const file = useRef(null);
  const jobList = real ? liveJobsFor(resume) : jobs;
  const tailor = useTailor({
    enabled: real,
    jobId: job
  });
  const selected = jobList.find(j => j.id === job),
    format = formatOf(resume);
  const task = real ? tailor.task ? {
    ...tailor.task,
    job: selected || {
      role: 'Saved job',
      company: ''
    }
  } : null : taskState;
  const [profileRun, setProfileRun] = useState(''),
    [texText, setTexText] = useState('');
  useEffect(() => {
    if (!real || !['files', 'format'].includes(view)) return;
    let current = true;
    (resume.tailored ? tailoredFile(resume.id) : format?.status === 'completed' ? formatPreview(resume.id) : Promise.resolve({
      tex: ''
    })).then(r => {
      if (current) setTexText(r.tex || '');
    }).catch(() => {});
    return () => {
      current = false;
    };
  }, [real, view, resume.id, format?.status]);
  const followedProfile = useRun(real ? profileRun : '');
  const locked = disabled || !!busy;
  function save(patch) {
    const next = {
      ...current.current,
      ...patch
    };
    try {
      onSave(next);
      current.current = next;
      return true;
    } catch {
      setError('Could not save on this device. Please retry.');
      return false;
    }
  }
  function saveTask(next) {
    if (!save({
      task: next
    })) return false;
    setTask(next);
    return true;
  }
  useEffect(() => {
    if (!real && ['queued', 'running'].includes(resume.task?.status)) {
      saveTask({
        ...resume.task,
        status: 'cancelled'
      });
      setNotice('The previous preview task was interrupted. Retry from Resume agents.');
    }
  }, []);
  useEffect(() => {
    setError('');
    setNotice('');
    setPdf(null);
    setChecks(null);
  }, [view]);
  useEffect(() => {
    if (scenario === 'empty') {
      setJob('');
      setScores(null);
    }
  }, [scenario]);
  function go(v) {
    setView(v);
  }
  async function act(kind, work, onFailure) {
    if (locked) return;
    const id = ++operation.current;
    setLastAction(kind);
    setError('');
    setNotice('');
    setBusy(kind);
    if (kind === 'checks') setChecks(null);
    try {
      if (!real) await pause();
      if (id !== operation.current) return;
      if (!real && (!services.online || scenario === 'offline')) throw Error('You are offline. Reconnect, choose Normal in the preview toolbar, and retry.');
      if (!real && ['tailor', 'profile', 'score'].includes(kind) && scenario === 'agent-error' || kind === 'compile' && scenario === 'compile-error' || kind === 'checks' && scenario === 'parser-error') throw Error(kind === 'compile' ? 'Format could not be prepared. Your resume details are unchanged; the attempted source and format are retained for retry. Choose Normal in the preview toolbar and retry.' : 'This request failed. Your saved resume is unchanged. Choose Normal in the preview toolbar and retry.');
      await work(() => id === operation.current);
    } catch (e) {
      if (id === operation.current) {
        setError(e.message);
        if (!real && (kind === 'tailor' || kind === 'approve')) saveTask({
          ...current.current.task,
          status: 'failed',
          failedAction: kind
        });
        if (onFailure) onFailure();
      }
    } finally {
      if (id === operation.current) setBusy('');
    }
  }
  // Waits for the server to finish building a format (LaTeX compile runs on its worker).
  async function waitForFormat() {
    const stop = Date.now() + 120000;
    while (Date.now() < stop) {
      await refreshLive({
        quiet: true
      });
      const r = (liveState().boot?.resumes || []).find(x => x.id === resume.id),
        job = r?.processing?.source;
      if (job?.status === 'failed') throw new Error(job.message || 'The format could not be compiled. Check the source and retry.');
      if (!job || job.status === 'completed') return;
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
    throw new Error('Building the format is taking longer than expected. Check back in a moment.');
  }
  async function startTailorLive() {
    if (!selected) return;
    const gate = availability('tailoring');
    if (!gate.ready) {
      setError(gate.message || 'Resume tailoring is not set up for your account yet.');
      return;
    }
    if (!format || format.status !== 'completed') {
      go('format');
      setNotice('Add a ready tailoring format, then return to Resume agents.');
      return;
    }
    await act('tailor', async () => {
      await tailor.start(selected.id);
      setRejected([]);
    });
  }
  async function profileLive() {
    const gate = availability('profile');
    if (!gate.ready) {
      setError(gate.message || 'Profile suggestions are not set up for your account yet.');
      return;
    }
    await act('profile', async () => {
      const run = await startRun('profile', 'self');
      setProfileRun(run.id);
    });
  }
  useEffect(() => {
    if (!real) return;
    const run = followedProfile.run;
    if (run?.status === 'completed' && run.artifacts?.profile) {
      setHeadline(run.artifacts.profile.suggested_headline || '');
      setAbout(run.artifacts.profile.suggested_about || '');
      setProfileReady(true);
      setApproved(false);
    } else if (run && ['failed', 'blocked', 'needs_input'].includes(run.status)) setError(run.message || 'Profile suggestions could not be drafted. Open Agents to see why.');
  }, [followedProfile.run?.status, followedProfile.run?.id]);
  useEffect(() => {
    if (real && view === 'changes' && task?.status === 'completed') setView('complete');
  }, [real, view, task?.status]);
  useEffect(() => {
    if (real) setRejected(task?.rejected || []);
  }, [real, task?.id]);
  function cancel() {
    if (real && task && ['queued', 'running'].includes(task.status)) tailor.cancel().catch(e => setError(describeError(e)));
    operation.current++;
    setBusy('');
    setError('');
    if (task && ['queued', 'running'].includes(task.status)) saveTask({
      ...task,
      status: 'cancelled'
    });
    setNotice('Cancelled. Your resume is unchanged.');
  }
  async function showPdf(r = resume) {
    if (real) {
      await act('preview', async valid => {
        const result = resume.tailored ? await tailoredFile(resume.id) : format?.status === 'completed' ? await formatPreview(resume.id) : {
          uri: await originalPdf(resume.id)
        };
        if (valid()) setPdf({
          uri: result.uri,
          pages: result.pages || resume.pages || 0
        });
      });
      return;
    }
    await act('preview', async valid => {
      const result = await makePdf(r);
      if (valid()) setPdf(result);
    });
  }
  async function compile(f) {
    if (real) {
      setPendingFormat(f);
      setPdf(null);
      setChecks(null);
      await act('compile', async valid => {
        if (f.kind === 'upload') await uploadSource(resume.id, f.sourceFile);else await applyTemplate(resume.id, f.template);
        await waitForFormat();
        if (valid()) setNotice('Format ready. Stack compiled it on your account.');
      });
      return;
    }
    setPendingFormat(f);
    setPdf(null);
    setChecks(null);
    await act('compile', async valid => {
      if (valid()) {
        if (!save({
          format: {
            ...f,
            status: 'completed'
          }
        })) return;
        setNotice('Format saved. Prototype compilation completed; uploaded LaTeX is retained as source.');
      }
    }, () => save({
      format: {
        ...f,
        status: 'failed'
      }
    }));
  }
  async function upload(e) {
    if (real) {
      const picked = e.target.files[0];
      e.target.value = '';
      if (!picked) return;
      setError('');
      if (picked.size > 2 * 1024 * 1024 || !/\.(tex|zip)$/i.test(picked.name)) {
        setError('Choose a .tex or Overleaf .zip of 2 MB or less.');
        return;
      }
      await compile({
        kind: 'upload',
        file: picked.name,
        sourceFile: picked
      });
      return;
    }
    const f = e.target.files[0];
    e.target.value = '';
    if (!f) return;
    setError('');
    if (f.size > 10 * 1024 * 1024 || !/\.(tex|zip)$/i.test(f.name)) {
      setError('Choose a .tex or Overleaf .zip smaller than 10 MB.');
      return;
    }
    try {
      let source,
        skipped = [];
      if (/\.zip$/i.test(f.name)) {
        const entries = unzipSync(new Uint8Array(await f.arrayBuffer()));
        const names = Object.keys(entries).filter(n => n.endsWith('.tex'));
        if (!names.length) throw Error('No .tex file found in the archive.');
        const main = names.find(n => /(^|\/)(main|resume)\.tex$/.test(n)) || names[0];
        source = strFromU8(entries[main]);
        skipped = Object.keys(entries).filter(n => n !== main);
      } else source = await f.text();
      if (!source.includes('\\begin{document}') || !source.includes('\\end{document}')) throw Error('Choose a complete LaTeX document with begin and end document.');
      await compile({
        kind: 'upload',
        file: f.name,
        source,
        skipped,
        template: 'jake'
      });
    } catch (e) {
      setError(e.message);
    }
  }
  function startTailor() {
    if (real) {
      startTailorLive();
      return;
    }
    if (!selected) return;
    if (!format || format.status !== 'completed') {
      saveTask({
        status: 'blocked',
        job: selected,
        changes: [],
        rejected: [],
        createdAt: Date.now()
      });
      go('format');
      setNotice('Add a ready tailoring format, then return to Resume agents.');
      return;
    }
    const next = {
      status: 'queued',
      job: selected,
      changes: [],
      rejected: [],
      createdAt: Date.now()
    };
    if (!saveTask(next)) return;
    setRejected([]);
    act('tailor', async valid => {
      if (!valid()) return;
      if (!saveTask({
        ...next,
        status: 'running'
      })) return;
      await pause();
      if (valid()) {
        const changes = propose(current.current, selected);
        if (!saveTask({
          ...next,
          status: 'review',
          changes
        })) return;
        go('changes');
      }
    });
  }
  function approvedDetails() {
    return applyChanges(resume.details, task?.changes || [], rejected);
  }
  async function approve() {
    if (real) {
      await act('approve', async () => {
        await tailor.approve(rejected);
        setNotice('Approved. Stack is rebuilding your tailored PDF.');
      });
      return;
    }
    await act('approve', async valid => {
      const d = approvedDetails();
      const version = {
        ...resume,
        id: String(Date.now()),
        name: `${d.name} · ${task.job.company}`,
        tailored: true,
        isDefault: false,
        details: d,
        format: tailorSource(resume, d),
        job: task.job,
        sourceName: resume.name,
        sourceId: resume.id,
        sourceDetails: {
          ...resume.details
        },
        createdAt: Date.now(),
        changes: task.changes,
        rejected: [...rejected],
        task: null,
        score: {
          before: score(resume.details, task.job),
          after: score(d, task.job)
        }
      };
      const generated = await makePdf(version);
      const parsed = await readPdf(generated.bytes);
      const baseline = await makePdf(resume);
      const original = await readPdf(baseline.bytes);
      version.pages = generated.pages;
      version.parse = compareText(d, parsed.text, original.text);
      if (valid()) {
        onTailored(version);
        if (!saveTask({
          ...task,
          status: 'completed',
          rejected,
          versionId: version.id
        })) return;
        setNotice('Approved and saved.');
        go('complete');
      }
    });
  }
  function profile() {
    if (real) {
      profileLive();
      return;
    }
    act('profile', async valid => {
      if (valid()) {
        setHeadline(`${resume.details.skills.split(',')[0] || 'Early-career professional'} · ${resume.details.education || 'Open to opportunities'}`);
        setAbout([resume.details.education, resume.details.experience].filter(Boolean).join('\n'));
        setProfileReady(true);
        setApproved(false);
      }
    });
  }
  async function check() {
    if (real) {
      await act('checks', async valid => {
        await checkTailored(resume.id);
        if (valid()) setChecks((liveState().boot?.tailored_resumes || []).find(t => t.id === resume.id)?.parse?.checks?.map(c => ({
          label: c.label,
          ok: !!c.ok,
          detail: c.detail || '',
          alsoOriginal: !!c.also_original
        })) || []);
      });
      return;
    }
    await act('checks', async valid => {
      const out = await makePdf(resume);
      const parsed = await readPdf(out.bytes);
      let original = '';
      if (resume.sourceDetails) {
        const base = await makePdf({
          ...resume,
          details: resume.sourceDetails
        });
        original = (await readPdf(base.bytes)).text;
      }
      const rows = compareText(resume.details, parsed.text, original);
      if (valid()) {
        setChecks(rows);
        save({
          parse: rows,
          pages: out.pages
        });
      }
    });
  }
  const rows = checks || resume.parse;
  const proposed = {
    ...resume,
    details: approvedDetails()
  };
  return render("resume_tools_4", {
    "s0": {
      "variant": 'resume-tools' + (disabled ? ' resume-tools-loading' : '')
    },
    "s1": view === '' ? render("resume_tools_5", {
      "s0": {},
      "s1": resume.name,
      "s2": {},
      "s3": (resume.tailored ? [['files', 'Files & checks'], ['manage', 'Manage resume']] : [['agents', 'Resume agents'], ['format', 'Tailoring format'], ['manage', 'Manage resume']]).map(([v, label]) => render("resume_tools_6", {
        "s0": {
          "key": v,
          "disabled": disabled,
          "onClick": () => go(v)
        },
        "s1": label,
        "s2": {}
      })),
      "s4": !resume.tailored && render("resume_tools_7", {
        "s0": {
          "disabled": disabled,
          "onClick": onEdit
        },
        "s1": {}
      }),
      "s5": {},
      "s6": {},
      "s7": {
        "variant": 'resume-paper ' + (format?.template || 'jake')
      },
      "s8": {},
      "s9": resume.details.name,
      "s10": {},
      "s11": [resume.details.email, resume.details.location].filter(Boolean).join(' · '),
      "s12": ['experience', 'education', 'skills'].map(k => render("resume_tools_8", {
        "s0": {
          "key": k
        },
        "s1": {},
        "s2": k,
        "s3": {},
        "s4": resume.details[k] || 'Not added'
      }))
    }) : render("resume_tools_9", {
      "s0": disabled && render("resume_tools_10", {
        "s0": {
          "role": "status"
        }
      }),
      "s1": {
        "disabled": locked,
        "aria-busy": locked,
        "aria-hidden": disabled || undefined,
        "inert": disabled ? '' : undefined
      },
      "s2": view === 'manage' && render("resume_tools_11", {
        "s0": {},
        "s1": {
          "value": name,
          "maxLength": 160,
          "onChange": e => {
            setName(e.target.value);
            setError('');
          }
        },
        "s2": {
          "onClick": () => {
            if (!name.trim() || name.length > 160) {
              setError('Enter a name of 1–160 characters.');
              return;
            }
            if (real) {
              act('rename', async () => {
                await renameResume(resume.id, name.trim());
                setNotice('Resume renamed.');
              });
              return;
            }
            if (!save({
              name: name.trim(),
              customName: true
            })) return;
            setNotice('Resume renamed.');
          }
        },
        "s3": !resume.tailored && render("resume_tools_12", {
          "s0": {
            "disabled": resume.isDefault,
            "onClick": () => {
              if (real) {
                act('default', async () => {
                  await setDefault(resume.id);
                  setNotice('Default resume updated.');
                });
                return;
              }
              if (!save({
                isDefault: true
              })) return;
              setNotice('Default resume updated.');
            }
          },
          "s1": resume.isDefault ? 'Default resume' : 'Use as default'
        }),
        "s4": {
          "onClick": () => setDeleting(true)
        },
        "s5": deleting && render("resume_tools_13", {
          "s0": {
            "role": "group",
            "aria-label": "Confirm deletion"
          },
          "s1": {},
          "s2": resume.name,
          "s3": resume.isDefault ? ' No default will be selected.' : '',
          "s4": {
            "onClick": onDelete
          },
          "s5": {
            "onClick": () => setDeleting(false)
          }
        })
      }),
      "s3": view === 'agents' && render("resume_tools_14", {
        "s0": {},
        "s1": (real ? !availability('tailoring').ready : scenario === 'unavailable') && render("resume_tools_15", {
          "s0": {
            "role": "status"
          },
          "message": real ? availability('tailoring').message || 'Resume tailoring is not set up for your account yet.' : 'Resume agents are unavailable. Configure a model provider in Agents to enable tailoring and profile suggestions.'
        }),
        "s2": {},
        "s3": {
          "value": job,
          "onChange": e => {
            setJob(e.target.value);
            setScores(null);
          }
        },
        "s4": {
          "value": ""
        },
        "s5": (real || scenario !== 'empty') && jobList.map(j => render("resume_tools_16", {
          "s0": {
            "key": j.id,
            "value": j.id
          },
          "s1": j.role,
          "s2": j.company
        })),
        "s6": (real ? !jobList.length : scenario === 'empty') && render("resume_tools_17", {
          "s0": {}
        }),
        "s7": {
          "disabled": !selected,
          "onClick": () => act('score', async valid => {
            if (real) {
              const result = await scoreFor(selected.id);
              if (valid()) setScores(scoreView(result.score));
              return;
            }
            if (valid()) setScores(score(resume.details, selected));
          })
        },
        "s8": scores && render("resume_tools_18", {
          "s0": {
            "component": Score,
            "value": scores
          }
        }),
        "s9": {
          "disabled": !selected || (real ? !availability('tailoring').ready : scenario === 'unavailable') || ['queued', 'running'].includes(task?.status),
          "onClick": startTailor
        },
        "s10": {
          "onClick": () => go('profile')
        },
        "s11": task && render("resume_tools_19", {
          "s0": {},
          "s1": {},
          "s2": {},
          "s3": task.job?.role,
          "s4": task.job?.company,
          "s5": {
            "role": "status"
          },
          "s6": {
            blocked: 'Needs a tailoring format',
            queued: 'Queued',
            running: 'Working',
            review: 'Ready for review',
            completed: 'Completed',
            cancelled: 'Cancelled',
            failed: 'Failed'
          }[task.status],
          "s7": task.status === 'review' && render("resume_tools_20", {
            "s0": {
              "onClick": () => go('changes')
            }
          }),
          "s8": task.status === 'blocked' && render("resume_tools_21", {
            "s0": {
              "onClick": () => go('format')
            }
          }),
          "s9": task.status === 'completed' && render("resume_tools_22", {
            "s0": {
              "onClick": () => onOpenTailored(task.versionId)
            }
          }),
          "s10": ['failed', 'cancelled'].includes(task.status) && render("resume_tools_23", {
            "s0": {
              "disabled": !selected,
              "onClick": startTailor
            }
          })
        }),
        "s12": {}
      }),
      "s4": view === 'changes' && task && render("resume_tools_24", {
        "s0": {},
        "s1": task.job.role,
        "s2": task.job.company,
        "s3": real ? {
          "component": task.score?.after ? Score : NoScore,
          "before": scoreView(task.score?.before),
          "value": scoreView(task.score?.after)
        } : {
          "component": Score,
          "before": score(resume.details, task.job),
          "value": score(proposed.details, task.job)
        },
        "s4": {},
        "s5": task.changes.length - rejected.length,
        "s6": task.changes.length,
        "s7": !task.changes.length && render("resume_tools_25", {
          "s0": {}
        }),
        "s8": task.changes.map(c => render("resume_tools_26", {
          "s0": {
            "key": c.id
          },
          "s1": {},
          "s2": c.kind,
          "s3": real ? c.where : c.key,
          "s4": {},
          "s5": c.reason,
          "s6": {},
          "s7": {},
          "s8": {},
          "s9": {},
          "s10": c.before,
          "s11": {},
          "s12": {},
          "s13": c.after,
          "s14": {},
          "s15": {
            "type": "checkbox",
            "checked": !rejected.includes(c.id),
            "onChange": () => {
              const next = rejected.includes(c.id) ? rejected.filter(x => x !== c.id) : [...rejected, c.id];
              setRejected(next);
              saveTask({
                ...task,
                rejected: next
              });
              setPdf(null);
            }
          }
        })),
        "s9": {},
        "s10": {},
        "s11": {},
        "s12": task.changes.some(c => c.kind === 'Trim') ? 'Only duplicate experience lines are proposed for removal. Reject the Trim change to retain them.' : 'No content is removed.',
        "s13": {},
        "s14": {},
        "s15": {},
        "s16": real ? task.changes.map(c => c.before).filter(Boolean).join('\n') : Object.values(resume.details).join('\n'),
        "s17": {},
        "s18": {},
        "s19": {},
        "s20": real ? task.changes.filter(c => !rejected.includes(c.id)).map(c => c.after).filter(Boolean).join('\n') : Object.values(proposed.details).join('\n'),
        "s21": {
          "onClick": () => real ? act('preview', async valid => {
            const out = await proposedPdf(task.run);
            if (!out) throw new Error('The proposed PDF is not available yet.');
            if (valid()) setPdf(out);
          }) : showPdf(proposed)
        },
        "s22": {},
        "s23": {
          "onClick": approve
        }
      }),
      "s5": view === 'complete' && render("resume_tools_27", {
        "s0": {},
        "s1": {},
        "s2": {
          "onClick": () => onOpenTailored(task?.versionId)
        }
      }),
      "s6": view === 'profile' && render("resume_tools_28", {
        "s0": {},
        "s1": {
          "disabled": real ? !availability('profile').ready : scenario === 'unavailable',
          "onClick": profile
        },
        "s2": profileReady ? 'Generate new suggestions' : 'Generate suggestions',
        "s3": profileReady && render("resume_tools_29", {
          "s0": {},
          "s1": {
            "value": headline,
            "onChange": e => {
              setHeadline(e.target.value);
              setApproved(false);
            }
          },
          "s2": {},
          "s3": {
            "value": about,
            "onChange": e => {
              setAbout(e.target.value);
              setApproved(false);
            }
          },
          "s4": {
            "disabled": !headline.trim() || !about.trim() || approved,
            "onClick": () => {
              if (!save({
                profileSuggestions: {
                  headline,
                  about,
                  approvedAt: Date.now()
                }
              })) return;
              setApproved(true);
              setNotice('Suggestions approved and saved with this resume.');
            }
          },
          "s5": approved ? 'Suggestions approved' : 'Approve suggestions',
          "s6": {}
        }),
        "s4": (real ? !availability('profile').ready : scenario === 'unavailable') && render("resume_tools_30", {
          "message": real ? availability('profile').message || 'Profile suggestions are not set up for your account yet.' : 'Configure a model provider in Agents to enable suggestions.',
          "s0": {}
        })
      }),
      "s7": view === 'format' && render("resume_tools_31", {
        "s0": {},
        "s1": {},
        "s2": format ? format.kind === 'upload' ? format.file : format.template === 'classic' ? 'Classic' : 'Jake’s Resume' : 'No format selected',
        "s3": format && render("resume_tools_32", {
          "s0": {
            "role": "status"
          },
          "s1": format.status === 'failed' ? 'Compilation failed — retry below' : busy === 'compile' || format.status === 'running' ? 'Compiling…' : real ? 'Ready · compiled on your Stack account' : 'Ready · prototype compilation'
        }),
        "s4": {
          "ref": file,
          "type": "file",
          "accept": ".tex,.zip",
          "hidden": true,
          "style": {
            display: 'none'
          },
          "onChange": upload
        },
        "s5": {
          "onClick": () => file.current.click()
        },
        "s6": format?.kind === 'upload' ? 'Replace LaTeX source' : 'Upload LaTeX (.tex or Overleaf .zip)',
        "s7": {},
        "s8": {},
        "s9": {
          "value": format?.kind === 'builtin' ? format.template : '',
          "onChange": e => {
            if (e.target.value) compile({
              kind: 'builtin',
              template: e.target.value
            });
          }
        },
        "s10": {
          "value": ""
        },
        "s11": {
          "value": "jake"
        },
        "s12": {
          "value": "classic"
        },
        "s13": format && render("resume_tools_33", {
          "s0": {
            "onClick": () => {
              if (real) {
                act('compile', async () => {
                  await removeFormat(resume.id);
                  setPdf(null);
                  setNotice('Format removed. Select or upload a format before tailoring.');
                });
                return;
              }
              if (!save({
                format: null
              })) return;
              setPdf(null);
              setNotice('Format removed. Select or upload a format before tailoring.');
            }
          },
          "s1": format.status === 'failed' && render("resume_tools_34", {
            "s0": {
              "onClick": () => compile(format)
            }
          }),
          "s2": format.skipped?.length > 0 && render("resume_tools_35", {
            "s0": {},
            "s1": {},
            "s2": {},
            "s3": format.skipped.join(', '),
            "s4": {}
          }),
          "s3": {
            "disabled": format.status !== 'completed',
            "onClick": () => showPdf()
          }
        }),
        "s14": task?.status === 'blocked' && format?.status === 'completed' && render("resume_tools_36", {
          "s0": {
            "onClick": () => go('agents')
          }
        })
      }),
      "s8": (view === 'files' || view === 'format') && render("resume_tools_37", {
        "s0": view === 'files' && render("resume_tools_38", {
          "s0": {},
          "s1": resume.job.role,
          "s2": resume.job.company,
          "s3": {},
          "s4": resume.createdAt ? new Date(resume.createdAt).toLocaleDateString() : 'Saved version',
          "s5": resume.pages || '—',
          "s6": resume.sourceName,
          "s7": (real ? resume.score?.after : resume.score) && render("resume_tools_39", {
            "s0": {
              "component": Score,
              "value": real ? scoreView(resume.score.after) : resume.score.after,
              "before": real ? scoreView(resume.score.before) : resume.score.before
            }
          }),
          "s8": {
            "onClick": () => showPdf()
          },
          "s9": {
            "onClick": () => act('download', async valid => {
              if (real) {
                const file = await tailoredFile(resume.id);
                const raw = atob(file.uri.split(',')[1]),
                  bytes = Uint8Array.from(raw, c => c.charCodeAt(0));
                await download(bytes, file.name || resume.name + '.pdf', 'application/pdf');
                if (valid()) setNotice('PDF prepared for export.');
                return;
              }
              const out = await makePdf(resume);
              if (valid()) {
                await download(out.bytes, resume.name + '.pdf', 'application/pdf');
                setNotice('PDF prepared for export.');
              }
            })
          }
        }),
        "s1": (format || view === 'files') && render("resume_tools_40", {
          "s0": {},
          "s1": {},
          "s2": {},
          "s3": real ? texText || 'Loading LaTeX source…' : latex(resume),
          "s4": {
            "onClick": () => act('source', async valid => {
              await download(real ? texText : latex(resume), 'resume.tex', 'text/plain');
              if(valid())setNotice('Source prepared for export.');
            })
          },
          "s5": {
            "href": "https://www.overleaf.com/project",
            "target": "_blank",
            "rel": "noreferrer",
            "onClick": e => {
              if (locked) e.preventDefault();
            }
          },
          "s6": {}
        }),
        "s2": view === 'files' && render("resume_tools_41", {
          "s0": {
            "onClick": check
          },
          "s1": rows ? 'Check again' : 'Run parser checks',
          "s2": busy !== 'checks' && rows && render("resume_tools_42", {
            "s0": {},
            "s1": {},
            "s2": rows.every(c => c.ok) ? 'PDF text checks passed' : rows.every(c => c.ok || c.alsoOriginal) ? 'No new parser issues' : 'Parser found issues',
            "s3": {},
            "s4": rows.filter(c => c.ok).length,
            "s5": rows.length,
            "s6": {},
            "s7": {},
            "s8": rows.map((c, i) => render("resume_tools_43", {
              "s0": {
                "key": i
              },
              "s1": c.ok ? '✓' : '!',
              "s2": c.label,
              "s3": c.detail,
              "s4": c.alsoOriginal ? ' · also missing from original' : ''
            })),
            "s9": {}
          })
        })
      }),
      "s9": pdf && !disabled && render("resume_tools_44", {
        "s0": {},
        "s1": {
          "onClick": () => setPdf(null)
        },
        "s2": {},
        "s3": pdf.pages,
        "s4": pdf.pages === 1 ? 'page' : 'pages',
        "s5": {
          "component": PdfPreview,
          "data": pdf.bytes,
          "uri": pdf.uri
        }
      })
    }),
    "s2": busy && render("resume_tools_45", {
      "s0": {
        "role": "status"
      },
      "s1": {},
      "s2": {
        compile: 'Compiling format…',
        tailor: 'Preparing tailoring changes…',
        approve: 'Rebuilding approved PDF and checking text…',
        profile: 'Drafting suggestions…',
        score: 'Scoring resume…',
        checks: 'Reading every PDF page…',
        preview: 'Preparing PDF preview…',
        download: 'Preparing download…'
      }[busy],
      "s3": {
        "onClick": cancel
      }
    }),
    "s3": error && render("resume_tools_46", {
      "s0": {
        "role": "alert"
      },
      "s1": {},
      "s2": error,
      "s3": {
        "disabled": locked,
        "onClick": () => {
          setError('');
          if (lastAction === 'checks') check();else if (lastAction === 'preview') showPdf();else if (lastAction === 'profile') profile();else if (lastAction === 'compile') compile(pendingFormat || format);else if (lastAction === 'approve') approve();else if (lastAction === 'tailor') startTailor();else if (lastAction === 'score' && selected) act('score', async valid => {
            if (valid()) setScores(score(resume.details, selected));
          });
        }
      }
    }),
    "s4": notice && render("resume_tools_47", {
      "s0": {
        "role": "status"
      },
      "s1": notice
    })
  });
}
