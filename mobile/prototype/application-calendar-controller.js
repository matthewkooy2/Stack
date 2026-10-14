import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState } from 'react';
import { ArrowLeft, ChevronLeft, ChevronRight, Flame, Check, CalendarDays } from 'lucide-react-native';
import { subscribePreviewLoading, applicationsLoadingSnapshot } from './loading';
import { backend } from './backend';
import { useCalendar, streakOf } from './calendar-live';
const mockToday = '2026-10-04';
const mockActivity = {
  '2026-09-22': ['Daylight · Product Design Intern'],
  '2026-09-28': ['Linear · Design Intern', 'Notion · Associate Designer'],
  '2026-09-29': ['Figma · Product Design Intern'],
  '2026-09-30': ['Canva · Junior Designer', 'Spotify · UX Intern', 'Ramp · Product Designer'],
  '2026-10-01': ['Northstar · Associate Product Designer'],
  '2026-10-02': ['Fieldwork · Software Engineering Intern', 'Stripe · Frontend Intern'],
  '2026-10-03': ['Duolingo · Product Design Intern'],
  '2026-10-04': ['Airbnb · UX Research Intern', 'Adobe · Associate Designer']
};
const mockEvents = {
  '2026-10-08': [{
    title: 'Portfolio chat',
    company: 'Northstar',
    time: '10:30–11:00 AM ET'
  }]
};
function key(date) {
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}
function streak() {
  let n = 0,
    d = new Date(2026, 9, 4);
  while (mockActivity[key(d)]?.length) {
    n++;
    d.setDate(d.getDate() - 1);
  }
  return n;
}
export function ApplicationCalendar({
  onClose
}) {
  // Build-time constant: live builds read your applications, interviews and reminders; mock builds use samples.
  const real = backend.live;
  const cal = useCalendar(real);
  const reviewLoading = React.useSyncExternalStore(subscribePreviewLoading, applicationsLoadingSnapshot);
  const loading = reviewLoading || real && cal.loading;
  const now = new Date();
  const today = real ? cal.today : mockToday,
    activity = real ? cal.activity : mockActivity,
    events = real ? cal.events : mockEvents;
  const [month, setMonth] = useState(real ? new Date(now.getFullYear(), now.getMonth(), 1) : new Date(2026, 9, 1)),
    [selected, setSelected] = useState(null),
    [mockConnected, setConnected] = useState(false);
  const connected = real ? cal.connected : mockConnected;
  const year = month.getFullYear(),
    m = month.getMonth(),
    days = new Date(year, m + 1, 0).getDate(),
    offset = new Date(year, m, 1).getDay();
  const total = Object.entries(activity).filter(([k]) => k.startsWith(key(month).slice(0, 7))).reduce((n, [, v]) => n + v.length, 0);
  function move(delta) {
    const next = new Date(year, m + delta, 1);
    setMonth(next);
    setSelected(null);
  }
  const applications = activity[selected] || [],
    meetings = events[selected] || [];
  return render("application_calendar_1", {
    "s0": {
      "variant": "applications-scroll application-calendar" + (loading ? " calendar-skeleton" : ""),
      "aria-busy": loading
    },
    "s1": loading && render("application_calendar_2", {
      "s0": {
        "role": "status"
      }
    }),
    "s2": {},
    "s3": {
      "aria-label": "Back to applications",
      "onClick": onClose
    },
    "s4": {
      "component": ArrowLeft,
      "size": 20
    },
    "s5": {},
    "s6": {
      "onClick": () => {
        setMonth(real ? new Date(now.getFullYear(), now.getMonth(), 1) : new Date(2026, 9, 1));
        setSelected(today);
      }
    },
    "s7": {},
    "s8": {},
    "s9": month.toLocaleDateString('en-US', {
      month: 'long',
      year: 'numeric'
    }),
    "s10": {},
    "s11": {
      "aria-label": "Previous month",
      "onClick": () => move(-1)
    },
    "s12": {
      "component": ChevronLeft,
      "size": 18
    },
    "s13": {
      "aria-label": "Next month",
      "onClick": () => move(1)
    },
    "s14": {
      "component": ChevronRight,
      "size": 18
    },
    "s15": {
      "role": "group",
      "aria-label": "Application activity calendar"
    },
    "s16": ['S', 'M', 'T', 'W', 'T', 'F', 'S'].map((d, i) => render("application_calendar_3", {
      "s0": {
        "key": 'w' + i
      },
      "s1": d
    })),
    "s17": Array.from({
      length: offset
    }, (_, i) => render("application_calendar_4", {
      "s0": {
        "key": 'blank' + i
      }
    })),
    "s18": Array.from({
      length: days
    }, (_, i) => {
      const date = key(new Date(year, m, i + 1)),
        count = loading ? 0 : activity[date]?.length || 0;
      return render("application_calendar_5", {
        "s0": {
          "key": date,
          "variant": 'calendar-day level-' + Math.min(count, 3) + (date === today ? ' is-today' : ''),
          "aria-label": loading ? date + ', activity loading' : date + ', ' + count + ' applications' + (events[date] ? ', interview scheduled' : ''),
          "aria-pressed": selected === date,
          "onClick": () => setSelected(date)
        },
        "s1": {},
        "s2": i + 1,
        "s3": count > 0 && render("application_calendar_6", {
          "s0": {},
          "s1": count
        }),
        "s4": !loading && events[date] && render("application_calendar_7", {
          "s0": {}
        })
      });
    }),
    "s19": {},
    "s20": {},
    "s21": {
      "component": Flame,
      "size": 16
    },
    "s22": {
      "variant": loading ? "skeleton-value" : "",
      "aria-hidden": loading
    },
    "s23": real ? streakOf(activity, now) : streak(),
    "s24": {},
    "s25": {
      "variant": loading ? "skeleton-value" : "",
      "aria-hidden": loading
    },
    "s26": total,
    "s27": selected && render("application_calendar_8", {
      "s0": {},
      "s1": {},
      "s2": new Date(selected + 'T12:00:00').toLocaleDateString('en-US', {
        weekday: 'long',
        month: 'short',
        day: 'numeric'
      }),
      "s3": selected === today && render("application_calendar_9", {
        "s0": {}
      }),
      "s4": {
        "aria-label": "Hide day details",
        "onClick": () => setSelected(null)
      },
      "s5": loading ? render("application_calendar_10", {
        "s0": {
          "aria-hidden": "true"
        },
        "s1": {},
        "s2": {},
        "s3": {}
      }) : render("application_calendar_11", {
        "s0": meetings.map(e => render("application_calendar_12", {
          "s0": {
            "key": e.title
          },
          "s1": {
            "component": CalendarDays,
            "size": 18
          },
          "s2": {},
          "s3": {},
          "s4": e.title,
          "s5": e.company,
          "s6": {},
          "s7": e.time
        })),
        "s1": {},
        "s2": applications.length ? applications.length + ' submitted' : 'No applications',
        "s3": applications.map(a => render("application_calendar_13", {
          "s0": {
            "key": a
          },
          "s1": {
            "component": Check,
            "size": 13
          },
          "s2": {},
          "s3": a
        }))
      })
    }),
    "s28": {
      "aria-pressed": connected,
      "onClick": () => real ? connected ? null : cal.connect() : setConnected(!connected)
    },
    "s29": {},
    "s30": {},
    "s31": connected ? 'Calendar connected' : 'Connect Google Calendar',
    "s32": {},
    "s33": connected ? render("application_calendar_14", {
      "s0": {
        "component": Check,
        "size": 18
      }
    }) : render("application_calendar_15", {
      "s0": {
        "component": ChevronRight,
        "size": 18
      }
    })
  });
}
