import {useScenario} from './scenarios';
import {backend, describeError} from './backend';
import {useLive} from './live-store';
import {usePrepSessions, sessionFor, saveSession, doneIds} from './prep-live';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState } from 'react';
import { Menu, ArrowLeft, ChevronRight, ChevronDown, Code2, MessageCircle, Check, Layers, Users, BriefcaseBusiness, FileText, GraduationCap } from 'lucide-react-native';
import { subscribePreviewLoading, prepLoadingSnapshot } from './loading';
import { MockInterview } from './mock-interview-controller';
import questions from './prep-questions.json';
const tabs = [['Network', Users], ['Applications', BriefcaseBusiness], ['Jobs', Layers], ['Resume', FileText], ['Prep', GraduationCap]];
let practiceNotes = {},
  completed = [];
export function PrepPreview({
  onNavigate,
  onProfile
}) {
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, prepLoadingSnapshot);
  // Build-time constant: live builds save practice to the account; mock builds keep it in memory.
  const real = backend.live;
  const account = useLive();
  const prep = usePrepSessions();
  const loading = reviewLoading || real && (account.status === 'loading' || prep.status === 'loading');
  const [saveError, setSaveError] = useState('');
  const started = React.useRef(Date.now());
  const [track, setTrack] = useState(null),
    [question, setQuestion] = useState(null),
    [guide, setGuide] = useState(false),
    [notes, setNotes] = useState(practiceNotes),
    [done, setDone] = useState(completed);
  const doneNow = real ? doneIds() : done;
  // The saved notes for the open question (live), loaded once its session is known.
  const notesFor = q => real ? notes[q.id] ?? sessionFor(q.id)?.data.notes ?? '' : notes[q.id] || '';
  React.useEffect(() => {
    if (!real || !question || track === 'Behavioral' || notes[question.id] === undefined) return;
    const id = setTimeout(() => saveSession(question.id, {
      notes: notes[question.id]
    }).catch(e => setSaveError(describeError(e))), 1200);
    return () => clearTimeout(id);
  }, [real, question?.id, notes[question?.id]]);
  useScenario('Prep/prep-controller', s=>{setTrack(s.track||null);if(s.question)setQuestion(questions.find(q=>q.id===s.question)||questions.find(q=>q.track===s.track));});
  function open(q) {
    setQuestion(q);
    setGuide(false);
    started.current = Date.now();
    setSaveError('');
  }
  function finish() {
    if (real) {
      // Practice time is what marks a question done: it is saved with the notes.
      const seconds = Math.max(1, Math.round((Date.now() - started.current) / 1000));
      saveSession(question.id, {
        ...(track === 'Behavioral' ? {} : {
          notes: notesFor(question)
        }),
        elapsed_seconds: Math.min(86400, (sessionFor(question.id)?.data.elapsed_seconds || 0) + seconds)
      }).then(() => setQuestion(null)).catch(e => setSaveError(describeError(e)));
      return;
    }
    const next = done.includes(question.id) ? done : [...done, question.id];
    completed = next;
    setDone(next);
    setQuestion(null);
  }
  function back() {
    if (question) setQuestion(null);else setTrack(null);
  }
  if (track === 'Behavioral' && question) return render("prep_1", {
    "s0": {},
    "s1": {
      "component": MockInterview,
      "question": question,
      "onFinish": finish,
      "onExit": () => setQuestion(null)
    }
  });
  return render("prep_2", {
    "s0": {
      "variant": 'jobs-preview prep-preview' + (loading ? ' prep-skeleton' : ''),
      "aria-label": "Interview preparation"
    },
    "s1": {},
    "s2": {
      "aria-label": "Open profile",
      "onClick": onProfile
    },
    "s3": {
      "component": Menu,
      "size": 21
    },
    "s4": {},
    "s5": {},
    "s6": {
      "style": {
        width: 40
      }
    },
    "s7": {
      "aria-busy": loading && !question,
      "key": question?.id || track || 'home'
    },
    "s8": loading && !question && render("prep_3", {
      "s0": {
        "role": "status"
      }
    }),
    "s9": track ? render("prep_4", {
      "s0": {},
      "s1": {
        "aria-label": question ? 'Back to questions' : 'Back to prep',
        "onClick": back
      },
      "s2": {
        "component": ArrowLeft,
        "size": 20
      },
      "s3": {},
      "s4": track
    }) : render("prep_5", {
      "s0": {},
      "s1": {}
    }),
    "s10": !track ? render("prep_6", {
      "s0": {},
      "s1": [['Behavioral', MessageCircle, 'Tell your story', 'Projects, teamwork & growth'], ['Technical', Code2, 'Think it through', 'Problem solving & code']].map(([name, Icon, title, subtitle]) => render("prep_7", {
        "s0": {
          "disabled": loading,
          "aria-hidden": loading || undefined,
          "key": name,
          "onClick": () => setTrack(name)
        },
        "s1": {
          "variant": 'prep-track-icon ' + name.toLowerCase()
        },
        "s2": {
          "component": Icon,
          "size": 21
        },
        "s3": {},
        "s4": {},
        "s5": name,
        "s6": {},
        "s7": subtitle,
        "s8": {
          "component": ChevronRight,
          "size": 17
        }
      }))
    }) : !question ? render("prep_8", {
      "s0": {},
      "s1": questions.filter(q => q.track === track).map(q => render("prep_9", {
        "s0": {
          "disabled": loading,
          "aria-hidden": loading || undefined,
          "key": q.id,
          "onClick": () => open(q)
        },
        "s1": {},
        "s2": {},
        "s3": q.title,
        "s4": {},
        "s5": q.topic,
        "s6": q.time,
        "s7": doneNow.includes(q.id) ? render("prep_10", {
          "s0": {
            "component": Check,
            "size": 17
          }
        }) : render("prep_11", {
          "s0": {
            "component": ChevronRight,
            "size": 17
          }
        })
      }))
    }) : track === 'Behavioral' ? render("prep_12", {
      "s0": {
        "component": MockInterview,
        "question": question,
        "onFinish": finish
      }
    }) : render("prep_13", {
      "s0": {},
      "s1": {},
      "s2": saveError || question.topic,
      "s3": question.time,
      "s4": {},
      "s5": question.title,
      "s6": {},
      "s7": question.prompt,
      "s8": {},
      "s9": {
        "aria-label": "Practice notes",
        "placeholder": track === 'Technical' ? 'Sketch your approach…' : 'Start with a real example…',
        "value": notesFor(question),
        "onChange": e => {
          const next = {
            ...notes,
            [question.id]: e.target.value
          };
          practiceNotes = next;
          setNotes(next);
        }
      },
      "s10": {
        "aria-expanded": guide,
        "onClick": () => setGuide(!guide)
      },
      "s11": {},
      "s12": {
        "component": ChevronDown,
        "size": 16
      },
      "s13": guide && render("prep_14", {
        "s0": {},
        "s1": {},
        "s2": question.steps.map(step => render("prep_15", {
          "s0": {
            "key": step
          },
          "s1": step
        })),
        "s3": {},
        "s4": question.guide,
        "s5": {},
        "s6": {},
        "s7": question.check
      }),
      "s14": {
        "onClick": finish
      },
      "s15": {
        "component": Check,
        "size": 17
      },
      "s16": {}
    }),
    "s11": {
      "aria-label": "Main navigation"
    },
    "s12": tabs.map(([name, Icon]) => render("prep_16", {
      "s0": {
        "key": name,
        "aria-current": name === 'Prep' ? 'page' : undefined,
        "onClick": () => {
          if (name === 'Prep') {
            setTrack(null);
            setQuestion(null);
          } else onNavigate(name);
        }
      },
      "s1": {
        "component": Icon,
        "size": 22
      },
      "s2": {},
      "s3": name,
      "s4": name === 'Prep' && render("prep_17", {
        "s0": {}
      })
    }))
  });
}
