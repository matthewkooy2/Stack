import {useScenario} from './scenarios';
import {backend,describeError} from './backend';
import {useLive,refreshLive,liveState} from './live-store';
import {uploadPdf,loadReview,saveDetails,deleteResume,applyTemplate} from './resume-live';
import {makePdf} from './resume-model';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import { readLibrary, saveLibrary } from './resume-library';
import { readStore } from './application-store';
import { ResumeTools, ResumeScenarios } from './resume-tools-controller';
import React, { useState, useRef, useEffect } from 'react';
import { subscribePreviewLoading, resumeLoadingSnapshot } from './loading';
import { Menu, Plus, ArrowLeft, ArrowUpRight, ChevronRight, FileText, Upload, Check, Layers, Users, BriefcaseBusiness, GraduationCap } from 'lucide-react-native';
const tabs = [['Network', Users], ['Applications', BriefcaseBusiness], ['Jobs', Layers], ['Resume', FileText], ['Prep', GraduationCap]];
const sample = {
  name: 'Alex Morgan',
  email: 'alex@example.com',
  location: 'New York, NY',
  experience: 'Design intern · Northstar\nBuilt and tested onboarding prototypes with the product team.',
  education: 'BA, Design · Class of 2027',
  skills: 'Figma, prototyping, user research'
};
const sections = [['Personal details', ['name', 'email', 'location']], ['Experience', ['experience']], ['Education', ['education']], ['Skills', ['skills']]];
const labels = {
  name: 'Full name',
  email: 'Email',
  location: 'Location',
  experience: 'Role & highlights',
  education: 'Degree & institution',
  skills: 'Your skills'
};
export function ResumePreview({
  onNavigate,
  onProfile
}) {
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, resumeLoadingSnapshot);
  // Build-time constant: live builds use the account's resumes; mock builds keep the on-device sample library.
  const real = backend.live;
  const account = useLive();
  const loading = reviewLoading || real && account.status === 'loading';
  const [page, setPage] = useState('home'),
    [category, setCategory] = useState(() => readStore('stack.resume.handoff.v1', 'Originals')),
    [items, setItems] = useState(readLibrary),
    [draft, setDraft] = useState(null),
    [step, setStep] = useState(0),
    [template, setTemplate] = useState('jake'),
    [error, setError] = useState(''),
    [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false),
    [progress, setProgress] = useState(null),
    [toolView, setToolView] = useState(''),
    [scenario, setScenario] = useState('normal');
  const picker = useRef(null),
    scroll = useRef(null);
  useEffect(() => {
    storage.removeItem('stack.resume.handoff.v1');
    const refresh = () => setItems(readLibrary());
    serviceEvents.addEventListener('stack-data-changed', refresh);
    serviceEvents.addEventListener('storage', refresh);
    return () => {
      serviceEvents.removeEventListener('stack-data-changed', refresh);
      serviceEvents.removeEventListener('storage', refresh);
    };
  }, []);
  useEffect(() => {
    if (!real || !draft || ['fields', 'review', 'processing'].includes(page)) return;
    const fresh = items.find(r => r.id === draft.id);
    if (fresh && JSON.stringify(fresh) !== JSON.stringify(draft)) setDraft(fresh);
  }, [items]);
  useEffect(() => {
    scroll.current?.scrollTo?.({
      y: 0,
      animated: false
    });
    setError('');
  }, [page, step, toolView]);
  useEffect(() => {
    if (real || page !== 'processing') return;
    const timer = setTimeout(() => {
      setStep(0);
      setPage('fields');
    }, 1400);
    return () => clearTimeout(timer);
  }, [page]);
  function add(name) {
    setDraft({
      id: String(Date.now()),
      name,
      kind: 'upload',
      details: {
        ...sample
      }
    });
    setPage('processing');
  }
  // Real upload: the PDF goes to the account, the server's parser reads it, then its details open for review.
  async function uploadLive(file) {
    setError('');
    setNotice('');
    setProgress(null);
    setPage('processing');
    try {
      const id = await uploadPdf(file, setProgress);
      const found = await waitForParse(id);
      setCategory('Originals');
      setDraft(found);
      setStep(0);
      setPage('fields');
    } catch (e) {
      setError(describeError(e));
      setPage('upload');
    }
  }
  async function waitForParse(id) {
    const stop = Date.now() + 90000;
    while (Date.now() < stop) {
      await refreshLive({
        quiet: true
      });
      const boot = liveState().boot,
        r = (boot?.resumes || []).find(x => x.id === id),
        status = r?.processing?.pdf?.status;
      const found = readLibrary().find(x => x.id === id);
      if (found?.parsed) return found;
      if (status === 'failed') throw new Error(r.processing.pdf.message || 'This PDF could not be read. Try another copy.');
      await new Promise(resolve => setTimeout(resolve, 1200));
    }
    throw new Error('Reading your PDF is taking longer than expected. Check Resume again in a moment.');
  }
  async function confirmLive() {
    try {
      setBusy(true);
      let id = draft.id;
      if (draft.kind === 'template' && draft.id.startsWith('draft-')) {
        // A new resume from a template: write its PDF, let the server read it, then fill the template from the details.
        const made = await makePdf({
          ...draft,
          format: {
            kind: 'builtin',
            template: draft.template,
            status: 'completed'
          }
        });
        const bytes = made.bytes;
        id = await uploadPdf({
          name: `${draft.details.name} · ${draft.template === 'jake' ? 'Jake’s Resume' : 'Classic'}.pdf`.replace(/[\\/]/g, '-'),
          arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
        });
        await waitForParse(id);
      }
      await saveDetails(id, draft.details, true);
      if (draft.kind === 'template' && draft.id.startsWith('draft-')) await applyTemplate(id, draft.template);
      setBusy(false);
      setCategory('Originals');
      setNotice('Resume confirmed.');
      setPage('home');
    } catch (e) {
      setBusy(false);
      setError(describeError(e));
    }
  }
  function manual() {
    setDraft({
      id: (real ? 'draft-' : '') + String(Date.now()),
      name: template === 'jake' ? "Jake’s Resume" : 'Classic resume',
      kind: 'template',
      template,
      details: Object.fromEntries(Object.keys(sample).map(k => [k, '']))
    });
    setStep(0);
    setPage('fields');
  }
  function valid() {
    if (step === 0 && !draft.details.name.trim()) {
      setError('Enter your name to continue.');
      return false;
    }
    if (step === 0 && draft.details.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(draft.details.email)) {
      setError('Check your email address.');
      return false;
    }
    return true;
  }
  function next() {
    if (!valid()) return;
    if (step < 3) {
      setStep(step + 1);
      return;
    }
    setPage('review');
  }
  function confirm() {
    if (real) {
      confirmLive();
      return;
    }
    const previous = items.find(r => r.id === draft.id);
    const detailsChanged = previous && JSON.stringify(previous.details) !== JSON.stringify(draft.details);
    const saved = {
      ...draft,
      task: detailsChanged ? null : draft.task,
      confirmed: true,
      isDefault: draft.confirmed ? !!draft.isDefault : !items.some(r => !r.tailored),
      name: draft.kind === 'template' && !draft.confirmed ? `${draft.details.name} · ${draft.template === 'jake' ? "Jake’s Resume" : 'Classic'}` : draft.name
    };
    try {
      const current = readLibrary();
      updateItems(current.some(r => r.id === saved.id) ? current.map(r => r.id === saved.id ? saved : r) : [...current, saved]);
    } catch {
      setError('Could not save the resume on this device. Please retry.');
      return;
    }
    setCategory('Originals');
    setNotice('Resume confirmed.');
    setPage('home');
  }
  function back() {
    if (page === 'preview' && toolView) {
      setToolView(['changes', 'profile', 'complete'].includes(toolView) ? 'agents' : '');
      return;
    }
    if (page === 'fields' && step > 0) setStep(step - 1);else if (page === 'fields') setPage(draft.kind === 'template' ? 'templates' : 'upload');else if (page === 'review') setPage('fields');else if (page === 'preview') setPage('home');else setPage('home');
  }
  function updateItems(next) {
    const saved = saveLibrary(next);
    setItems(saved);
    return saved;
  }
  function saveResume(r) {
    const saved = updateItems(readLibrary().map(x => x.id === r.id ? r : r.isDefault ? {
      ...x,
      isDefault: false
    } : x));
    setDraft(saved.find(x => x.id === r.id));
  }
  useScenario('Resume/resume-controller', s=>{const r=readLibrary().find(r=>s.view==='files'?r.tailored:!r.tailored);if(r)setDraft(r);setPage(s.page||'home');setStep(s.step||0);setToolView(s.view||'');setCategory(s.category||'Originals');setScenario(s.state||'normal');});
  const first = !items.length;
  const detailLoading = loading && ['fields', 'review', 'preview'].includes(page) || page === 'processing';
  return render("resume_1", {
    "s0": {
      "variant": 'jobs-preview resume-minimal' + (loading ? ' resume-skeleton' : '') + (detailLoading ? ' resume-detail-skeleton' : ''),
      "aria-label": "Resume library"
    },
    "s1": {
      "component": ResumeScenarios,
      "value": scenario,
      "onChange": setScenario
    },
    "s2": {},
    "s3": {
      "aria-label": "Open profile",
      "onClick": onProfile
    },
    "s4": {
      "component": Menu,
      "size": 21
    },
    "s5": {},
    "s6": {},
    "s7": {
      "style": {
        width: 34
      }
    },
    "s8": {
      "ref": scroll,
      "aria-busy": loading && page === 'home' || detailLoading
    },
    "s9": (loading && page === 'home' || detailLoading) && render("resume_2", {
      "s0": {
        "role": "status"
      },
      "s1": page === 'processing' ? 'Reading resume details' : 'Loading resumes'
    }),
    "s10": {},
    "s11": page !== 'home' && render("resume_3", {
      "s0": {
        "aria-label": "Back",
        "onClick": back
      },
      "s1": {
        "component": ArrowLeft,
        "size": 20
      }
    }),
    "s12": {},
    "s13": {
      home: 'Resume',
      choose: 'Add resume',
      upload: 'Upload resume',
      templates: 'Choose a template',
      processing: 'Reading your resume',
      fields: draft?.kind === 'template' ? 'Build your resume' : 'Review your details',
      review: 'Confirm your resume',
      preview: {
        agents: 'Resume agents',
        format: 'Tailoring format',
        manage: 'Manage resume',
        profile: 'Profile suggestions',
        changes: 'Review changes',
        files: 'Files & checks',
        complete: 'Resume ready'
      }[toolView] || 'Your resume'
    }[page],
    "s14": page === 'home' && !first && render("resume_4", {
      "s0": {
        "aria-label": "Add another resume",
        "onClick": () => setPage('choose')
      },
      "s1": {
        "component": Plus,
        "size": 21
      }
    }),
    "s15": page === 'home' && first || page === 'choose' ? render("resume_5", {
      "s0": {},
      "s1": {},
      "s2": {},
      "s3": {
        "aria-hidden": loading || undefined,
        "inert": loading ? '' : undefined
      },
      "s4": {
        "onClick": () => setPage('upload')
      },
      "s5": {
        "component": Upload,
        "size": 21
      },
      "s6": {},
      "s7": {},
      "s8": {},
      "s9": {
        "component": ChevronRight,
        "size": 17
      },
      "s10": {
        "onClick": () => setPage('templates')
      },
      "s11": {
        "component": FileText,
        "size": 21
      },
      "s12": {},
      "s13": {},
      "s14": {},
      "s15": {
        "component": ChevronRight,
        "size": 17
      },
      "s16": {}
    }) : page === 'home' ? render("resume_6", {
      "s0": {
        "role": "tablist",
        "aria-label": "Resume type"
      },
      "s1": ['Originals', 'Tailored'].map(c => render("resume_7", {
        "s0": {
          "key": c,
          "role": "tab",
          "aria-selected": category === c,
          "onClick": () => {
            setCategory(c);
            setNotice('');
          }
        },
        "s1": c
      })),
      "s2": category === 'Originals' ? render("resume_8", {
        "s0": items.filter(r => !r.tailored).map(r => render("resume_9", {
          "s0": {
            "key": r.id,
            "disabled": loading || busy,
            "aria-hidden": loading || undefined,
            "onClick": async () => {
              setDraft({
                ...r,
                details: {
                  ...r.details
                }
              });
              setToolView('');
              setStep(0);
              if (real && !r.parsed) {
                setBusy(true);
                setError('');
                setNotice('Loading resume details…');
                try {
                  await loadReview(r.id);
                  let found = readLibrary().find(x => x.id === r.id);
                  if (!found?.parsed) {
                    setNotice('');
                    setProgress(null);
                    setPage('processing');
                    found = await waitForParse(r.id);
                  }
                  setDraft(found);
                  setNotice('');
                  setPage(found.confirmed ? 'preview' : 'fields');
                } catch (e) {
                  setPage('home');
                  setNotice(describeError(e));
                } finally {
                  setBusy(false);
                }
                return;
              }
              setPage(r.confirmed ? 'preview' : 'fields');
            }
          },
          "s1": {},
          "s2": {
            "component": FileText,
            "size": 22
          },
          "s3": {},
          "s4": {},
          "s5": r.name,
          "s6": {},
          "s7": r.isDefault ? 'Default · ' : '',
          "s8": r.confirmed ? 'Details confirmed' : real && ['queued', 'running'].includes(r.processing?.status) ? 'Reading your PDF…' : real && r.processing?.status === 'failed' ? 'Could not read this PDF' : 'Facts need confirmation',
          "s9": r.kind === 'upload' ? 'PDF' : 'Template',
          "s10": {
            "component": ChevronRight,
            "size": 17
          }
        })),
        "s1": !items.some(r => !r.tailored) ? render("resume_10", {
          "s0": {},
          "s1": {},
          "s2": {},
          "s3": {
            "disabled": loading,
            "onClick": () => setPage('choose')
          }
        }) : render("resume_11", {
          "s0": {}
        })
      }) : items.some(r => r.tailored) ? items.filter(r => r.tailored).map(r => render("resume_12", {
        "s0": {
          "key": r.id,
          "disabled": loading,
          "onClick": () => {
            setDraft(r);
            setToolView('');
            setPage('preview');
          }
        },
        "s1": {},
        "s2": {
          "component": FileText,
          "size": 22
        },
        "s3": {},
        "s4": {},
        "s5": r.name,
        "s6": {},
        "s7": r.job.role,
        "s8": {
          "component": ChevronRight,
          "size": 17
        }
      })) : loading ? render("resume_13", {
        "s0": {
          "aria-hidden": "true"
        },
        "s1": [1, 2, 3].map(n => render("resume_14", {
          "s0": {
            "key": n
          },
          "s1": {},
          "s2": {},
          "s3": {},
          "s4": {}
        }))
      }) : render("resume_15", {
        "s0": {},
        "s1": {
          "component": Layers,
          "size": 30,
          "strokeWidth": 1.2
        },
        "s2": {},
        "s3": {},
        "s4": {
          "onClick": () => onNavigate('Jobs')
        },
        "s5": {
          "component": ArrowUpRight,
          "size": 14
        }
      }),
      "s3": notice && render("resume_16", {
        "s0": {
          "role": "status"
        },
        "s1": {
          "component": Check,
          "size": 13
        },
        "s2": notice
      })
    }) : page === 'upload' ? render("resume_17", {
      "s0": {},
      "s1": {},
      "s2": {
        "onClick": () => picker.current.click()
      },
      "s3": {
        "component": Upload,
        "size": 19
      },
      "s4": {},
      "s5": {},
      "s6": {
        "component": Plus,
        "size": 17
      },
      "s7": {
        "ref": picker,
        "hidden": true,
        "type": "file",
        "accept": ".pdf,application/pdf",
        "onChange": e => {
          const f = e.target.files[0];
          if (!f) return;
          if (!/\.pdf$/i.test(f.name) || f.size > 10 * 1024 * 1024) {
            setError('Choose a PDF smaller than 10 MB.');
            return;
          }
          if (real) uploadLive(f);else add(f.name);
        }
      },
      "s8": {
        "omit": real,
        "onClick": () => add('Alex_Morgan_Resume.pdf')
      },
      "s9": {
        "component": ArrowUpRight,
        "size": 14
      },
      "s10": {}
    }) : page === 'processing' ? render("resume_18", {
      "s0": {
        "aria-hidden": "true"
      },
      "s1": sections.map(s => render("resume_19", {
        "s0": {
          "key": s[0]
        }
      })),
      "s2": {},
      "s3": {},
      "s4": {},
      "s5": {},
      "s6": ['name', 'email', 'location'].map(k => render("resume_20", {
        "s0": {
          "key": k
        },
        "s1": labels[k],
        "s2": k === 'name' && ' *',
        "s3": {
          "aria-hidden": "true"
        }
      })),
      "s7": {
        "disabled": true
      },
      "s8": {
        "component": ChevronRight,
        "size": 16
      }
    }) : page === 'templates' ? render("resume_21", {
      "s0": {},
      "s1": {},
      "s2": ['jake', 'classic'].map(t => render("resume_22", {
        "s0": {
          "key": t,
          "variant": 'resume-template ' + (template === t ? 'selected' : ''),
          "aria-pressed": template === t,
          "onClick": () => setTemplate(t)
        },
        "s1": {
          "variant": 'resume-template-paper ' + t,
          "aria-hidden": "true"
        },
        "s2": {},
        "s3": {},
        "s4": {},
        "s5": {},
        "s6": {},
        "s7": {},
        "s8": {},
        "s9": {},
        "s10": {},
        "s11": {},
        "s12": {},
        "s13": {},
        "s14": t === 'jake' ? "Jake’s Resume" : 'Classic',
        "s15": {},
        "s16": t === 'jake' ? 'Clean & traditional' : 'Simple & modern',
        "s17": template === t && render("resume_23", {
          "s0": {
            "component": Check,
            "size": 16
          }
        })
      })),
      "s3": {
        "onClick": manual
      },
      "s4": {
        "component": ChevronRight,
        "size": 16
      },
      "s5": {}
    }) : page === 'fields' ? render("resume_24", {
      "s0": {
        "aria-label": `Step ${step + 1} of 4`
      },
      "s1": sections.map((s, i) => render("resume_25", {
        "s0": {
          "key": s[0],
          "variant": i <= step ? 'done' : ''
        }
      })),
      "s2": {},
      "s3": step + 1,
      "s4": {},
      "s5": sections[step][0],
      "s6": {},
      "s7": draft.kind === 'upload' ? 'Check the extracted details and correct anything.' : 'Add your details. Leave anything that doesn’t apply blank.',
      "s8": {},
      "s9": sections[step][1].map(k => render("resume_26", {
        "s0": {
          "key": k
        },
        "s1": labels[k],
        "s2": k === 'name' && ' *',
        "s3": step === 0 ? render("resume_27", {
          "s0": {
            "disabled": detailLoading,
            "aria-hidden": detailLoading,
            "autoComplete": "off",
            "value": detailLoading ? '' : draft.details[k],
            "onChange": e => setDraft({
              ...draft,
              details: {
                ...draft.details,
                [k]: e.target.value
              }
            })
          }
        }) : render("resume_28", {
          "s0": {
            "disabled": detailLoading,
            "aria-hidden": detailLoading,
            "value": detailLoading ? '' : draft.details[k],
            "placeholder": detailLoading ? '' : k === 'experience' ? 'Work, internships, volunteering, or projects' : k === 'education' ? 'Your school, qualification, and dates' : 'Tools, languages, and strengths',
            "onChange": e => setDraft({
              ...draft,
              details: {
                ...draft.details,
                [k]: e.target.value
              }
            })
          }
        })
      })),
      "s10": {
        "disabled": detailLoading,
        "onClick": next
      },
      "s11": step === 3 ? 'Review resume' : 'Continue',
      "s12": {
        "component": ChevronRight,
        "size": 16
      },
      "s13": draft.kind === 'upload' && render("resume_29", {
        "s0": {}
      })
    }) : page === 'review' ? render("resume_30", {
      "s0": {},
      "s1": sections.map(([title, keys], i) => render("resume_31", {
        "s0": {
          "key": title
        },
        "s1": {},
        "s2": {},
        "s3": title,
        "s4": {
          "disabled": detailLoading,
          "aria-label": `Edit ${title.toLowerCase()}`,
          "onClick": () => {
            setStep(i);
            setPage('fields');
          }
        },
        "s5": keys.map(k => render("resume_32", {
          "s0": {
            "aria-hidden": detailLoading,
            "key": k
          },
          "s1": draft.details[k] || 'Not added'
        }))
      })),
      "s2": {
        "disabled": detailLoading,
        "onClick": confirm
      },
      "s3": {
        "component": Check,
        "size": 16
      }
    }) : render("resume_33", {
      "s0": {
        "component": ResumeTools,
        "key": draft.id,
        "resume": draft,
        "disabled": detailLoading,
        "view": toolView,
        "setView": setToolView,
        "scenario": scenario,
        "onSave": saveResume,
        "onEdit": () => {
          setStep(0);
          setPage('fields');
        },
        "onDelete": async () => {
          try {
            if (real) await deleteResume(draft.id);else updateItems(readLibrary().filter(r => r.id !== draft.id));
          } catch (e) {
            setError(real ? describeError(e) : 'Could not delete this resume. Please retry.');
            return;
          }
          setNotice('Resume deleted.');
          setToolView('');
          setPage('home');
        },
        "onTailored": r => updateItems([...readLibrary(), r]),
        "onOpenTailored": id => {
          const found = readLibrary().find(r => r.id === String(id));
          if (found) {
            setDraft(found);
            setToolView('files');
            setPage('preview');
          } else {
            setCategory('Tailored');
            setPage('home');
            setNotice('That tailored version was deleted.');
          }
        }
      }
    }),
    "s16": error && render("resume_34", {
      "s0": {
        "role": "alert"
      },
      "s1": error
    }),
    "s17": {
      "aria-label": "Main navigation"
    },
    "s18": tabs.map(([name, Icon]) => render("resume_35", {
      "s0": {
        "key": name,
        "aria-current": name === 'Resume' ? 'page' : undefined,
        "onClick": () => name === 'Resume' ? setPage('home') : onNavigate(name)
      },
      "s1": {
        "component": Icon,
        "size": 22
      },
      "s2": {},
      "s3": name,
      "s4": name === 'Resume' && render("resume_36", {
        "s0": {}
      })
    }))
  });
}
