import {useScenario} from './scenarios';
import {backend} from './backend';
import {useLiveDeck,factsFor,placeholder,clip,PAGE_LOW,fullListing} from './jobs-live';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState, useRef } from 'react';
import { subscribePreviewLoading, jobsLoadingSnapshot } from './loading';
import { Menu, SlidersHorizontal, Undo2, Bookmark, X, ArrowUpRight, MapPin, ChevronDown, Layers, Users, BriefcaseBusiness, FileText, GraduationCap, Check } from 'lucide-react-native';
const jobs = [{
  id: 'northstar',
  company: 'Northstar',
  initial: 'N',
  tagline: 'Good design moves people.',
  title: 'Associate Product Designer',
  location: 'New York, NY',
  mode: 'Hybrid',
  type: 'Full-time',
  level: 'New grad',
  pay: '$75–90k',
  payNote: 'per year',
  color: 'lilac',
  about: 'Help make everyday money decisions feel simpler. Join a small product team building thoughtful tools for a new generation.',
  work: ['Turn early ideas into clear, thoughtful product experiences.', 'Prototype, test, and iterate alongside engineers and researchers.', 'Bring your perspective to a product used every day.'],
  needs: ['A portfolio of student, personal, or internship projects.', 'Curiosity, visual craft, and an interest in solving real problems.'],
  perks: ['Design mentorship', 'Flexible hours', 'Health & wellness']
}, {
  id: 'fieldwork',
  company: 'Fieldwork',
  initial: 'f.',
  tagline: 'A little curiosity. A big impact.',
  title: 'Software Engineering Intern',
  location: 'Remote · US',
  mode: 'Remote',
  type: 'Internship',
  level: 'Student',
  pay: '$38–45',
  payNote: 'per hour',
  color: 'mint',
  about: 'Build useful software with people who care about how it feels to use. Spend the summer shipping features with a dedicated mentor.',
  work: ['Build and ship a feature from idea to release.', 'Collaborate with product designers and senior engineers.', 'Learn through code reviews and weekly mentorship.'],
  needs: ['Currently studying computer science or a related field.', 'Experience with JavaScript from classes or personal projects.'],
  perks: ['Paid internship', 'Dedicated mentor', 'Remote friendly']
}, {
  id: 'common',
  company: 'Common Ground',
  initial: 'cg',
  tagline: 'Make your first move matter.',
  title: 'Brand & Marketing Associate',
  location: 'Chicago, IL',
  mode: 'Hybrid',
  type: 'Full-time',
  level: 'New grad',
  pay: '$60–72k',
  payNote: 'per year',
  color: 'peach',
  about: 'Tell the stories behind a growing community brand. Bring fresh ideas to campaigns, content, and real-world experiences.',
  work: ['Create content for launches and community events.', 'Help shape campaign concepts and brand stories.', 'Learn what resonates through audience research.'],
  needs: ['Strong writing skills and a creative point of view.', 'A recent degree or equivalent project experience.'],
  perks: ['Creative team', 'Learning budget', 'Community days']
}];
const quickFacts = {
  northstar: {
    experience: '0–1 years',
    timing: 'Starts Aug 2027',
    workplace: 'Hybrid · 3 days in office',
    eligibility: 'Portfolio required',
    skills: 'Figma · prototyping',
    sponsorship: 'Sponsorship not listed',
    tasks: ['Design mobile money tools', 'Prototype and test with real users']
  },
  fieldwork: {
    experience: 'No experience required',
    timing: 'Jun–Aug 2027 · 12 weeks',
    workplace: 'Remote · US only',
    eligibility: 'Currently enrolled student',
    skills: 'JavaScript · React',
    sponsorship: 'Sponsorship available',
    tasks: ['Ship a customer-facing feature', 'Pair with a dedicated engineer mentor']
  },
  common: {
    experience: '0–2 years',
    timing: 'Start date flexible',
    workplace: 'Hybrid · 2 days in office',
    eligibility: 'Degree or equivalent projects',
    skills: 'Writing · social content',
    sponsorship: 'No visa sponsorship',
    tasks: ['Create launch and social content', 'Help plan community campaigns']
  }
};
let previewSession = {
  index: 0,
  history: [],
  saved: [],
  type: 'All',
  mode: 'Any'
};
const tabs = [['Network', Users], ['Applications', BriefcaseBusiness], ['Jobs', Layers], ['Resume', FileText], ['Prep', GraduationCap]];
export function JobsPreview({
  onNavigate,
  onProfile
}) {
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, jobsLoadingSnapshot);
  // Build-time constant: live builds read the real catalog, mock builds keep the sample deck below.
  const real = backend.live;
  const [index, setIndex] = useState(previewSession.index),
    [history, setHistory] = useState(previewSession.history),
    [saved, setSaved] = useState(previewSession.saved),
    [sheet, setSheet] = useState(''),
    [type, setType] = useState(previewSession.type),
    [mode, setMode] = useState(previewSession.mode),
    [draftType, setDraftType] = useState('All'),
    [draftMode, setDraftMode] = useState('Any'),
    [drag, setDrag] = useState(0),
    [live, setLive] = useState(0),
    [leaving, setLeaving] = useState(''),
    [toast, setToast] = useState('');
  const account = real ? useLiveDeck(setToast) : null;
  const loading = reviewLoading || real && account.status === 'loading';
  const [fullText, setFullText] = useState({
    id: '',
    text: ''
  });
  React.useEffect(() => {
    previewSession = {
      index,
      history,
      saved,
      type,
      mode
    };
  }, [index, history, saved, type, mode]);
  useScenario('Jobs/jobs-controller', s=>{if(['filters','details','menu'].includes(s.page))setSheet(s.page);if(s.page==='exhausted')setIndex(99);});
  const start = useRef(null),
    distance = useRef(0),
    timer = useRef(null);
  const [dragging, setDragging] = useState(false);
  // `drag` is a held card position (review states). `live` is the coarse intent of a drag in
  // progress, reported by the card only when it changes; the card's motion never uses React state.
  const shown = drag || live,
    progress = Math.min(Math.abs(shown) / 90, 1),
    direction = leaving || (shown > 0 ? 'save' : 'pass');
  const activeType = real ? account.filters.type : type,
    activeMode = real ? account.filters.mode : mode;
  const deck = real ? account.cards : jobs.filter(j => (type === 'All' || j.type === type) && (mode === 'Any' || j.mode === mode)),
    job = loading ? real ? placeholder : jobs[0] : deck[index];
  const facts = job ? real ? factsFor(job) : quickFacts[job.id] : null;
  React.useEffect(() => {
    if (real && deck.length - index <= PAGE_LOW) account.more();
  }, [real, deck.length, index]);
  React.useEffect(() => {
    if (!real || sheet !== 'details' || !job || job.id === 'placeholder') return;
    let current = true;
    fullListing(job.id).then(r => {
      if (current) setFullText({
        id: job.id,
        text: String(r.description || '').replace(/<[^>]*>/g, ' ')
      });
    }).catch(() => {});
    return () => {
      current = false;
    };
  }, [sheet, job?.id]);
  const about = real && job && fullText.id === job.id && fullText.text.trim() ? clip(fullText.text, 900) : job?.about;
  function decide(action) {
    if (loading || !job || leaving) return;
    setDragging(false);
    start.current = null;
    setLeaving(action);
    timer.current = setTimeout(() => {
      setHistory(h => [...h, {
        index,
        saved
      }]);
      if (real) account.decide(job, action);
      if (action === 'save') {
        setSaved(s => [...s, job.id]);
        setToast(`${job.company} saved`);
      } else setToast(real ? 'Passed · Undo' : 'Passed · Undo anytime');
      setIndex(i => i + 1);
      setLeaving('');
      setDrag(0);
      setLive(0);
      distance.current = 0;
    }, 280);
  }
  function undo() {
    if (!history.length || leaving) return;
    if (real && !account.undo()) {
      setToast('That choice is already saved');
      setHistory([]);
      return;
    }
    const last = history.at(-1);
    setIndex(last.index);
    setSaved(last.saved);
    setHistory(h => h.slice(0, -1));
    setToast('Last swipe undone');
  }
  React.useEffect(() => () => clearTimeout(timer.current), []);
  React.useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(''), 2400);
    return () => clearTimeout(id);
  }, [toast]);
  function openFilters() {
    setDraftType(activeType);
    setDraftMode(activeMode);
    setSheet('filters');
  }
  function pointerDown(e) {
    if (loading || leaving || e.target.closest('button') || e.button !== 0) return;
    start.current = e.clientX;
    distance.current = 0;
    setDragging(true);
    e.currentTarget.setPointerCapture(e.pointerId);
  }
  function pointerUp() {
    if (start.current === null) return;
    start.current = null;
    setDragging(false);
    if (Math.abs(distance.current) >= 90) decide(distance.current > 0 ? 'save' : 'pass');else setDrag(0);
  }
  return render("jobs_1", {
    "s0": {
      "variant": 'jobs-preview' + (loading ? ' jobs-skeleton' : ''),
      "aria-label": "Job discovery"
    },
    "s1": {},
    "s2": {
      "aria-label": "Open menu",
      "onClick": () => setSheet('menu')
    },
    "s3": {
      "component": Menu,
      "size": 21
    },
    "s4": {},
    "s5": {},
    "s6": {},
    "s7": {
      "aria-label": "Undo last swipe",
      "disabled": loading || (real ? !account.held : !history.length) || !!leaving,
      "onClick": undo
    },
    "s8": {
      "component": Undo2,
      "size": 21
    },
    "s9": {
      "aria-label": "Filter jobs",
      "onClick": openFilters
    },
    "s10": {
      "component": SlidersHorizontal,
      "size": 20
    },
    "s11": (activeType !== 'All' || activeMode !== 'Any') && render("jobs_2", {
      "s0": {}
    }),
    "s12": {
      "aria-busy": loading
    },
    "s13": loading && render("jobs_3", {
      "s0": {
        "role": "status"
      }
    }),
    "s14": job ? render("jobs_4", {
      "s0": {
        "aria-hidden": loading || undefined,
        "inert": loading ? '' : undefined,
        "variant": `opportunity ${job.color} ${leaving ? 'leave-' + leaving : ''} ${dragging ? 'is-dragging' : ''} ${progress > 0 || leaving ? 'intent-' + direction : ''}`,
        "onSwipe": action => {
          setLive(0);
          decide(action);
        },
        "onDrag": value => setLive(value),
        "style": {
          '--drag': `${drag}px`,
          '--tilt': `${Math.max(-9, Math.min(9, drag / 28))}deg`,
          '--swipe-progress': leaving ? 1 : progress
        }
      },
      "s1": {},
      "s2": {
        "aria-hidden": "true"
      },
      "s3": job.initial,
      "s4": {},
      "s5": {},
      "s6": job.company,
      "s7": {},
      "s8": {},
      "s9": job.level,
      "s10": {},
      "s11": {},
      "s12": job.title,
      "s13": {},
      "s14": {},
      "s15": job.pay,
      "s16": {},
      "s17": job.payNote,
      "s18": job.type,
      "s19": {},
      "s20": {},
      "s21": {
        "component": MapPin,
        "size": 15
      },
      "s22": {},
      "s23": job.location.replace('Remote · US', 'United States'),
      "s24": {},
      "s25": facts.workplace,
      "s26": {},
      "s27": {
        "component": BriefcaseBusiness,
        "size": 15
      },
      "s28": {},
      "s29": facts.experience,
      "s30": {},
      "s31": facts.timing,
      "s32": {},
      "s33": {},
      "s34": {},
      "s35": facts.tasks.map(task => render("jobs_5", {
        "s0": {
          "key": task
        },
        "s1": task
      })),
      "s36": {},
      "s37": {},
      "s38": {},
      "s39": facts.eligibility,
      "s40": {},
      "s41": facts.skills,
      "s42": {
        "variant": `decision-sponsor ${!real && job.id === 'fieldwork' ? 'available' : ''}`
      },
      "s43": !real && job.id === 'fieldwork' ? render("jobs_6", {
        "s0": {
          "component": Check,
          "size": 13
        }
      }) : render("jobs_7", {
        "s0": {}
      }),
      "s44": facts.sponsorship,
      "posted": real ? job.posted : 'Posted today · Sample job',
      "s45": {
        "onClick": () => setSheet('details')
      },
      "s46": {
        "component": ArrowUpRight,
        "size": 17
      },
      "s47": {},
      "s48": {
        "aria-label": "Pass on job",
        "disabled": loading || !!leaving,
        "onClick": () => decide('pass')
      },
      "s49": {
        "component": X,
        "size": 25
      },
      "s50": {},
      "s51": leaving ? leaving === 'save' ? 'Saved' : 'Passed' : progress >= 1 ? 'Release to ' + direction : render("jobs_8", {
        "s0": {
          "aria-hidden": "true"
        }
      }),
      "s52": {
        "aria-label": "Save job",
        "disabled": loading || !!leaving,
        "onClick": () => decide('save')
      },
      "s53": {
        "component": Bookmark,
        "size": 24
      }
    }) : render("jobs_9", {
      "s0": {},
      "s1": {
        "component": Layers,
        "size": 40
      },
      "s2": {},
      "s3": {},
      "s4": real && account.status === 'error' ? account.error : saved.length ? `${saved.length} ${saved.length === 1 ? 'opportunity' : 'opportunities'} saved. Take another look, or try a different search.` : 'That’s this stack. Try a different search or take another look.',
      "s5": {
        "onClick": () => {
          if (real) account.reload();
          setIndex(0);
          setHistory([]);
          setSaved([]);
        }
      },
      "s6": {
        "onClick": openFilters
      }
    }),
    "s15": toast && !loading && render("jobs_10", {
      "s0": {
        "role": "status"
      },
      "s1": {
        "component": Check,
        "size": 15
      },
      "s2": toast
    }),
    "s16": {
      "aria-label": "Main navigation"
    },
    "s17": tabs.map(([name, Icon]) => render("jobs_11", {
      "s0": {
        "key": name,
        "aria-current": name === 'Jobs' ? 'page' : undefined,
        "onClick": () => name !== 'Jobs' && onNavigate(name)
      },
      "s1": {
        "component": Icon,
        "size": 22
      },
      "s2": {},
      "s3": name,
      "s4": name === 'Jobs' && render("jobs_12", {
        "s0": {}
      })
    })),
    "s18": sheet && render("jobs_13", {
      "s0": {
        "onClick": () => setSheet('')
      },
      "s1": {
        "role": "dialog",
        "aria-modal": "true",
        "aria-label": sheet === 'filters' ? 'Job filters' : sheet === 'menu' ? 'Menu' : 'Job details',
        "onClick": e => e.stopPropagation()
      },
      "s2": {},
      "s3": {
        "aria-label": "Close panel",
        "onClick": () => setSheet('')
      },
      "s4": {
        "component": X,
        "size": 21
      },
      "s5": sheet === 'filters' ? render("jobs_14", {
        "s0": {},
        "s1": {},
        "s2": {},
        "s3": {},
        "s4": {},
        "s5": ['All', 'Full-time', 'Internship'].map(t => render("jobs_15", {
          "s0": {
            "key": t,
            "aria-pressed": draftType === t,
            "onClick": () => setDraftType(t)
          },
          "s1": t
        })),
        "s6": {},
        "s7": {},
        "s8": ['Any', 'Remote', 'Hybrid'].map(m => render("jobs_16", {
          "s0": {
            "key": m,
            "aria-pressed": draftMode === m,
            "onClick": () => setDraftMode(m)
          },
          "s1": m
        })),
        "s9": {
          "onClick": () => {
            if (real) account.applyFilters({
              type: draftType,
              mode: draftMode
            });
            setType(draftType);
            setMode(draftMode);
            setIndex(0);
            setHistory([]);
            setSheet('');
          }
        }
      }) : sheet === 'menu' ? render("jobs_17", {
        "s0": {},
        "s1": {
          "onClick": () => {
            setSheet('');
            onProfile();
          }
        },
        "s2": {
          "component": ArrowUpRight,
          "size": 18
        },
        "s3": {
          "onClick": () => {
            setSheet('');
            onNavigate('Applications');
          }
        },
        "s4": {
          "component": ArrowUpRight,
          "size": 18
        },
        "s5": {},
        "s6": saved.length
      }) : job && render("jobs_18", {
        "s0": {},
        "s1": job.company,
        "s2": job.type,
        "s3": {},
        "s4": job.title,
        "s5": {},
        "s6": about,
        "s7": {},
        "s8": facts.workplace,
        "s9": {},
        "s10": facts.experience,
        "s11": facts.timing,
        "s12": {},
        "s13": facts.sponsorship,
        "s14": {},
        "s15": {},
        "s16": job.work.map(x => render("jobs_19", {
          "s0": {
            "key": x
          },
          "s1": x
        })),
        "s17": {},
        "s18": {},
        "s19": job.needs.map(x => render("jobs_20", {
          "s0": {
            "key": x
          },
          "s1": x
        })),
        "s20": {},
        "s21": job.perks.map(x => render("jobs_21", {
          "s0": {
            "key": x
          },
          "s1": x
        })),
        "s22": {},
        "s23": {
          "onClick": () => {
            setSheet('');
            decide('save');
          }
        },
        "s24": {
          "component": Bookmark,
          "size": 17
        }
      })
    })
  });
}
