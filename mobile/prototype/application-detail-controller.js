import {useScenario} from './scenarios';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState, useEffect, useRef } from 'react';
import { ArrowLeft, ArrowUpRight, Check, ChevronRight } from 'lucide-react-native';
import { APPLICATION_STATUSES, readLibrary, saveLibrary, sampleResume, jobFor, analysisFor, ensurePlan, writeStore, storeFile, readStore, cancelTasks, resumeFingerprint } from './application-store';
import { ApplicationTask } from './application-task-controller';
import { ApplicationDocument } from './application-document-controller';
import { backend, describeError } from './backend';
import { liveState, mutate, refreshLive } from './live-store';
import { uploadPdf, saveDetails, scoreFor } from './resume-live';
import { fitOf } from './applications-live';
import { call } from './backend';
import { planFor } from './prep-live';
export function ApplicationDetail({
  item,
  onUpdate,
  onClose,
  onNavigate,
  loading = false
}) {
  // Build-time constant: live builds save to the account; mock builds keep the on-device sample behavior.
  const real = backend.live;
  const [liveFit, setLiveFit] = useState(null),
    [livePlan, setLivePlan] = useState([]);
  const plan = real ? livePlan : item.plan;
  const [view, setView] = useState('details'),
    [draft, setDraft] = useState(item),
    [error, setError] = useState(''),
    [message, setMessage] = useState(''),
    [confirmClose, setConfirmClose] = useState(false),
    [library, setLibrary] = useState(readLibrary),
    [busy, setBusy] = useState(''),
    [preview, setPreview] = useState(false),
    [reminder, setReminder] = useState(''),
    [when, setWhen] = useState(''),
    [editing, setEditing] = useState(null),
    [facts, setFacts] = useState(() => item.facts || readLibrary().find(r => r.id === (item.resume_id || item.resolvedResumeId))?.details || {}),
    [confirmed, setConfirmed] = useState(!!item.factsConfirmed || !!readLibrary().find(r => r.id === (item.resume_id || item.resolvedResumeId))?.confirmed),
    [submitConfirm, setSubmitConfirm] = useState(false);
  useEffect(() => {
    const refresh = () => setLibrary(readLibrary());
    serviceEvents.addEventListener('stack-data-changed', refresh);
    serviceEvents.addEventListener('storage', refresh);
    return () => {
      serviceEvents.removeEventListener('stack-data-changed', refresh);
      serviceEvents.removeEventListener('storage', refresh);
    };
  }, []);
  useScenario('Applications/application-detail-controller', s=>{if(s.page&&!['detail','list'].includes(s.page))setView(s.page);});
  const root = useRef(null),
    timer = useRef(null);
  const job = jobFor(item),
    resume = library.find(r => String(r.id) === String(item.resume_id || (real ? item.resolvedResumeId : ''))),
    fit = real ? liveFit : item.fit,
    dirty = draft.note !== item.note;
  useEffect(() => {
    root.current?.scrollTo?.({
      y: 0,
      animated: false
    });
    root.current?.focus?.();
    setError('');
    setMessage('');
    setPreview(false);
  }, [view]);
  useEffect(() => {
    if (real) return;
    const current = item.factsConfirmed ? item.facts : resume?.confirmed ? resume.details : null;
    const taskChanged = ['task', 'tailorTask'].some(key => item[key] && item[key].status !== 'cancelled' && item[key].resumeFingerprint !== resumeFingerprint(resume));
    const fitChanged = item.fit && item.fit.fingerprint !== JSON.stringify(current || {});
    if (taskChanged || fitChanged) update({
      fit: null,
      ...(taskChanged ? cancelTasks(item, 'Resume library changed; review required') : {})
    });
  }, [resume, item.facts, item.factsConfirmed]);
  useEffect(() => {
    if (error || confirmClose) root.current?.scrollTo?.({
      y: 0,
      animated: false
    });
  }, [error, confirmClose]);
  useEffect(() => () => clearTimeout(timer.current), []);
  function update(patch) {
    if (real) {
      applyLive(patch);
      setDraft(current => ({
        ...current,
        ...patch
      }));
      return item;
    }
    try {
      const next = {
        ...item,
        ...patch
      };
      onUpdate(next);
      setDraft(current => ({
        ...current,
        ...patch
      }));
      setError('');
      return next;
    } catch {
      setError('Could not save on this device. Your changes are still here. Free up browser storage and retry.');
      return null;
    }
  }
  // Live: a screen change becomes the matching account call. Errors show on this screen; the snapshot then refreshes.
  function failLive(e) {
    setError(describeError(e));
  }
  function applyLive(patch) {
    if ('note' in patch) mutate('save_application', {
      id: item.id,
      notes: patch.note
    }).catch(failLive);
    if ('resume_id' in patch) mutate('select_application_resume', {
      id: item.id,
      resume_id: patch.resume_id
    }).catch(failLive);
    if (patch.status === 'Submitted') mutate('mark_application_submitted', {
      id: item.id
    }).catch(failLive);else if ('status' in patch) setError('Stack records Assessment, Interview and Rejected from your connected email. Only Submitted can be set by hand.');
    if (patch.reminders) syncReminders(item.reminders || [], patch.reminders);
    if ('fit' in patch && !patch.fit) setLiveFit(null);
  }
  function syncReminders(before, after) {
    const known = new Map(before.map(r => [r.id, r]));
    for (const r of after) {
      const old = known.get(r.id);
      const due = Math.floor(new Date(r.when).getTime() / 1000);
      if (!old) mutate('save_reminder', {
        id: '',
        target_type: 'application',
        target_id: item.id,
        title: r.title,
        due_at: due
      }).catch(failLive);else if (r.done && !old.done) mutate('change_reminder', {
        id: r.id,
        action: 'complete'
      }).catch(failLive);else if (!r.done && (r.title !== old.title || r.when !== old.when)) mutate('save_reminder', {
        id: r.id,
        target_type: 'application',
        target_id: item.id,
        title: r.title,
        due_at: due
      }).catch(failLive);
    }
    for (const old of before) if (!after.some(r => r.id === old.id)) mutate('change_reminder', {
      id: old.id,
      action: 'delete'
    }).catch(failLive);
  }
  async function saveLive() {
    if (draft.note.length > 5000) {
      setError('Keep notes under 5,000 characters.');
      return false;
    }
    try {
      setBusy('Saving notes…');
      await mutate('save_application', {
        id: item.id,
        notes: draft.note
      });
      setBusy('');
      setMessage('Notes saved');
      return true;
    } catch (e) {
      setBusy('');
      failLive(e);
      return false;
    }
  }
  async function runFit() {
    setError('');
    setBusy('Comparing requirements and evidence…');
    try {
      const result = await scoreFor(item.id);
      setLiveFit(fitOf(result, resume?.name || 'Your resume'));
    } catch (e) {
      failLive(e);
    } finally {
      setBusy('');
    }
  }
  async function saveFacts() {
    try {
      setBusy('Saving confirmed facts…');
      await saveDetails(resume.id, {
        ...resume.details,
        ...facts
      }, true);
      setLiveFit(null);
      setMessage('Confirmed facts saved.');
    } catch (e) {
      failLive(e);
    } finally {
      setBusy('');
    }
  }
  async function uploadLive(file) {
    if (!file) return;
    try {
      if (!/\.pdf$/i.test(file.name) || file.size > 10485760) throw new Error('Choose a valid PDF, 10 MB or smaller.');
      setBusy('Uploading your PDF…');
      const id = await uploadPdf(file);
      await mutate('select_application_resume', {
        id: item.id,
        resume_id: id
      });
      setLiveFit(null);
      setMessage('PDF added to your Resume library and attached. Confirm its details in Resume before analysis.');
    } catch (e) {
      failLive(e);
    } finally {
      setBusy('');
    }
  }
  function save() {
    if (real) {
      saveLive();
      return false;
    }
    if (draft.note.length > 5000) {
      setError('Keep notes under 5,000 characters.');
      return false;
    }
    if (!update({
      note: draft.note
    })) return false;
    setMessage('Notes saved');
    return true;
  }
  function back() {
    clearTimeout(timer.current);
    setBusy('');
    if (view === 'details') {
      if (dirty) setConfirmClose(true);else onClose();
    } else setView('details');
  }
  function open(name) {
    if (dirty) {
      setError('Save or discard your notes before opening a workflow.');
      return;
    }
    setView(name);
  }
  function work(label, done) {
    setError('');
    setBusy(label);
    timer.current = setTimeout(() => {
      setBusy('');
      if (!services.online) {
        setError('You appear to be offline. Reconnect and try again.');
        return;
      }
      done();
    }, 900);
  }
  function chooseResume(id) {
    if (real) {
      const chosen = library.find(r => r.id === id);
      setLiveFit(null);
      mutate('select_application_resume', {
        id: item.id,
        resume_id: id
      }).then(() => {
        setMessage(id ? 'Resume attached' : 'Resume detached');
        if (chosen?.confirmed) {
          setFacts(chosen.details || {});
          setConfirmed(true);
        }
      }).catch(failLive);
      return;
    }
    const changed = id !== item.resume_id;
    const chosen = library.find(r => r.id === id);
    if (update({
      resume_id: id,
      ...(changed ? cancelTasks(item) : {}),
      fit: changed ? null : item.fit,
      task: changed && item.task ? {
        ...item.task,
        status: 'cancelled',
        approvals: {},
        events: [...item.task.events, {
          label: 'Resume changed; approval invalidated',
          at: Date.now()
        }]
      } : item.task
    })) {
      setMessage(id ? 'Resume attached' : 'Resume detached');
      if (chosen?.confirmed) {
        setFacts(chosen.details || {});
        setConfirmed(true);
      }
    }
  }
  function addSample() {
    try {
      const next = library.some(r => r.id === sampleResume.id) ? library : [...library, sampleResume];
      saveLibrary(next);
      setLibrary(next);
      if (update({
        resume_id: sampleResume.id,
        ...cancelTasks(item),
        fit: null,
        task: item.task ? {
          ...item.task,
          status: 'cancelled',
          approvals: {}
        } : null
      })) {
        setFacts(sampleResume.details);
        setConfirmed(true);
        setMessage('Sample resume added to the shared Resume library.');
      }
    } catch {
      setError('Could not save the sample resume.');
    }
  }
  async function upload(file) {
    if (real) {
      await uploadLive(file);
      return;
    }
    if (!file) return;
    try {
      if (!/\.pdf$/i.test(file.name) || file.size > 10485760 || (await file.slice(0, 5).text()) !== '%PDF-') throw new Error('Choose a valid PDF, 10 MB or smaller.');
      const id = 'resume-' + services.id();
      await storeFile(id, file);
      const record = {
        id,
        name: file.name,
        kind: 'upload',
        blobId: id,
        confirmed: false,
        details: {},
        size: file.size
      };
      const next = [...library, record];
      saveLibrary(next);
      setLibrary(next);
      update({
        resume_id: id,
        ...cancelTasks(item),
        fit: null,
        task: item.task ? {
          ...item.task,
          status: 'cancelled',
          approvals: {}
        } : null
      });
      setMessage('PDF saved on this device and attached. Confirm its facts before analysis.');
      setFacts({});
      setConfirmed(false);
    } catch (e) {
      setError(e.message || 'Could not store this PDF. Try again.');
    }
  }
  function setStage(status, source = 'User confirmed') {
    if (real) {
      if (status !== 'Submitted') {
        setError('Stack records Assessment, Interview and Rejected from your connected email. Only Submitted can be set by hand.');
        return;
      }
      mutate('mark_application_submitted', {
        id: item.id
      }).then(() => setMessage('Marked as submitted.')).catch(failLive);
      return;
    }
    update({
      status,
      history: [...(item.history || []), {
        status,
        date: new Date().toLocaleString(),
        source
      }],
      next: status === 'Submitted' ? 'Waiting to hear back' : status === 'Rejected' ? 'Application closed' : status === 'Interview' ? 'Add interview details to your notes' : 'Check your application for the next step'
    });
  }
  function buildPlan() {
    if (real) {
      setError('');
      setBusy('Selecting practice sessions…');
      planFor(item.id).then(rows => {
        setLivePlan(rows);
        setMessage(rows.length + ' practice sessions ready in Prep.');
      }).catch(failLive).finally(() => setBusy(''));
      return;
    }
    work('Selecting practice sessions…', () => {
      try {
        const plan = ensurePlan(item);
        if (update({
          plan
        })) {
          setMessage(plan.length + ' practice sessions ready in Prep.');
        }
      } catch {
        setError('Could not save the interview plan. Please retry.');
      }
    });
  }
  function handoff() {
    if (real) {
      planFor(item.id).then(rows => {
        setLivePlan(rows);
        writeStore('stack.prep.handoff.v2', item.id);
        onNavigate('Prep');
      }).catch(failLive);
      return;
    }
    try {
      ensurePlan(item);
      writeStore('stack.prep.handoff.v2', item.id);
      onNavigate('Prep');
    } catch {
      setError('Could not save your Prep handoff. Please retry.');
    }
  }
  const fitFacts = item.factsConfirmed ? item.facts : resume?.confirmed ? resume.details : null;
  return render("application_detail_1", {
    "s0": {},
    "s1": {
      "ref": root,
      "role": "region",
      "aria-label": view === 'details' ? 'Application details' : view
    },
    "s2": {},
    "s3": {
      "aria-label": view === 'details' ? 'Back to applications' : 'Back to application',
      "onClick": back
    },
    "s4": {
      "component": ArrowLeft,
      "size": 20
    },
    "s5": {},
    "s6": view === 'details' ? 'Application details' : view,
    "s7": {},
    "s8": {},
    "s9": item.company,
    "s10": {},
    "s11": item.role,
    "s12": {},
    "s13": item.location,
    "s14": item.pay,
    "s15": confirmClose && render("application_detail_2", {
      "s0": {
        "role": "alert"
      },
      "s1": {},
      "s2": {
        "onClick": () => {
          if (real) saveLive().then(ok => ok && onClose());else if (save()) onClose();
        }
      },
      "s3": {
        "onClick": onClose
      },
      "s4": {
        "onClick": () => setConfirmClose(false)
      }
    }),
    "s16": !loading && error && render("application_detail_3", {
      "s0": {
        "role": "alert"
      },
      "s1": error
    }),
    "s17": !loading && message && render("application_detail_4", {
      "s0": {
        "role": "status"
      },
      "s1": message
    }),
    "s18": loading && render("application_detail_5", {
      "s0": {
        "role": "status"
      },
      "s1": view === 'details' ? 'application details' : view.toLowerCase()
    }),
    "s19": {
      "inert": loading,
      "aria-hidden": loading || undefined,
      "aria-busy": loading || !!busy,
      "variant": loading ? 'application-held-loading' : undefined
    },
    "s20": busy ? render("application_detail_6", {
      "s0": {
        "role": "status"
      },
      "s1": {},
      "s2": busy,
      "s3": {},
      "s4": {}
    }) : render("application_detail_7", {
      "s0": view === 'details' && render("application_detail_8", {
        "s0": {},
        "s1": {},
        "s2": {},
        "s3": item.status,
        "s4": {},
        "s5": item.next,
        "s6": {},
        "s7": ['Explain my fit', 'Tailor my resume', 'Follow-ups', 'Build interview plan'].map(name => render("application_detail_9", {
          "s0": {
            "key": name,
            "onClick": () => open(name)
          },
          "s1": {},
          "s2": name,
          "s3": name === 'Prepare & apply' && item.task && render("application_detail_10", {
            "s0": {},
            "s1": item.task.status.replace('_', ' '),
            "s2": item.task.step
          }),
          "s4": {
            "component": ChevronRight,
            "size": 17
          }
        })),
        "s8": {},
        "s9": {},
        "s10": {},
        "s11": job.experience,
        "s12": {},
        "s13": {},
        "s14": job.responsibilities.map(x => render("application_detail_11", {
          "s0": {
            "key": x
          },
          "s1": x
        })),
        "s15": {},
        "s16": {},
        "s17": job.requirements.map(([key, text]) => render("application_detail_12", {
          "s0": {
            "key": key
          },
          "s1": text
        })),
        "s18": {
          "href": job.url,
          "target": "_blank",
          "rel": "noreferrer"
        },
        "s19": {
          "component": ArrowUpRight,
          "size": 15
        },
        "s20": {},
        "s21": real ? (job.active ? 'Source: ' : 'No longer verified active · ') + job.source : job.active ? 'Active demo' : 'Closed demo',
        "s22": {
          "open": true
        },
        "s23": {},
        "s24": dirty ? ' · Unsaved notes' : '',
        "s25": {},
        "s26": {
          "aria-label": "Attached resume",
          "value": item.resume_id || (real ? item.resolvedResumeId : ''),
          "onChange": e => chooseResume(e.target.value)
        },
        "s27": {
          "value": ""
        },
        "s28": library.map(r => render("application_detail_13", {
          "s0": {
            "value": r.id,
            "key": r.id
          },
          "s1": r.name
        })),
        "s29": resume ? render("application_detail_14", {
          "s0": {},
          "s1": resume.confirmed ? 'Confirmed details' : 'Facts need confirmation',
          "s2": resume.sample ? 'Sample resume' : 'Shared Resume library',
          "s3": {
            "onClick": () => setPreview(!preview)
          }
        }) : render("application_detail_15", {
          "s0": {}
        }),
        "s30": preview && render("application_detail_16", {
          "s0": {
            "component": ApplicationDocument,
            "resume": resume,
            "onClose": () => setPreview(false)
          }
        }),
        "s31": {},
        "s32": {
          "type": "file",
          "aria-label": "Attach resume",
          "accept": ".pdf,application/pdf",
          "onChange": e => upload(e.target.files[0])
        },
        "s33": {
          "omit": real,
          "onClick": addSample
        },
        "s34": {
          "onClick": () => {
            if (dirty) {
              setError('Save or discard your notes before opening Resume.');
              return;
            }
            onNavigate('Resume');
          }
        },
        "s35": {},
        "s36": {
          "maxLength": 5000,
          "value": draft.note,
          "onChange": e => setDraft({
            ...draft,
            note: e.target.value
          })
        },
        "s37": {
          "onClick": save
        },
        "s38": {
          "component": Check,
          "size": 16
        },
        "s39": dirty && render("application_detail_17", {
          "s0": {
            "onClick": () => setDraft(item)
          }
        }),
        "s40": {},
        "s41": {},
        "s42": !(item.history || []).length ? render("application_detail_18", {
          "s0": {}
        }) : render("application_detail_19", {
          "s0": {},
          "s1": item.history.map((h, i) => render("application_detail_20", {
            "s0": {
              "key": i
            },
            "s1": {},
            "s2": h.status,
            "s3": {},
            "s4": h.date,
            "s5": h.source || 'Imported sample',
            "s6": h.evidence && render("application_detail_21", {
              "s0": {},
              "s1": h.evidence
            })
          }))
        }),
        "s43": {},
        "s44": {},
        "s45": {
          "aria-label": "Confirmed stage",
          "value": item.status,
          "onChange": e => setStage(e.target.value)
        },
        "s46": (real ? [...new Set(['Ready to apply', 'Submitted', item.status])] : APPLICATION_STATUSES).map(s => render("application_detail_22", {
          "s0": {
            "key": s
          },
          "s1": s
        })),
        "s47": item.status === 'Ready to apply' && render("application_detail_23", {
          "s0": {
            "onClick": () => setSubmitConfirm(!submitConfirm)
          },
          "s1": submitConfirm && render("application_detail_24", {
            "s0": {},
            "s1": {},
            "s2": {
              "onClick": () => {
                setStage('Submitted');
                setSubmitConfirm(false);
              }
            },
            "s3": {
              "onClick": () => setSubmitConfirm(false)
            }
          })
        })
      }),
      "s1": view === 'Explain my fit' && render("application_detail_25", {
        "s0": {},
        "s1": {},
        "s2": {
          "open": !fitFacts
        },
        "s3": {},
        "s4": ['name', 'email', 'experience', 'education', 'skills'].map(key => render("application_detail_26", {
          "s0": {
            "key": key
          },
          "s1": key,
          "s2": {
            "value": facts[key] || '',
            "onChange": e => {
              setFacts({
                ...facts,
                [key]: e.target.value
              });
              setConfirmed(false);
            }
          }
        })),
        "s5": {},
        "s6": {
          "type": "checkbox",
          "checked": confirmed,
          "onChange": e => setConfirmed(e.target.checked)
        },
        "s7": {
          "disabled": !confirmed || !Object.values(facts).some(v => v.trim()),
          "onClick": () => {
            if (real) {
              saveFacts();
              return;
            }
            if (update({
              facts,
              factsConfirmed: true,
              ...cancelTasks(item),
              fit: null,
              task: item.task ? {
                ...item.task,
                status: 'cancelled',
                approvals: {}
              } : null
            })) setMessage('Confirmed facts saved.');
          }
        },
        "s8": !fitFacts ? render("application_detail_27", {
          "s0": {}
        }) : render("application_detail_28", {
          "s0": {
            "onClick": () => real ? runFit() : work('Comparing requirements and evidence…', () => update({
              fit: analysisFor(item, fitFacts, item.factsConfirmed ? 'Confirmed profile facts' : resume.name)
            }))
          },
          "s1": fit ? 'Refresh fit analysis' : 'Analyze fit'
        }),
        "s9": fit?.checks && render("application_detail_29", {
          "s0": {},
          "s1": {},
          "s2": fit.summary,
          "s3": fit.checks.map((c, i) => render("application_detail_30", {
            "s0": {
              "key": i
            },
            "s1": {},
            "s2": c.requirement,
            "s3": {},
            "s4": {},
            "s5": c.result,
            "s6": {},
            "s7": c.listingQuote,
            "s8": {},
            "s9": c.quote ? render("application_detail_31", {
              "s0": {},
              "s1": c.quote,
              "s2": {},
              "s3": c.source
            }) : render("application_detail_32", {
              "s0": {}
            })
          })),
          "s4": {},
          "s5": {},
          "s6": fit.unknowns.map(x => render("application_detail_33", {
            "s0": {
              "key": x
            },
            "s1": x
          })),
          "s7": {},
          "s8": {},
          "s9": {
            "onClick": () => setView('Tailor my resume')
          }
        })
      }),
      "s2": ['Prepare & apply', 'Tailor my resume'].includes(view) && render("application_detail_34", {
        "s0": {
          "component": ApplicationTask,
          "key": view,
          "kind": view === 'Tailor my resume' ? 'resume' : 'application',
          "item": view === 'Tailor my resume' ? {
            ...item,
            task: item.tailorTask
          } : item,
          "resume": resume,
          "facts": fitFacts || {},
          "update": patch => view === 'Tailor my resume' ? update({
            tailorTask: patch.task
          }) : update(patch),
          "onResume": () => setView('details'),
          "onFit": () => setView('Explain my fit'),
          "onLibrary": () => {
            try {
              writeStore('stack.resume.handoff.v1', 'Tailored');
              onNavigate('Resume');
            } catch {
              setError('Could not open the Resume handoff. Please retry.');
            }
          },
          "loading": loading
        }
      }),
      "s3": view === 'Follow-ups' && render("application_detail_35", {
        "s0": {},
        "s1": {},
        "s2": !(item.reminders || []).length && render("application_detail_36", {
          "s0": {}
        }),
        "s3": (item.reminders || []).map(r => render("application_detail_37", {
          "s0": {
            "key": r.id
          },
          "s1": {},
          "s2": r.title,
          "s3": {},
          "s4": new Date(r.when).toLocaleString(),
          "s5": r.done ? 'Completed' : new Date(r.when) < new Date() ? 'Overdue' : 'Scheduled',
          "s6": {},
          "s7": !r.done && render("application_detail_38", {
            "s0": {
              "onClick": () => {
                if (update({
                  reminders: item.reminders.map(x => x.id === r.id ? {
                    ...x,
                    done: true
                  } : x)
                })) setMessage('Follow-up completed');
              }
            }
          }),
          "s8": {
            "onClick": () => {
              setEditing(r.id);
              setReminder(r.title);
              setWhen(r.when);
            }
          },
          "s9": {
            "onClick": () => {
              if (update({
                reminders: item.reminders.filter(x => x.id !== r.id)
              }) && editing === r.id) {
                setEditing(null);
                setReminder('');
                setWhen('');
              }
            }
          }
        })),
        "s4": {},
        "s5": {
          "value": reminder,
          "maxLength": 160,
          "onChange": e => setReminder(e.target.value)
        },
        "s6": {},
        "s7": {
          "type": "datetime-local",
          "value": when,
          "onChange": e => setWhen(e.target.value)
        },
        "s8": {
          "onClick": () => {
            if (!reminder.trim() || !Number.isFinite(new Date(when).getTime()) || new Date(when) <= new Date()) {
              setError('Add a reminder and choose a future date and time.');
              return;
            }
            if (!update({
              reminders: editing ? item.reminders.map(r => r.id === editing ? {
                ...r,
                title: reminder.trim(),
                when,
                done: false
              } : r) : [...(item.reminders || []), {
                id: services.id(),
                title: reminder.trim(),
                when,
                done: false,
                target_type: 'application',
                target_id: item.id
              }]
            })) return;
            setEditing(null);
            setReminder('');
            setWhen('');
            setMessage('Reminder saved');
          }
        },
        "s9": editing ? 'Save reminder' : 'Add reminder',
        "s10": editing && render("application_detail_39", {
          "s0": {
            "onClick": () => {
              setEditing(null);
              setReminder('');
              setWhen('');
            }
          }
        })
      }),
      "s4": view === 'Build interview plan' && render("application_detail_40", {
        "s0": {},
        "s1": item.company,
        "s2": {},
        "s3": !plan?.[0]?.session_id ? render("application_detail_41", {
          "s0": {
            "onClick": buildPlan
          }
        }) : render("application_detail_42", {
          "s0": {},
          "s1": plan.map(s => render("application_detail_43", {
            "s0": {
              "key": s.session_id
            },
            "s1": {},
            "s2": s.title,
            "s3": {},
            "s4": s.reason,
            "s5": {},
            "s6": s.minutes,
            "s7": s.language ? ' · ' + s.language : ''
          })),
          "s2": item.note && render("application_detail_44", {
            "s0": {},
            "s1": item.note
          }),
          "s3": {
            "onClick": handoff
          },
          "s4": {
            "component": ArrowUpRight,
            "size": 17
          },
          "s5": {
            "onClick": buildPlan
          },
          "s6": {}
        })
      })
    })
  });
}
