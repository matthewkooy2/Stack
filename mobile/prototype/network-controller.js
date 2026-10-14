import {useScenario} from './scenarios';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import { PreviewControls } from './review-controls';
import React, { useState, useEffect, useRef, useSyncExternalStore } from 'react';
import { Menu, ChevronRight, ArrowLeft, Users, BriefcaseBusiness, Layers, FileText, GraduationCap, Plus, Pencil, ChevronDown, Search, Mail, Globe, Bell, Trash2, Bookmark, SlidersHorizontal } from 'lucide-react-native';
import { PublicProfiles } from './public-profiles-controller';
import { subscribePreviewLoading, networkLoadingSnapshot } from './loading';
import { snapshot, subscribe, update, reset, people, exampleCSV, delay, saveContact, parseContacts, importContacts, saveReminder, localDateTime, stopContact, createTask, generateTask, sendTask, reconcileTask, validateLinkedIn, startLinkedIn, analyzeLinkedIn } from './network-model';
import { backend, describeError } from './backend';
import { useLive } from './live-store';
import { syncLive, liveError, saveContactLive, importContactsLive, stopContactLive, saveReminderLive, createTaskLive, sendTaskLive, reconcileTaskLive, retryTaskLive } from './network-model';
import { saveLinkedInTarget, startLinkedInRun, linkedinAvailability } from './network-live';
const tabs = [['Network', Users], ['Applications', BriefcaseBusiness], ['Jobs', Layers], ['Resume', FileText], ['Prep', GraduationCap]];
const labels = {
  generating: 'Creating draft',
  review: 'Needs your approval',
  sending: 'Sending',
  sent: 'Sent · simulated',
  failed: 'Draft failed',
  uncertain: 'Confirm delivery',
  cancelled: 'Cancelled',
  signin: 'Sign-in needed',
  scanning: 'Analyzing profile',
  blocked: 'Analysis paused',
  complete: 'Review ready',
  expired: 'Session expired'
};
const initials = name => name.split(' ').map(n => n[0]).slice(0, 2).join('');
const dateText = value => new Date(value).toLocaleString(undefined, {
  dateStyle: 'medium',
  timeStyle: 'short'
});
function Field({
  label,
  multiline = false,
  loading = false,
  ...props
}) {
  return render("network_1", {
    "s0": {},
    "s1": label,
    "s2": {
      "variant": loading ? 'net-input-mask' : ''
    },
    "s3": multiline ? render("network_2", {
      "s0": {
        ...props,
        "disabled": loading || props.disabled,
        "aria-hidden": loading || undefined
      }
    }) : render("network_3", {
      "s0": {
        ...props,
        "onInput": props.type === "datetime-local" ? props.onChange : props.onInput,
        "disabled": loading || props.disabled,
        "aria-hidden": loading || undefined
      }
    })
  });
}
function Entry({
  title,
  hint,
  onClick,
  disabled,
  loading = false,
  pendingHint = false,
  icon: Icon,
  mark
}) {
  return render("network_4", {
    "s0": {
      "onClick": onClick,
      "disabled": disabled || loading || pendingHint,
      "aria-label": loading ? 'Loading item' : undefined
    },
    "s1": (Icon || mark) && render("network_5", {
      "s0": {
        "variant": 'net-entry-mark' + (loading ? ' net-mask' : ''),
        "aria-hidden": loading || undefined
      },
      "s1": Icon ? render("network_6", {
        "s0": {
          "component": Icon,
          "size": 19
        }
      }) : mark
    }),
    "s2": {},
    "s3": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s4": title,
    "s5": {
      "variant": loading || pendingHint ? 'net-mask' : '',
      "aria-hidden": loading || pendingHint || undefined
    },
    "s6": hint,
    "s7": {
      "component": ChevronRight,
      "size": 17
    }
  });
}
function Fold({
  title,
  children,
  initial = false
}) {
  return render("network_7", {
    "s0": {
      "open": initial || undefined
    },
    "s1": {},
    "s2": title,
    "s3": {
      "component": ChevronDown,
      "size": 16
    },
    "s4": children
  });
}
function Editable({
  label,
  value,
  onChange,
  loading = false,
  disabled = false,
  multiline = false
}) {
  const [open, setOpen] = useState(false),
    trigger = useRef(null);
  return render("network_8", {
    "s0": {
      "variant": "net-editable" + (label === "Message" ? " net-email-body" : "")
    },
    "s1": open ? render("network_9", {
      "s0": {},
      "s1": {
        "component": Field,
        "label": label,
        "multiline": multiline,
        "value": value,
        "onChange": onChange,
        "loading": loading,
        "disabled": disabled,
        "autoFocus": true
      },
      "s2": {
        "onClick": () => {
          setOpen(false);
          requestAnimationFrame(() => trigger.current?.focus());
        }
      }
    }) : render("network_10", {
      "s0": {},
      "s1": {
        "ref": trigger,
        "disabled": loading || disabled,
        "aria-expanded": false,
        "aria-label": 'Edit ' + label,
        "onClick": () => setOpen(true)
      },
      "s2": {},
      "s3": label,
      "s4": {
        "variant": loading ? 'net-mask' : '',
        "aria-hidden": loading || undefined
      },
      "s5": value || 'Not added yet',
      "s6": {
        "aria-label": 'Edit ' + label + ' field',
        "disabled": loading || disabled,
        "onClick": () => setOpen(true)
      },
      "s7": {
        "component": Pencil,
        "size": 17
      }
    })
  });
}
function Empty({
  title,
  children
}) {
  return render("network_11", {
    "s0": {},
    "s1": {
      "component": Users,
      "size": 26
    },
    "s2": {},
    "s3": title,
    "s4": {},
    "s5": children
  });
}
function Announcement({
  loading,
  label
}) {
  return loading ? render("network_12", {
    "s0": {
      "role": "status"
    },
    "s1": label
  }) : null;
}
export function NetworkPreview({
  onNavigate,
  onProfile
}) {
  // Build-time constant: live builds use the account's contacts and outreach; mock builds keep the sample network.
  const real = backend.live;
  const account = useLive();
  const data = useSyncExternalStore(subscribe, snapshot),
    reviewLoading = useSyncExternalStore(subscribePreviewLoading, networkLoadingSnapshot);
  const loading = reviewLoading || real && account.status === 'loading';
  useEffect(() => {
    if (real && account.status === 'ready') syncLive();
  }, [real, account.loadedAt]);
  const [routes, setRoutes] = useState([{
      page: 'home'
    }]),
    [error, setError] = useState(''),
    [notice, setNotice] = useState(''),
    [scenario, setScenario] = useState('normal');
  const [contactQuery, setContactQuery] = useState(''),
    [contactSearchOpen, setContactSearchOpen] = useState(false),
    [peopleQuery, setPeopleQuery] = useState(''),
    [peopleSearchOpen, setPeopleSearchOpen] = useState(false),
    [filter, setFilter] = useState('Everyone'),
    [filtersOpen, setFiltersOpen] = useState(false),
    [importRows, setImportRows] = useState(null),
    [importBusy, setImportBusy] = useState(false);
  useScenario('Network/network-controller', s=>{setRoutes([{page:'home'},...(s.page&&s.page!=='home'?[{page:s.page,id:['person','followups'].includes(s.page)?'person-1':s.contactId,taskId:s.taskId,runId:s.runId}]:[])]);setScenario(s.state||'normal');});
  const heading = useRef(null),
    importToken = useRef(0),
    mounted = useRef(true);
  const route = routes[routes.length - 1],
    page = route.page;
  const contact = data.contacts.find(c => c.id === route.id),
    person = people.find(p => p.id === route.id),
    personData = data.people[route.id];
  const task = data.tasks.find(t => t.id === route.taskId),
    taskContact = data.contacts.find(c => c.id === task?.contactId),
    run = data.linkedin.runs.find(r => r.id === route.runId);
  const selectedContact = contact || taskContact;
  useEffect(() => {
    if (real && route.page === 'linkedinTask' && run?.status === 'signin') setNotice('Sign in to LinkedIn in the private browser: open your profile, then Agents → Activity, and choose this task. Stack never sees your password.');
  }, [real, route.page, run?.status]);
  useEffect(() => () => {
    mounted.current = false;
    importToken.current++;
  }, []);
  useEffect(() => {
    heading.current?.focus();
  }, [route]);
  function go(next, params = {}) {
    importToken.current++;
    setImportBusy(false);
    setRoutes(r => [...r, {
      page: next,
      ...params
    }]);
    setError('');
    setNotice('');
  }
  function home() {
    importToken.current++;
    setImportBusy(false);
    setRoutes([{
      page: 'home'
    }]);
    setError('');
    setNotice('');
  }
  function back() {
    importToken.current++;
    setImportBusy(false);
    setRoutes(r => r.length > 1 ? r.slice(0, -1) : r);
    setError('');
    setNotice('');
  }
  async function attempt(action) {
    setError('');
    try {
      return await action();
    } catch (e) {
      setError(describeError(e));
      return null;
    }
  }
  function editForm(key, value) {
    update(s => {
      s.contactForm[key] = value;
    });
  }
  function updateRun(edit) {
    update(s => edit(s.linkedin.runs.find(r => r.id === route.runId)));
  }
  async function openDraft(id, followup = false) {
    const taskId = await attempt(() => real ? createTaskLive(id, followup) : createTask(id, followup));
    if (!taskId) return;
    go('draft', {
      taskId
    });
    if (!real && snapshot().tasks.find(t => t.id === taskId).status === 'generating') generateTask(taskId, scenario === 'draft-error');
  }
  function retryDraft() {
    if (real) {
      attempt(() => retryTaskLive(task.id));
      return;
    }
    update(s => {
      const t = s.tasks.find(t => t.id === task.id);
      t.status = 'generating';
      delete t.error;
    });
    setScenario('normal');
    generateTask(task.id, false);
  }
  async function previewCSV() {
    setError('');
    setImportBusy(true);
    const token = ++importToken.current;
    if (!real) await delay();
    if (!mounted.current || token !== importToken.current) return;
    try {
      const rows = parseContacts(snapshot().csv);
      const seen = new Set(snapshot().contacts.map(c => c.email).filter(Boolean));
      setImportRows(rows.filter(c => {
        if (c.email && seen.has(c.email)) return false;
        if (c.email) seen.add(c.email);
        return true;
      }));
    } catch (e) {
      setError(e.message);
    }
    setImportBusy(false);
  }
  function setup() {
    return render("network_13", {
      "s0": {
        "role": "status"
      },
      "s1": {},
      "s2": {},
      "s3": {
        "onClick": () => setScenario('normal')
      }
    });
  }
  async function copy(text) {
    try {
      await services.copy(text);
      setNotice('Copied. Apply the changes on LinkedIn when ready.');
    } catch {
      setError('Copy is unavailable. Open the field and select its text to copy.');
    }
  }
  const title = {
    home: 'Network',
    contacts: 'Your contacts',
    add: data.contactForm.id ? 'Edit contact' : 'Add contact',
    import: 'Import contacts',
    contact: contact?.name,
    discover: 'Discover people',
    person: person?.name,
    followups: 'Follow-ups',
    draft: task?.followup ? 'Review follow-up' : 'Review email',
    linkedin: 'LinkedIn review',
    linkedinTask: 'LinkedIn review'
  }[page];
  const reminders = data.reminders.filter(r => r.targetId === route.id),
    reminderForm = data.reminderForms[route.id];
  const taskLocked = loading || !task || task.status !== 'review' || taskContact?.stopped || !taskContact?.email || taskContact.email !== task.recipient?.email || taskContact.name !== task.recipient?.name;
  return render("network_14", {
    "s0": {},
    "s1": {
      "component": PreviewControls,
      "scenario": scenario,
      "setScenario": setScenario,
      "contact": selectedContact,
      "advance": () => openDraft(selectedContact.id, true),
      "reply": () => {
        (real ? attempt(() => stopContactLive(selectedContact.id)) : Promise.resolve(stopContact(selectedContact.id, true))).then(() => setNotice('Reply received. Outreach and follow-ups stopped.'));
      },
      "expire": run && ['signin', 'scanning'].includes(run.status) ? () => updateRun(r => {
        r.status = 'expired';
      }) : null
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
        width: 44
      }
    },
    "s8": page === 'profiles' ? render("network_15", {
      "s0": {
        "component": PublicProfiles,
        "onClose": back
      }
    }) : render("network_16", {
      "s0": {
        "key": page + JSON.stringify(route)
      },
      "s1": {},
      "s2": page !== 'home' && render("network_17", {
        "s0": {
          "aria-label": "Back",
          "onClick": back
        },
        "s1": {
          "component": ArrowLeft,
          "size": 20
        }
      }),
      "s3": {
        "ref": heading
      },
      "s4": title,
      "s5": error && render("network_18", {
        "s0": {
          "role": "alert"
        },
        "s1": error
      }),
      "s6": notice && render("network_19", {
        "s0": {
          "role": "status"
        },
        "s1": notice
      }),
      "s7": page === 'home' && render("network_20", {
        "s0": {
          "component": Entry,
          "mark": "in",
          "title": "Strengthen your LinkedIn profile",
          "hint": "Review your professional story",
          "onClick": () => go('linkedin')
        },
        "s1": {
          "component": Entry,
          "icon": Users,
          "title": "Your contacts",
          "hint": "People you know or have researched",
          "onClick": () => go('contacts')
        },
        "s2": {
          "component": Entry,
          "icon": Search,
          "title": "Discover people",
          "hint": "Explore people and your saved circle",
          "onClick": () => go('discover')
        },
        "s3": {
          "component": Entry,
          "icon": Globe,
          "title": "Public profiles",
          "hint": "LinkedIn, GitHub & portfolio",
          "onClick": () => go('profiles')
        }
      }),
      "s8": page === 'contacts' && render("network_21", {
        "s0": {},
        "s1": {
          "onClick": () => go('add')
        },
        "s2": {
          "component": Plus,
          "size": 16
        },
        "s3": {
          "onClick": () => {
            setImportRows(null);
            go('import');
          }
        },
        "s4": {
          "aria-label": "Search contacts",
          "aria-expanded": contactSearchOpen,
          "onClick": () => setContactSearchOpen(!contactSearchOpen)
        },
        "s5": {
          "component": Search,
          "size": 18
        },
        "s6": contactSearchOpen && render("network_22", {
          "s0": {
            "component": Field,
            "label": "Search contacts",
            "value": contactQuery,
            "onChange": e => setContactQuery(e.target.value),
            "placeholder": "Name, company, or email"
          }
        }),
        "s7": {
          "component": Announcement,
          "loading": loading,
          "label": "Loading contacts"
        },
        "s8": data.contacts.filter(c => (c.name + ' ' + c.company + ' ' + c.email).toLowerCase().includes(contactQuery.toLowerCase())).map(c => render("network_23", {
          "s0": {
            "component": Entry,
            "key": c.id,
            "mark": initials(c.name),
            "title": c.name,
            "hint": `${c.company || c.email || 'No email'} · ${c.stopped ? 'Outreach stopped' : c.selected ? 'Selected' : 'Not selected'}`,
            "loading": loading,
            "onClick": () => go('contact', {
              id: c.id
            })
          }
        })),
        "s9": loading && !data.contacts.length && render("network_24", {
          "s0": {
            "component": Entry,
            "title": "Loading contact",
            "hint": "Loading contact details",
            "mark": "\u2026",
            "loading": true
          }
        }),
        "s10": !loading && !data.contacts.length && render("network_25", {
          "s0": {
            "component": Empty,
            "title": "No contacts yet"
          }
        }),
        "s11": !loading && data.contacts.length > 0 && !data.contacts.some(c => (c.name + ' ' + c.company + ' ' + c.email).toLowerCase().includes(contactQuery.toLowerCase())) && render("network_26", {
          "s0": {
            "component": Empty,
            "title": "No matches"
          }
        })
      }),
      "s9": page === 'add' && render("network_27", {
        "s0": {
          "onSubmit": async e => {
            e.preventDefault();
            const id = await attempt(() => real ? saveContactLive(data.contactForm) : saveContact(data.contactForm));
            if (id) {
              back();
              setNotice('Contact saved. Nothing was sent.');
            }
          }
        },
        "s1": {
          "component": Field,
          "label": "Name",
          "required": true,
          "maxLength": 120,
          "value": data.contactForm.name,
          "onChange": e => editForm('name', e.target.value)
        },
        "s2": {
          "component": Field,
          "label": "Verified email (optional)",
          "type": "email",
          "value": data.contactForm.email,
          "onChange": e => editForm('email', e.target.value)
        },
        "s3": {
          "component": Field,
          "label": "Company (optional)",
          "maxLength": 160,
          "value": data.contactForm.company,
          "onChange": e => editForm('company', e.target.value)
        },
        "s4": {
          "component": Fold,
          "title": "Relationship & research",
          "initial": !!data.contactForm.relationship || !!data.contactForm.source_url
        },
        "s5": {
          "component": Field,
          "label": "How you know them",
          "multiline": true,
          "maxLength": 2000,
          "value": data.contactForm.relationship,
          "onChange": e => editForm('relationship', e.target.value)
        },
        "s6": {
          "component": Field,
          "label": "Public research source (optional)",
          "type": "url",
          "placeholder": "https://company.com/team",
          "value": data.contactForm.source_url,
          "onChange": e => editForm('source_url', e.target.value)
        },
        "s7": {
          "type": "submit"
        },
        "s8": {}
      }),
      "s10": page === 'import' && render("network_28", {
        "s0": !importRows ? render("network_29", {
          "s0": {},
          "s1": {
            "component": Field,
            "label": "CSV or email addresses",
            "multiline": true,
            "value": data.csv,
            "disabled": importBusy,
            "onChange": e => update(s => {
              s.csv = e.target.value;
            })
          },
          "s2": {},
          "s3": {},
          "s4": {
            "omit": real,
            "disabled": importBusy,
            "onClick": () => update(s => {
              s.csv = exampleCSV;
            })
          },
          "s5": {
            "disabled": importBusy,
            "onClick": previewCSV
          },
          "s6": importBusy ? 'Checking contacts…' : 'Review contacts',
          "s7": {}
        }) : render("network_30", {
          "s0": {},
          "s1": {},
          "s2": importRows.length,
          "s3": {
            "onClick": () => setImportRows(null)
          },
          "s4": {},
          "s5": importRows.map((c, i) => render("network_31", {
            "s0": {
              "key": i
            },
            "s1": {},
            "s2": initials(c.name),
            "s3": {},
            "s4": {},
            "s5": c.name,
            "s6": {},
            "s7": c.email || 'No email',
            "s8": c.relationship && render("network_32", {
              "s0": {},
              "s1": c.relationship
            })
          })),
          "s6": importRows.length ? render("network_33", {
            "s0": {
              "onClick": async () => {
                const count = await attempt(() => real ? importContactsLive(importRows) : importContacts(importRows));
                if (count !== null) {
                  back();
                  setImportRows(null);
                  setNotice(`${count} contacts imported. Select a contact before drafting.`);
                }
              }
            }
          }) : render("network_34", {
            "s0": {
              "component": Empty,
              "title": "Already in your contacts"
            }
          })
        }),
        "s1": {}
      }),
      "s11": page === 'contact' && contact && render("network_35", {
        "s0": {},
        "s1": {},
        "s2": initials(contact.name),
        "s3": {},
        "s4": {},
        "s5": contact.company || 'Your connection',
        "s6": {},
        "s7": contact.email || 'No email added',
        "s8": {
          "aria-label": "Edit contact",
          "onClick": () => {
            update(s => {
              s.contactForm = {
                ...contact
              };
            });
            go('add');
          }
        },
        "s9": {
          "component": Pencil,
          "size": 17
        },
        "s10": {},
        "s11": contact.stopped ? `Outreach stopped · ${contact.stopReason}` : contact.selected ? 'Selected for outreach' : 'Not selected for outreach',
        "s12": (contact.relationship || contact.source_url) && render("network_36", {
          "s0": {
            "component": Fold,
            "title": "Relationship & research"
          },
          "s1": {},
          "s2": contact.relationship || 'No relationship added.',
          "s3": contact.source_url && render("network_37", {
            "s0": {
              "href": contact.source_url,
              "target": "_blank",
              "rel": "noreferrer"
            }
          })
        }),
        "s13": scenario === 'setup' ? setup() : null,
        "s14": !contact.selected && !contact.stopped && render("network_38", {
          "s0": {
            "disabled": loading,
            "onClick": () => update(s => {
              s.contacts.find(c => c.id === contact.id).selected = true;
            })
          }
        }),
        "s15": contact.selected && !contact.stopped && render("network_39", {
          "s0": {
            "component": Entry,
            "icon": Mail,
            "title": "Contact outreach",
            "hint": data.tasks.some(t => t.contactId === contact.id && ['review', 'failed', 'uncertain'].includes(t.status)) ? 'Continue your draft or review' : 'Draft an email for your review',
            "disabled": loading || scenario === 'setup' || !contact.email,
            "onClick": () => openDraft(contact.id)
          }
        }),
        "s16": !contact.email && !contact.stopped && render("network_40", {
          "s0": {}
        }),
        "s17": !contact.stopped && render("network_41", {
          "s0": {
            "disabled": loading,
            "onClick": () => {
              (real ? attempt(() => stopContactLive(contact.id)) : Promise.resolve(stopContact(contact.id))).then(() => setNotice('Outreach and follow-ups stopped.'));
            }
          }
        }),
        "s18": {
          "component": Fold,
          "title": "Follow-up rules"
        },
        "s19": {},
        "s20": {
          "component": Field,
          "label": "Follow-ups per contact (0\u20133)",
          "type": "number",
          "min": "0",
          "max": "3",
          "value": data.policy.limit,
          "onChange": e => {
            const value = Number(e.target.value);
            if (Number.isInteger(value) && value >= 0 && value <= 3) update(s => {
              s.policy.limit = value;
              if (!value) {
                s.contacts.forEach(c => {
                  c.nextAt = 0;
                });
                s.tasks.filter(t => t.followup && ['generating', 'review', 'failed'].includes(t.status)).forEach(t => {
                  t.status = 'cancelled';
                });
              }
            });
          }
        },
        "s21": {
          "component": Field,
          "label": "Days between follow-ups (3\u201330)",
          "type": "number",
          "min": "3",
          "max": "30",
          "value": data.policy.days,
          "onChange": e => {
            const value = Number(e.target.value);
            if (Number.isInteger(value) && value >= 3 && value <= 30) update(s => {
              s.policy.days = value;
            });
          }
        },
        "s22": {
          "component": Fold,
          "title": "Outreach activity",
          "initial": true
        },
        "s23": {},
        "s24": contact.followups,
        "s25": contact.nextAt > 0 ? ` · Next draft ${dateText(contact.nextAt)}` : '',
        "s26": data.tasks.filter(t => t.contactId === contact.id).map(t => render("network_42", {
          "s0": {
            "component": Entry,
            "key": t.id,
            "title": t.followup ? 'Follow-up email' : 'Initial outreach',
            "hint": `${labels[t.status]} · ${dateText(t.createdAt)}`,
            "loading": loading,
            "onClick": () => go('draft', {
              taskId: t.id
            })
          }
        })),
        "s27": !loading && !data.tasks.some(t => t.contactId === contact.id) && render("network_43", {
          "s0": {}
        })
      }),
      "s12": page === 'draft' && task && taskContact && render("network_44", {
        "s0": {},
        "s1": task.recipient?.name || 'Recipient not recorded',
        "s2": {},
        "s3": task.recipient?.email || 'No recorded email',
        "s4": {
          "role": "status"
        },
        "s5": labels[task.status],
        "s6": task.error && render("network_45", {
          "s0": {
            "role": "alert"
          },
          "s1": task.error
        }),
        "s7": task.status === 'failed' && render("network_46", {
          "s0": {
            "onClick": retryDraft
          }
        }),
        "s8": task.status === 'uncertain' && render("network_47", {
          "s0": {},
          "s1": {},
          "s2": {
            "onClick": () => real ? attempt(() => reconcileTaskLive(task.id, true)) : reconcileTask(task.id, true)
          },
          "s3": {
            "onClick": () => real ? attempt(() => reconcileTaskLive(task.id, false)) : reconcileTask(task.id, false)
          }
        }),
        "s9": task.status === 'cancelled' ? render("network_48", {
          "s0": {}
        }) : render("network_49", {
          "s0": {
            "component": Fold,
            "title": "Email",
            "initial": true
          },
          "s1": {
            "component": Announcement,
            "loading": loading || task.status === 'generating',
            "label": "Loading email draft"
          },
          "s2": {
            "component": Editable,
            "label": "Subject",
            "value": task.subject,
            "loading": loading || task.status === 'generating',
            "disabled": task.status !== 'review',
            "onChange": e => update(s => {
              s.tasks.find(t => t.id === task.id).subject = e.target.value;
            })
          },
          "s3": {
            "component": Editable,
            "label": "Message",
            "multiline": true,
            "value": task.body,
            "loading": loading || task.status === 'generating',
            "disabled": task.status !== 'review',
            "onChange": e => update(s => {
              s.tasks.find(t => t.id === task.id).body = e.target.value;
            })
          },
          "s4": {}
        }),
        "s10": task.status === 'review' && render("network_50", {
          "s0": {
            "disabled": taskLocked || !task.subject.trim() || !task.body.trim(),
            "onClick": () => {
              setError('');
              (real ? sendTaskLive(task.id) : sendTask(task.id, scenario)).catch(e => setError(describeError(e)));
            }
          },
          "s1": {
            "disabled": loading,
            "onClick": () => update(s => {
              s.tasks.find(t => t.id === task.id).status = 'cancelled';
            })
          }
        }),
        "s11": task.status === 'sent' && render("network_51", {
          "s0": {
            "role": "status"
          }
        }),
        "s12": {}
      }),
      "s13": page === 'discover' && render("network_52", {
        "s0": {},
        "s1": {
          "aria-pressed": filter === 'Everyone',
          "onClick": () => setFilter('Everyone')
        },
        "s2": {
          "aria-pressed": filter === 'Saved',
          "onClick": () => setFilter('Saved')
        },
        "s3": {
          "aria-label": "Search people",
          "onClick": () => setPeopleSearchOpen(!peopleSearchOpen)
        },
        "s4": {
          "component": Search,
          "size": 18
        },
        "s5": {
          "aria-label": "Filter people",
          "aria-expanded": filtersOpen,
          "onClick": () => setFiltersOpen(!filtersOpen)
        },
        "s6": {
          "component": SlidersHorizontal,
          "size": 18
        },
        "s7": filtersOpen && render("network_53", {
          "s0": {},
          "s1": {},
          "s2": ['Everyone', 'Saved', 'Alumni'].map(f => render("network_54", {
            "s0": {
              "key": f,
              "aria-pressed": filter === f,
              "onClick": () => {
                setFilter(f);
                setFiltersOpen(false);
              }
            },
            "s1": f
          }))
        }),
        "s8": peopleSearchOpen && render("network_55", {
          "s0": {
            "component": Field,
            "label": "Search people",
            "value": peopleQuery,
            "onChange": e => setPeopleQuery(e.target.value),
            "placeholder": "Name, role, or company"
          }
        }),
        "s9": {},
        "s10": {
          "component": Announcement,
          "loading": loading,
          "label": "Loading people"
        },
        "s11": people.filter(p => (filter !== 'Saved' || data.people[p.id].saved) && (filter !== 'Alumni' || p.signal === 'Fellow alum') && (p.name + ' ' + p.role + ' ' + p.company).toLowerCase().includes(peopleQuery.toLowerCase())).map(p => render("network_56", {
          "s0": {
            "key": p.id
          },
          "s1": {
            "component": Entry,
            "mark": p.initials,
            "title": p.name,
            "hint": `${p.role} · ${p.company} · ${p.signal}`,
            "loading": loading,
            "onClick": () => go('person', {
              id: p.id
            })
          },
          "s2": {
            "disabled": loading,
            "aria-label": (data.people[p.id].saved ? 'Unsave ' : 'Save ') + p.name,
            "aria-pressed": data.people[p.id].saved,
            "onClick": () => update(s => {
              s.people[p.id].saved = !s.people[p.id].saved;
            })
          },
          "s3": {
            "component": Bookmark,
            "size": 18,
            "fill": data.people[p.id].saved ? 'currentColor' : 'none'
          }
        })),
        "s12": !loading && !people.some(p => (filter !== 'Saved' || data.people[p.id].saved) && (filter !== 'Alumni' || p.signal === 'Fellow alum') && (p.name + ' ' + p.role + ' ' + p.company).toLowerCase().includes(peopleQuery.toLowerCase())) && render("network_57", {
          "s0": {
            "component": Empty,
            "title": peopleQuery ? 'No matches' : 'No saved people yet'
          }
        })
      }),
      "s14": page === 'person' && person && render("network_58", {
        "s0": {
          "component": Announcement,
          "loading": loading,
          "label": "Loading person details"
        },
        "s1": {
          "variant": loading ? 'net-intro net-mask' : 'net-intro',
          "aria-hidden": loading || undefined
        },
        "s2": person.role,
        "s3": person.company,
        "s4": {},
        "s5": person.detail,
        "s6": {},
        "s7": {
          "variant": loading ? 'net-muted net-mask' : 'net-muted',
          "aria-hidden": loading || undefined
        },
        "s8": person.about,
        "s9": {
          "variant": loading ? 'net-muted net-mask' : 'net-muted',
          "aria-hidden": loading || undefined
        },
        "s10": person.topics,
        "s11": {
          "disabled": loading,
          "aria-pressed": personData.saved,
          "onClick": () => update(s => {
            s.people[person.id].saved = !s.people[person.id].saved;
          })
        },
        "s12": personData.saved ? 'Remove from saved' : 'Save person',
        "s13": {
          "component": Entry,
          "icon": Bell,
          "title": "Follow-ups",
          "pendingHint": loading,
          "hint": `${reminders.filter(r => !r.done).length} open reminders`,
          "onClick": () => go('followups', {
            id: person.id
          })
        },
        "s14": {
          "component": Fold,
          "title": "Private notes"
        },
        "s15": {
          "component": Editable,
          "label": "Private notes",
          "multiline": true,
          "value": personData.notes,
          "loading": loading,
          "onChange": e => update(s => {
            s.people[person.id].notes = e.target.value;
          })
        },
        "s16": {
          "component": Fold,
          "title": "Outreach draft"
        },
        "s17": {
          "component": Editable,
          "label": "Outreach draft",
          "multiline": true,
          "value": personData.draft,
          "loading": loading,
          "onChange": e => update(s => {
            s.people[person.id].draft = e.target.value;
          })
        },
        "s18": {}
      }),
      "s15": page === 'followups' && person && render("network_59", {
        "s0": {},
        "s1": person.name,
        "s2": {
          "disabled": loading,
          "onClick": () => update(s => {
            s.reminderForms[person.id] = {
              id: '',
              title: '',
              due: localDateTime(Date.now() + 86400000)
            };
          })
        },
        "s3": {
          "component": Plus,
          "size": 16
        },
        "s4": reminderForm && render("network_60", {
          "s0": {
            "onSubmit": e => {
              e.preventDefault();
              const fields = {
                get: key => snapshot().reminderForms[person.id][key]
              };
              update(s => {
                s.reminderForms[person.id] = {
                  ...reminderForm,
                  title: fields.get('title'),
                  due: fields.get('due')
                };
              });
              attempt(async () => {
                const form = {
                  ...reminderForm,
                  title: fields.get('title'),
                  due: fields.get('due')
                };
                if (real) await saveReminderLive(person.id, form);else saveReminder(person.id, form);
                return true;
              }).then(result => result && setNotice(reminderForm.id ? 'Reminder rescheduled and reopened.' : 'Reminder added.'));
            }
          },
          "s1": {
            "component": Field,
            "label": "Reminder",
            "name": "title",
            "required": true,
            "maxLength": 160,
            "value": reminderForm.title,
            "disabled": loading,
            "onChange": e => update(s => {
              s.reminderForms[person.id].title = e.target.value;
            })
          },
          "s2": {
            "component": Field,
            "label": "Date and time",
            "name": "due",
            "type": "datetime-local",
            "required": true,
            "value": reminderForm.due,
            "disabled": loading,
            "onChange": e => update(s => {
              s.reminderForms[person.id].due = e.target.value;
            })
          },
          "s3": {
            "disabled": loading,
            "type": "submit"
          },
          "s4": reminderForm.id ? 'Save changes' : 'Save reminder',
          "s5": {
            "type": "button",
            "onClick": () => update(s => {
              delete s.reminderForms[person.id];
            })
          }
        }),
        "s5": {
          "component": Announcement,
          "loading": loading,
          "label": "Loading reminders"
        },
        "s6": (reminders.length ? reminders : loading ? [{
          id: 'pending',
          title: 'Loading reminder',
          dueAt: Date.now(),
          done: false
        }] : []).map(r => render("network_61", {
          "s0": {
            "key": r.id
          },
          "s1": {
            "variant": loading ? 'net-mask' : '',
            "aria-hidden": loading || undefined
          },
          "s2": r.title,
          "s3": {
            "variant": loading ? 'net-mask' : '',
            "aria-hidden": loading || undefined
          },
          "s4": dateText(r.dueAt),
          "s5": r.done ? 'Completed' : r.dueAt <= Date.now() ? 'Overdue' : 'Upcoming',
          "s6": {},
          "s7": !r.done && render("network_62", {
            "s0": {
              "disabled": loading,
              "onClick": () => update(s => {
                s.reminders.find(x => x.id === r.id).done = true;
              })
            }
          }),
          "s8": {
            "disabled": loading,
            "aria-label": 'Reschedule ' + r.title,
            "onClick": () => update(s => {
              s.reminderForms[person.id] = {
                id: r.id,
                title: r.title,
                due: localDateTime(r.dueAt)
              };
            })
          },
          "s9": {
            "component": Pencil,
            "size": 16
          },
          "s10": {
            "disabled": loading,
            "aria-label": 'Delete ' + r.title,
            "onClick": () => {
              update(s => {
                s.reminders = s.reminders.filter(x => x.id !== r.id);
                if (s.reminderForms[person.id]?.id === r.id) delete s.reminderForms[person.id];
              });
              setNotice('Reminder deleted.');
            }
          },
          "s11": {
            "component": Trash2,
            "size": 16
          }
        })),
        "s7": !loading && !reminders.length && render("network_63", {
          "s0": {
            "component": Empty,
            "title": "No reminders yet"
          }
        }),
        "s8": {}
      }),
      "s16": page === 'linkedin' && render("network_64", {
        "s0": {},
        "s1": {
          "component": Announcement,
          "loading": loading,
          "label": "Loading saved profile details"
        },
        "s2": {
          "component": Field,
          "label": "LinkedIn profile URL",
          "placeholder": "https://www.linkedin.com/in/your-name/",
          "value": data.linkedin.form.url,
          "loading": loading,
          "onChange": e => update(s => {
            s.linkedin.form.url = e.target.value;
          })
        },
        "s3": {
          "component": Field,
          "label": "Target role (optional)",
          "placeholder": "e.g. Frontend engineer",
          "value": data.linkedin.form.role,
          "loading": loading,
          "onChange": e => update(s => {
            s.linkedin.form.role = e.target.value;
          })
        },
        "s4": {
          "disabled": loading,
          "onClick": () => attempt(async () => {
            const url = validateLinkedIn(data.linkedin.form.url);
            if (real) {
              await saveLinkedInTarget(url, data.linkedin.form.role.trim());
              setNotice('LinkedIn details saved to your account.');
              return;
            }
            update(s => {
              s.linkedin.saved = {
                url,
                role: s.linkedin.form.role.trim()
              };
              s.linkedin.form = {
                ...s.linkedin.saved
              };
            });
            setNotice('Profile details saved in this preview.');
          })
        },
        "s5": scenario === 'setup' && setup(),
        "s6": {
          "disabled": loading || scenario === 'setup',
          "onClick": async () => {
            const id = await attempt(async () => {
              if (!real) return startLinkedIn();
              const url = validateLinkedIn(data.linkedin.form.url);
              const gate = linkedinAvailability();
              if (!gate.ready) throw new Error(gate.message || 'LinkedIn review is not set up for your account yet.');
              return (await startLinkedInRun(url, data.linkedin.form.role.trim())).id;
            });
            if (id) go('linkedinTask', {
              runId: id
            });
          }
        },
        "s7": {},
        "s8": {
          "component": Fold,
          "title": "Review history",
          "initial": data.linkedin.runs.length > 0
        },
        "s9": data.linkedin.runs.map(r => render("network_65", {
          "s0": {
            "component": Entry,
            "key": r.id,
            "title": r.role || 'LinkedIn profile',
            "hint": `${labels[r.status]} · ${dateText(r.createdAt)}`,
            "loading": loading,
            "onClick": () => go('linkedinTask', {
              runId: r.id
            })
          }
        })),
        "s10": !loading && !data.linkedin.runs.length && render("network_66", {
          "s0": {}
        })
      }),
      "s17": page === 'linkedinTask' && run && render("network_67", {
        "s0": {},
        "s1": run.url,
        "s2": {},
        "s3": run.role || 'General profile review',
        "s4": {
          "role": "status"
        },
        "s5": labels[run.status],
        "s6": run.status === 'signin' && scenario === 'browser-error' && render("network_68", {
          "s0": {
            "role": "alert"
          },
          "s1": {},
          "s2": {
            "onClick": () => setScenario('normal')
          }
        }),
        "s7": !real && run.status === 'signin' && scenario !== 'browser-error' && render("network_69", {
          "s0": {},
          "s1": {},
          "s2": {},
          "s3": {},
          "s4": {},
          "s5": {
            "type": "checkbox",
            "checked": !!run.confirmed,
            "onChange": e => updateRun(r => {
              r.confirmed = e.target.checked;
            })
          },
          "s6": {
            "disabled": !run.confirmed || loading,
            "onClick": () => analyzeLinkedIn(run.id, scenario === 'scan-error')
          }
        }),
        "s8": run.status === 'expired' && render("network_70", {
          "s0": {},
          "s1": {},
          "s2": {
            "onClick": () => updateRun(r => {
              r.status = 'signin';
              r.confirmed = false;
            })
          }
        }),
        "s9": run.status === 'blocked' && render("network_71", {
          "s0": {},
          "s1": {},
          "s2": {
            "onClick": () => {
              setScenario('normal');
              analyzeLinkedIn(run.id, false);
            }
          }
        }),
        "s10": ['scanning', 'complete'].includes(run.status) && render("network_72", {
          "s0": {
            "component": LinkedInReport,
            "run": run,
            "loading": loading || run.status === 'scanning',
            "edit": updateRun,
            "copy": copy
          }
        }),
        "s11": !['complete', 'cancelled'].includes(run.status) && render("network_73", {
          "s0": {
            "onClick": () => updateRun(r => {
              r.status = 'cancelled';
            })
          }
        }),
        "s12": run.status === 'cancelled' && render("network_74", {
          "s0": {}
        })
      })
    }),
    "s9": {
      "aria-label": "Main navigation"
    },
    "s10": tabs.map(([name, Icon]) => render("network_75", {
      "s0": {
        "key": name,
        "aria-current": name === 'Network' ? 'page' : undefined,
        "onClick": () => {
          if (name === 'Network') home();else {
            importToken.current++;
            onNavigate(name);
          }
        }
      },
      "s1": {
        "component": Icon,
        "size": 22
      },
      "s2": {},
      "s3": name,
      "s4": name === 'Network' && render("network_76", {
        "s0": {}
      })
    }))
  });
}
function LinkedInReport({
  run,
  loading,
  edit,
  copy
}) {
  const evidence = {
    headline: 'Computer science student. Building accessible web interfaces with React.',
    about: 'In the campus web club, I contribute to a student events site.',
    experience: 'Contributed React components to the student events site.'
  };
  return render("network_77", {
    "s0": {
      "component": Announcement,
      "loading": loading,
      "label": "Analyzing captured profile"
    },
    "s1": {},
    "s2": dateText(run.capturedAt || run.createdAt),
    "strengths": run.report ? run.report.strengths.join(' ') || 'No strengths were listed.' : 'Your sample profile names a clear technical skill and a concrete project.',
    "questions": run.report ? run.report.questions.join(' ') || 'No questions to answer.' : 'Which components did you own? What outcome can you verify?',
    "findings": (run.report ? run.report.findings : [{
      label: 'High priority · Headline',
      quote: evidence.headline,
      advice: 'Bring your technical focus into the headline so recruiters can understand your direction at a glance.'
    }, {
      label: 'Medium priority · Experience',
      quote: evidence.experience,
      advice: 'Describe your contribution clearly. Add outcomes only after you can verify them.'
    }]).map((f, i) => render("network_finding", {
      "s0": {
        "key": i
      },
      "s1": {
        "variant": loading ? 'net-mask' : '',
        "aria-hidden": loading || undefined
      },
      "s2": f.label,
      "s3": {
        "variant": loading ? 'net-mask' : '',
        "aria-hidden": loading || undefined
      },
      "s4": f.quote,
      "s5": {
        "variant": loading ? 'net-mask' : '',
        "aria-hidden": loading || undefined
      },
      "s6": f.advice
    })),
    "s3": {
      "component": Fold,
      "title": "Strengths"
    },
    "s4": {
      "variant": loading ? 'net-mask net-muted' : 'net-muted',
      "aria-hidden": loading || undefined
    },
    "s5": {
      "component": Fold,
      "title": "Prioritized findings",
      "initial": true
    },
    "s6": {},
    "s7": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s8": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s9": evidence.headline,
    "s10": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s11": {},
    "s12": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s13": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s14": evidence.experience,
    "s15": {
      "variant": loading ? 'net-mask' : '',
      "aria-hidden": loading || undefined
    },
    "s16": {
      "component": Fold,
      "title": "Suggested rewrites",
      "initial": true
    },
    "s17": Object.entries(run.rewrites).map(([key, value]) => render("network_78", {
      "s0": {
        "key": key
      },
      "s1": {
        "component": Editable,
        "label": key[0].toUpperCase() + key.slice(1),
        "multiline": true,
        "value": value,
        "loading": loading,
        "onChange": e => edit(r => {
          r.rewrites[key] = e.target.value;
          r.approved = false;
        })
      },
      "s2": {},
      "s3": {},
      "s4": {
        "variant": loading ? 'net-mask' : '',
        "aria-hidden": loading || undefined
      },
      "s5": run.report ? run.report.evidence[key] || '' : evidence[key],
      "s6": {},
      "s7": {
        "type": "checkbox",
        "disabled": loading,
        "checked": run.included[key],
        "onChange": e => edit(r => {
          r.included[key] = e.target.checked;
          r.approved = false;
        })
      }
    })),
    "s18": {
      "component": Fold,
      "title": "Questions & limitations"
    },
    "s19": {
      "variant": loading ? 'net-mask net-muted' : 'net-muted',
      "aria-hidden": loading || undefined
    },
    "s20": {},
    "s21": {
      "disabled": loading || run.approved || !Object.entries(run.included).some(([k, yes]) => yes && run.rewrites[k].trim()) || Object.entries(run.included).some(([k, yes]) => yes && !run.rewrites[k].trim()),
      "onClick": () => edit(r => {
        r.approved = true;
      })
    },
    "s22": run.approved ? 'Rewrites approved' : 'Approve selected rewrites',
    "s23": run.approved && render("network_79", {
      "s0": {
        "role": "status"
      },
      "s1": {
        "disabled": loading,
        "onClick": () => copy(Object.entries(run.rewrites).filter(([k]) => run.included[k]).map(([k, text]) => `${k.toUpperCase()}\n${text}`).join('\n\n'))
      }
    })
  });
}
