import {useScenario} from './scenarios';
import {backend, describeError} from './backend';
import {liveState, useLive} from './live-store';
import {planFor, savePlanSession} from './prep-live';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useEffect, useState } from 'react';
import { ArrowLeft, Check } from 'lucide-react-native';
import { PrepPreview as GeneralPrep } from './prep-entry';
import { readStore, writeStore, PREP_KEY } from './application-store';
import { subscribePreviewLoading, prepLoadingSnapshot } from './loading';
export function PrepPreview(props) {
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, prepLoadingSnapshot);
  // Build-time constant: live builds read the plan from the account; mock builds keep it on the device.
  const real = backend.live;
  const account = useLive();
  const [applicationId, setApplicationId] = useState(() => readStore('stack.prep.handoff.v2', null));
  const [sessions, setSessions] = useState(() => readStore(PREP_KEY, [])),
    [selected, setSelected] = useState(null),
    [error, setError] = useState('');
  useScenario('Prep/applications-prep-controller', s=>{if(s.practice)setSelected(sessions[0]);});
  const openedAt = React.useRef(Date.now());
  const [planRows, setPlanRows] = useState([]),
    [planLoading, setPlanLoading] = useState(real && !!applicationId);
  const loading = reviewLoading || planLoading;
  useEffect(() => {
    if (!real || !applicationId || account.status !== 'ready') return;
    setPlanLoading(true);
    planFor(applicationId).then(rows => {
      setPlanRows(rows);
      setError('');
    }).catch(e => setError(describeError(e))).finally(() => setPlanLoading(false));
  }, [real, applicationId, account.status]);
  const job = real ? (liveState().boot?.applications || []).find(a => a.id === applicationId)?.job : null;
  const own = real ? planRows.map(r => ({
    ...r,
    company: job?.company,
    role: job?.title
  })) : sessions.filter(s => s.application_id === applicationId);
  function save(patch) {
    if (real) {
      const row = selected;
      const seconds = Math.round((Date.now() - openedAt.current) / 1000);
      savePlanSession(row, {
        notes: patch.notes,
        ...(patch.done ? {
          elapsed_seconds: Math.max(1, seconds)
        } : {})
      }).then(() => {
        const next = planRows.map(r => r.session_id === row.session_id ? {
          ...r,
          notes: patch.notes,
          done: r.done || !!patch.done
        } : r);
        setPlanRows(next);
        setSelected({
          ...row,
          notes: patch.notes,
          done: row.done || !!patch.done
        });
        setError('');
        if (patch.done) setSelected(null);
      }).catch(e => setError(describeError(e)));
      return false;
    }
    const next = sessions.map(s => s.session_id === selected.session_id ? {
      ...s,
      ...patch
    } : s);
    try {
      writeStore(PREP_KEY, next);
      setSessions(next);
      setSelected({
        ...selected,
        ...patch
      });
      setError('');
      return true;
    } catch {
      setError('Could not save practice. Your notes are still here; try again.');
      return false;
    }
  }
  function leavePractice() {
    if (selected && (selected.notes !== (sessions.find(s => s.session_id === selected.session_id)?.notes || '') || (selected.focus || '') !== (sessions.find(s => s.session_id === selected.session_id)?.focus || ''))) {
      setError('Save your notes before leaving this practice.');
      return;
    }
    setSelected(null);
  }
  function general() {
    if (selected && (selected.notes !== (sessions.find(s => s.session_id === selected.session_id)?.notes || '') || (selected.focus || '') !== (sessions.find(s => s.session_id === selected.session_id)?.focus || ''))) {
      setError('Save your notes before leaving this practice.');
      return;
    }
    try {
      writeStore('stack.prep.handoff.v2', null);
      setApplicationId(null);
    } catch {
      setError('Could not change the handoff. Try again.');
    }
  }
  if (applicationId === null) return render("applications_prep_1", {
    "s0": {
      "component": GeneralPrep,
      ...props
    }
  });
  return render("applications_prep_2", {
    "s0": {
      "aria-label": "Job interview preparation"
    },
    "s1": {},
    "s2": {},
    "s3": {
      "aria-label": selected ? 'Back to job plan' : 'Back to Applications',
      "onClick": () => selected ? leavePractice() : props.onNavigate('Applications')
    },
    "s4": {
      "component": ArrowLeft,
      "size": 20
    },
    "s5": {},
    "s6": selected ? 'Practice' : 'Interview plan',
    "s7": {},
    "s8": {},
    "s9": own[0]?.company || 'Interview plan',
    "s10": {},
    "s11": own[0]?.role,
    "s12": error && render("applications_prep_3", {
      "s0": {
        "role": "alert"
      },
      "s1": error
    }),
    "s13": loading && render("applications_prep_4", {
      "s0": {
        "role": "status"
      }
    }),
    "s14": {
      "inert": loading,
      "aria-hidden": loading || undefined,
      "variant": loading ? 'application-held-loading' : undefined
    },
    "s15": !own.length ? render("applications_prep_5", {
      "s0": {},
      "s1": {
        "onClick": () => props.onNavigate('Applications')
      }
    }) : selected ? render("applications_prep_6", {
      "s0": {},
      "s1": selected.title,
      "s2": {},
      "s3": selected.prompt,
      "s4": {},
      "s5": selected.language && selected.language + ' · ',
      "s6": selected.minutes,
      "s7": {},
      "s8": {
        "value": selected.notes,
        "onChange": e => setSelected({
          ...selected,
          notes: e.target.value
        })
      },
      "s9": {
        "omit": real
      },
      "s10": {
        "value": selected.focus || '',
        "onChange": e => setSelected({
          ...selected,
          focus: e.target.value
        })
      },
      "s11": {
        "value": ""
      },
      "s12": {
        "value": "reflection"
      },
      "s13": {
        "value": "edge cases"
      },
      "s14": {
        "onClick": () => save({
          notes: selected.notes,
          focus: selected.focus,
          feedback: selected.focus ? [{
            criterion: selected.focus,
            score: 1
          }] : []
        })
      },
      "s15": {
        "onClick": () => {
          if (save({
            notes: selected.notes,
            done: true,
            focus: selected.focus,
            feedback: selected.focus ? [{
              criterion: selected.focus,
              score: 1
            }] : []
          })) setSelected(null);
        }
      },
      "s16": {
        "component": Check,
        "size": 15
      }
    }) : render("applications_prep_7", {
      "s0": {},
      "s1": own.map(s => render("applications_prep_8", {
        "s0": {
          "key": s.session_id,
          "onClick": () => {
            openedAt.current = Date.now();
            setSelected(s);
          }
        },
        "s1": {},
        "s2": {},
        "s3": s.title,
        "s4": {},
        "s5": s.minutes,
        "s6": s.done ? 'Completed' : s.reason,
        "s7": s.done && render("applications_prep_9", {
          "s0": {
            "component": Check,
            "size": 17
          }
        })
      }))
    }),
    "s16": {
      "onClick": general
    }
  });
}
