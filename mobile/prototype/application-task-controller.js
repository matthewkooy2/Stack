import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import { TaskScenarios } from './review-controls';
import { formatOf, applicationTailoredResume } from './resume-model';
import React, { useEffect, useState } from 'react';
import { createTask, tickTask, approveTask, jobFor, readLibrary, saveLibrary } from './application-store';
import { ApplicationDocument } from './application-document-controller';
import { backend, describeError } from './backend';
import { useApplicationTask } from './task-live';
const stepLabels = {
  inspect: 'Read form',
  fit: 'Explain fit',
  tailor: 'Tailor resume',
  approve_resume: 'Review resume',
  fill: 'Review & fill',
  submit: 'Review & submit'
};
export function ApplicationTask({
  item,
  resume,
  facts,
  update,
  onResume,
  onFit,
  onLibrary,
  loading,
  kind = 'application'
}) {
  // Build-time constant: live builds run these tasks as assistant runs on the account; mock builds simulate them.
  const real = backend.live;
  const live = useApplicationTask({
    enabled: real,
    item,
    kind
  });
  const [kept, setKept] = useState({});
  const task = real ? live.task ? {
    ...live.task,
    changes: live.task.changes.map(c => ({
      ...c,
      kept: kept[c.id] ?? c.kept
    }))
  } : null : item.task,
    [error, setError] = useState(''),
    [preview, setPreview] = useState(false),
    [approved, setApproved] = useState(false),
    [answers, setAnswers] = useState(task?.answers || {}),
    [evidence, setEvidence] = useState('');
  const job = jobFor(item);
  function commit(next, extra = {}) {
    const success = update({
      task: next,
      ...extra
    });
    if (success) {
      setError('');
      setApproved(false);
    }
    return success;
  }
  useEffect(() => {
    setAnswers(task?.answers || {});
    setApproved(false);
  }, [task?.status, task?.step, task?.id]);
  useEffect(() => {
    if (real || !task || !['queued', 'running'].includes(task.status)) return;
    const timer = setTimeout(() => {
      const next = tickTask(task);
      commit(next);
    }, Math.max(0, (task.due || Date.now()) - Date.now()));
    return () => clearTimeout(timer);
  }, [task]);
  // Live: each button is one explicit call on the account; failures show here and nothing else runs.
  async function liveAct(work) {
    setError('');
    try {
      await work();
    } catch (e) {
      setError(describeError(e));
    }
  }
  function start() {
    if (real) {
      if (!resume) {
        onResume();
        return;
      }
      const gate = live.availability();
      if (!gate.ready) {
        setError(gate.message || 'This assistant is not set up for your account yet.');
        return;
      }
      liveAct(() => live.start());
      return;
    }
    if (!resume) {
      onResume();
      return;
    }
    if (!job.active) {
      setError('This sample listing is closed. You can still review its history and prepare for interviews.');
      return;
    }
    if (formatOf(resume)?.status !== 'completed') {
      commit({
        ...createTask(item, resume, facts, kind),
        status: 'blocked',
        message: 'Choose a resume format before tailoring.',
        blocker: 'format',
        resumeFrom: 'queued'
      });
      return;
    }
    commit(createTask(item, resume, facts, kind));
  }
  function retry() {
    if (real) {
      if (task?.blocker === 'format') onResume();else liveAct(() => task.status === 'needs_input' ? live.resume() : live.retry());
      return;
    }
    if (!task) return;
    commit({
      ...task,
      status: task.resumeFrom || 'queued',
      due: Date.now() + 800,
      message: '',
      blocker: ''
    });
  }
  function approve() {
    if (real) {
      liveAct(() => live.approve(task.changes.filter(c => !c.kept).map(c => c.id)));
      return;
    }
    try {
      const next = approveTask(task);
      if (next.kind === 'resume' && next.status === 'completed') {
        const record = applicationTailoredResume(next, item, resume);
        const existing = readLibrary();
        saveLibrary([...existing.filter(r => r.id !== record.id), record]);
      }
      commit(next);
    } catch (e) {
      setError(e.message);
    }
  }
  function scenario(value) {
    if (!task) {
      setError('Start preparation before selecting a task scenario.');
      return;
    }
    if (value === 'normal') {
      retry();
      return;
    }
    const checkpoint = ['queued', 'running', 'review'].includes(task.status) ? task.status : 'queued';
    commit({
      ...task,
      status: value,
      resumeFrom: checkpoint,
      message: {
        blocked: 'Browser connection is unavailable.',
        failed: 'The sample worker stopped before completing this step.',
        uncertain: 'The submission response was lost. Check before continuing.',
        needs_input: 'Confirm the missing answers.'
      }[value],
      step: value === 'uncertain' ? 'submit' : task.step
    });
  }
  const toolbar = true;
  return render("application_task_1", {
    "s0": {
      "omit": real,
      "component": TaskScenarios,
      "kind": kind,
      "onChange": scenario
    },
    "s1": {},
    "s2": error && render("application_task_2", {
      "s0": {
        "role": "alert"
      },
      "s1": error
    }),
    "s3": !task || task.status === 'cancelled' ? render("application_task_3", {
      "s0": {},
      "s1": task ? 'Task cancelled' : kind === 'resume' ? 'Tailor your resume' : 'Prepare your application',
      "s2": {},
      "s3": kind === 'resume' ? 'Review each wording change and save a separate tailored version. Your original stays unchanged.' : 'Review your tailored resume, then approve filling and submission separately.',
      "s4": {},
      "s5": Object.entries(stepLabels).filter(([key]) => kind !== 'resume' || ['tailor', 'approve_resume'].includes(key)).map(([key, label]) => label).map(label => render("application_task_4", {
        "s0": {
          "key": label
        },
        "s1": label
      })),
      "s6": {
        "disabled": !job.active,
        "onClick": start
      },
      "s7": resume ? kind === 'resume' ? 'Start tailoring' : 'Start preparation' : 'Choose a resume',
      "s8": !job.active && render("application_task_5", {
        "s0": {}
      })
    }) : render("application_task_6", {
      "s0": {},
      "s1": {},
      "s2": stepLabels[task.step],
      "s3": {},
      "s4": task.status.replace('_', ' '),
      "s5": {},
      "s6": task.resumeName,
      "s7": task.destination,
      "s8": ['queued', 'running'].includes(task.status) && render("application_task_7", {
        "s0": {
          "role": "status"
        },
        "s1": {},
        "s2": task.status === 'queued' ? 'Queued for preparation…' : stepLabels[task.step] + '…',
        "s3": {},
        "s4": {}
      }),
      "s9": task.status === 'review' && task.step === 'approve_resume' && render("application_task_8", {
        "s0": {},
        "s1": {},
        "s2": task.changes.map(c => render("application_task_9", {
          "s0": {
            "key": c.id
          },
          "s1": {},
          "s2": {},
          "s3": c.before,
          "s4": {},
          "s5": {},
          "s6": c.after,
          "s7": {},
          "s8": {
            "type": "checkbox",
            "checked": c.kept,
            "onChange": e => real ? setKept({
              ...kept,
              [c.id]: e.target.checked
            }) : commit({
              ...task,
              changes: task.changes.map(x => x.id === c.id ? {
                ...x,
                kept: e.target.checked
              } : x),
              approvals: {}
            })
          }
        })),
        "s3": {
          "onClick": () => setPreview(!preview)
        },
        "s4": preview ? 'Hide' : 'Preview',
        "s5": {
          "onClick": approve
        },
        "s6": {
          "onClick": onFit
        }
      }),
      "s10": task.status === 'needs_input' && render("application_task_10", {
        "s0": {},
        "s1": {},
        "s2": (real ? task.requests.map(r => [r.key, r.label]) : [['name', 'Full name'], ['email', 'Email'], ['authorization', 'Work authorization / sponsorship']]).map(([key, label]) => render("application_task_11", {
          "s0": {
            "key": key
          },
          "s1": label,
          "s2": {
            "value": answers[key] || '',
            "onChange": e => setAnswers({
              ...answers,
              [key]: e.target.value
            })
          }
        })),
        "s3": {
          "onClick": () => {
            if (real) {
              const values = task.requests.map(r => ({
                key: r.key,
                value: (answers[r.key] || '').trim(),
                source: 'User confirmed'
              })).filter(v => v.value);
              if (values.length !== task.requests.length) {
                setError('Answer every question Stack listed before continuing.');
                return;
              }
              liveAct(() => live.respond(values));
              return;
            }
            if (!answers.name?.trim() || !/^\S+@\S+\.\S+$/.test(answers.email || '') || !answers.authorization?.trim()) {
              setError('Add your name, a valid email, and work authorization answer.');
              return;
            }
            commit({
              ...task,
              answers,
              status: 'review',
              step: 'fill',
              approvals: {
                ...task.approvals,
                fill: null,
                submit: null
              }
            });
          }
        }
      }),
      "s11": task.status === 'review' && ['fill', 'submit'].includes(task.step) && render("application_task_12", {
        "s0": {},
        "s1": task.step === 'fill' ? 'Review what will be entered' : 'Review before submission',
        "s2": {},
        "s3": Object.entries(task.answers).map(([key, value]) => render("application_task_13", {
          "s0": {
            "key": key
          },
          "s1": {},
          "s2": key === 'authorization' ? 'Work authorization' : key,
          "s3": {},
          "s4": value || 'Not provided'
        })),
        "s4": {},
        "s5": {},
        "s6": {},
        "s7": task.resumeName,
        "s8": task.changes.filter(c => c.kept).length,
        "s9": {
          "onClick": () => setPreview(!preview)
        },
        "s10": {
          "omit": real,
          "onClick": () => commit({
            ...task,
            status: 'needs_input',
            approvals: {
              ...task.approvals,
              fill: null,
              submit: null
            }
          })
        },
        "s11": {},
        "s12": {
          "type": "checkbox",
          "checked": approved,
          "onChange": e => setApproved(e.target.checked)
        },
        "s13": real ? task.step === 'fill' ? 'I approve entering these answers and this document in the application form.' : 'I approve submitting this application. This cannot be undone.' : task.step === 'fill' ? 'I approve entering these answers and this document in the simulation.' : 'I approve this separate simulated submission.',
        "s14": {
          "disabled": !approved,
          "onClick": approve
        },
        "s15": real ? task.step === 'fill' ? 'Approve fill' : 'Approve submission' : task.step === 'fill' ? 'Approve simulated fill' : 'Approve simulated submission',
        "s16": {
          "href": task.destination,
          "target": "_blank",
          "rel": "noreferrer"
        },
        "s17": {}
      }),
      "s12": task.status === 'blocked' && render("application_task_14", {
        "s0": {
          "role": "alert"
        },
        "s1": task.message,
        "s2": task.blocker === 'format' ? render("application_task_15", {
          "s0": {},
          "s1": {
            "onClick": () => {
              try {
                const ready = {
                  ...resume,
                  format: {
                    kind: 'builtin',
                    template: 'jake',
                    status: 'completed'
                  }
                };
                saveLibrary(readLibrary().map(r => r.id === ready.id ? ready : r));
                commit({
                  ...createTask(item, ready, facts, kind),
                  status: 'queued'
                });
              } catch {
                setError('Could not save the format. Please retry.');
              }
            }
          }
        }) : render("application_task_16", {
          "s0": {
            "onClick": retry
          }
        }),
        "s3": {
          "href": job.url,
          "target": "_blank",
          "rel": "noreferrer"
        }
      }),
      "s13": task.status === 'failed' && render("application_task_17", {
        "s0": {
          "role": "alert"
        },
        "s1": task.message,
        "s2": {
          "onClick": retry
        }
      }),
      "s14": task.status === 'uncertain' && render("application_task_18", {
        "s0": {},
        "s1": task.message,
        "s2": {},
        "s3": {},
        "s4": {
          "value": evidence,
          "onChange": e => setEvidence(e.target.value),
          "placeholder": "Describe the confirmation or application history you checked."
        },
        "s5": {
          "disabled": evidence.trim().length < 10,
          "onClick": () => real ? liveAct(() => live.reconcile('confirmed', evidence.trim())) : commit({
            ...task,
            status: 'completed',
            receipt: 'SIM-CONFIRMED-' + task.id,
            events: [...task.events, {
              label: 'User reconciled simulated outcome: ' + evidence,
              at: Date.now()
            }]
          })
        },
        "s6": {
          "disabled": evidence.trim().length < 10,
          "onClick": () => real ? liveAct(() => live.reconcile('not_sent', evidence.trim())) : commit({
            ...task,
            status: 'review',
            step: 'submit',
            approvals: {
              ...task.approvals,
              submit: null
            },
            events: [...task.events, {
              label: 'User confirmed nothing sent: ' + evidence,
              at: Date.now()
            }]
          })
        }
      }),
      "s15": task.status === 'completed' && task.kind === 'resume' ? render("application_task_19", {
        "s0": {
          "role": "status"
        },
        "s1": {},
        "s2": {
          "onClick": onLibrary
        },
        "s3": {
          "onClick": start
        }
      }) : task.status === 'completed' && render("application_task_20", {
        "s0": {
          "role": "status"
        },
        "s1": {},
        "s2": task.receipt,
        "s3": {},
        "s4": item.status.toLowerCase(),
        "s5": {
          "href": task.destination,
          "target": "_blank",
          "rel": "noreferrer"
        },
        "s6": {
          "onClick": start
        }
      }),
      "s16": preview && render("application_task_21", {
        "s0": {
          "component": ApplicationDocument,
          "resume": resume,
          "task": task,
          "onClose": () => setPreview(false)
        }
      }),
      "s17": {},
      "s18": {},
      "s19": {},
      "s20": task.events.map((e, i) => render("application_task_22", {
        "s0": {
          "key": i
        },
        "s1": {},
        "s2": e.label,
        "s3": {},
        "s4": new Date(e.at).toLocaleString()
      })),
      "s21": !['completed', 'cancelled'].includes(task.status) && render("application_task_23", {
        "s0": {
          "onClick": () => real ? liveAct(() => live.cancel()) : commit({
            ...task,
            status: 'cancelled',
            events: [...task.events, {
              label: 'Task cancelled by user',
              at: Date.now()
            }]
          })
        }
      })
    })
  });
}
