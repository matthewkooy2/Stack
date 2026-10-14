import {useScenario} from './scenarios';
import {backend} from './backend';
import {useLive} from './live-store';
import {itemsOf} from './applications-live';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import { migrateApplication, APPLICATION_STATUSES } from './application-store';
import { ApplicationDetail } from './application-detail-controller';
import React, { useState } from 'react';
import { subscribePreviewLoading, applicationsLoadingSnapshot } from './loading';
import { ApplicationCalendar } from './application-calendar-controller';
import { Menu, Search, SlidersHorizontal, ArrowUpRight, ChevronRight, X, Check, CalendarDays, Layers, Users, BriefcaseBusiness, FileText, GraduationCap } from 'lucide-react-native';
let records = [{
  id: 1,
  company: 'Northstar',
  initial: 'N',
  role: 'Associate Product Designer',
  location: 'New York · Hybrid',
  pay: '$75–90k',
  status: 'Interview',
  date: 'Applied Oct 1',
  next: 'Portfolio chat · Oct 8, 10:30 AM ET',
  note: 'Bring two projects and be ready to talk through your design decisions.',
  color: 'lilac'
}, {
  id: 2,
  company: 'Fieldwork',
  initial: 'f.',
  role: 'Software Engineering Intern',
  location: 'Remote · US',
  pay: '$38–45 / hr',
  status: 'Applied',
  date: 'Applied Oct 2',
  next: 'Waiting to hear back',
  note: '',
  color: 'mint'
}, {
  id: 3,
  company: 'Common Ground',
  initial: 'cg',
  role: 'Brand & Marketing Associate',
  location: 'Chicago · Hybrid',
  pay: '$60–72k',
  status: 'Saved',
  date: 'Saved today',
  next: 'Ready when you are',
  note: '',
  color: 'peach'
}, {
  id: 4,
  company: 'Forma',
  initial: 'F',
  role: 'Junior UX Researcher',
  location: 'Boston · Hybrid',
  pay: '$70–85k',
  status: 'Saved',
  date: 'Saved Oct 3',
  next: 'Ready when you are',
  note: 'Ask about the research mentorship program.',
  color: 'lilac'
}, {
  id: 5,
  company: 'Daylight',
  initial: 'd',
  role: 'Product Design Intern',
  location: 'Remote · US',
  pay: '$32 / hr',
  status: 'Closed',
  date: 'Closed Sep 28',
  next: 'Position filled',
  note: '',
  color: 'peach'
}];
try {
  const saved = JSON.parse(storage.getItem('stack.applications.v1'));
  if (Array.isArray(saved) && saved.length && saved.every(i => i.id && i.company && i.role)) records = saved;
} catch {}
;
records = records.map(migrateApplication);
const tabs = [['Network', Users], ['Applications', BriefcaseBusiness], ['Jobs', Layers], ['Resume', FileText], ['Prep', GraduationCap]];
export function ApplicationsPreview({
  onNavigate,
  onProfile
}) {
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, applicationsLoadingSnapshot);
  // Build-time constant: live builds list the account's saved jobs; mock builds keep the sample list below.
  const real = backend.live;
  const account = useLive();
  const loading = reviewLoading || real && account.status === 'loading';
  const [localItems, setItems] = useState(()=>real?[]:JSON.parse(storage.getItem('stack.applications.v1')||'null')||records),
    [filter, setFilter] = useState('All'),
    [query, setQuery] = useState(''),
    [search, setSearch] = useState(false),
    [selected, setSelected] = useState(null),
    [toast, setToast] = useState('');
  const [filtersOpen, setFiltersOpen] = useState(false),
    [calendarOpen, setCalendarOpen] = useState(false);
  useScenario('Applications/applications-controller', s=>{if(s.page==='calendar')setCalendarOpen(true);else if(s.page==='filters')setFiltersOpen(true);else if(s.page==='search')setSearch(true);else if(s.page&&!['list'].includes(s.page))setSelected(items[0]);});
  const items = real ? itemsOf(account.boot) : localItems;
  const current = real && selected ? items.find(i => i.id === selected.id) || null : selected;
  const visible = items.filter(i => (filter === 'All' || i.status === filter) && `${i.company} ${i.role}`.toLowerCase().includes(query.toLowerCase()));
  function open(item) {
    if (loading) return;
    setSelected(item);
  }
  React.useEffect(() => {
    if (!toast) return;
    const id = setTimeout(() => setToast(''), 2200);
    return () => clearTimeout(id);
  }, [toast]);
  if (current) return render("applications_1", {
    "s0": {},
    "s1": {
      "component": ApplicationDetail,
      "loading": loading,
      "item": current,
      "onClose": () => setSelected(null),
      "onNavigate": onNavigate,
      "onUpdate": updated => {
        if (real) return;
        const next = items.map(i => i.id === updated.id ? updated : i);
        storage.setItem('stack.applications.v1', JSON.stringify(next));
        records = next;
        setItems(next);
        setSelected(updated);
      }
    }
  });
  return render("applications_2", {
    "s0": {
      "variant": 'jobs-preview applications-preview' + (loading ? ' applications-skeleton' : ''),
      "aria-label": "Applications tracker"
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
    "s6": !calendarOpen ? render("applications_3", {
      "s0": {
        "aria-label": "Search applications",
        "aria-expanded": search,
        "onClick": () => {
          setSearch(!search);
          setQuery('');
        }
      },
      "s1": {
        "component": Search,
        "size": 20
      }
    }) : render("applications_4", {
      "s0": {
        "style": {
          width: 40
        }
      }
    }),
    "s7": calendarOpen ? render("applications_5", {
      "s0": {
        "component": ApplicationCalendar,
        "onClose": () => setCalendarOpen(false)
      }
    }) : render("applications_6", {
      "s0": {},
      "s1": {},
      "s2": {},
      "s3": {},
      "s4": {
        "aria-label": "Open application calendar",
        "onClick": () => setCalendarOpen(true)
      },
      "s5": {
        "component": CalendarDays,
        "size": 20
      },
      "s6": {
        "aria-label": filter === 'All' ? 'Filter applications' : 'Filter applications: ' + filter,
        "aria-haspopup": "dialog",
        "aria-expanded": filtersOpen,
        "onClick": () => setFiltersOpen(true)
      },
      "s7": {
        "component": SlidersHorizontal,
        "size": 20
      },
      "s8": filter !== 'All' && render("applications_7", {
        "s0": {}
      }),
      "s9": search && render("applications_8", {
        "s0": {},
        "s1": {
          "component": Search,
          "size": 16
        },
        "s2": {
          "autoFocus": true,
          "aria-label": "Search by role or company",
          "placeholder": "Role or company",
          "value": query,
          "onChange": e => setQuery(e.target.value)
        }
      }),
      "s10": loading && render("applications_9", {
        "s0": {
          "role": "status"
        }
      }),
      "s11": {
        "aria-busy": loading,
        "aria-hidden": loading || undefined,
        "inert": loading
      },
      "s12": (loading && !visible.length ? items : visible).map(item => render("applications_10", {
        "s0": {
          "disabled": loading,
          "key": item.id,
          "onClick": () => open(item)
        },
        "s1": {
          "variant": `application-logo ${item.color}`
        },
        "s2": item.initial,
        "s3": {},
        "s4": {},
        "s5": item.company,
        "s6": {},
        "s7": item.role,
        "s8": {
          "variant": `application-row-status status-${item.status.toLowerCase()}`
        },
        "s9": item.status,
        "s10": {
          "component": ChevronRight,
          "size": 16
        }
      })),
      "s13": !loading && !visible.length && render("applications_11", {
        "s0": {},
        "s1": {
          "component": BriefcaseBusiness,
          "size": 30
        },
        "s2": {},
        "s3": real && account.status === 'error' ? 'Could not load your applications.' : query ? 'No matches here.' : `Nothing ${filter.toLowerCase()} yet.`,
        "s4": {},
        "s5": real && account.status === 'error' ? account.error : query ? 'Try another role or company.' : 'Your next opportunity is waiting in Jobs.',
        "s6": {
          "onClick": () => real && account.status === 'error' ? account.retry() : query ? setQuery('') : onNavigate('Jobs')
        },
        "s7": real && account.status === 'error' ? 'Try again' : query ? 'Clear search' : 'Explore jobs'
      })
    }),
    "s8": {
      "aria-label": "Main navigation"
    },
    "s9": tabs.map(([name, Icon]) => render("applications_12", {
      "s0": {
        "key": name,
        "aria-current": name === 'Applications' ? 'page' : undefined,
        "onClick": () => name === 'Applications' ? setCalendarOpen(false) : onNavigate(name)
      },
      "s1": {
        "component": Icon,
        "size": 22
      },
      "s2": {},
      "s3": name,
      "s4": name === 'Applications' && render("applications_13", {
        "s0": {}
      })
    })),
    "s10": toast && !loading && render("applications_14", {
      "s0": {
        "role": "status"
      },
      "s1": {
        "component": Check,
        "size": 15
      },
      "s2": toast
    }),
    "s11": filtersOpen && render("applications_15", {
      "s0": {
        "onClick": () => setFiltersOpen(false)
      },
      "s1": {
        "role": "dialog",
        "aria-modal": "true",
        "aria-label": "Filter applications",
        "onClick": e => e.stopPropagation()
      },
      "s2": {},
      "s3": {
        "autoFocus": true,
        "aria-label": "Close filters",
        "onClick": () => setFiltersOpen(false)
      },
      "s4": {
        "component": X,
        "size": 21
      },
      "s5": {},
      "s6": {},
      "s7": {},
      "s8": ['All', ...APPLICATION_STATUSES].map(s => render("applications_16", {
        "s0": {
          "key": s,
          "aria-pressed": filter === s,
          "onClick": () => {
            setFilter(s);
            setFiltersOpen(false);
          }
        },
        "s1": {},
        "s2": s === 'All' ? 'All applications' : s,
        "s3": filter === s && render("applications_17", {
          "s0": {
            "component": Check,
            "size": 18
          }
        })
      }))
    })
  });
}
