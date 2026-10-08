import {useScenario} from './scenarios';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState } from 'react';
import { ArrowLeft, ChevronRight, ChevronDown, Pencil, X, Check } from 'lucide-react-native';
import { subscribePreviewLoading, networkLoadingSnapshot } from './loading';
const platforms = [{
  id: 'linkedin',
  name: 'LinkedIn',
  mark: 'in',
  hint: 'Your professional story',
  sections: [{
    id: 'intro',
    name: 'Introduction',
    fields: [['url', 'Profile URL', 'https://linkedin.com/in/you'], ['headline', 'Headline', 'Your role and what you bring'], ['location', 'Location', 'City, region']]
  }, {
    id: 'about',
    name: 'About you',
    fields: [['about', 'About', 'Introduce yourself, your strengths, and your direction'], ['skills', 'Top skills', 'Your strongest skills']]
  }, {
    id: 'experience',
    name: 'Experience',
    fields: [['role', 'Current or recent role', 'Role and organization'], ['experience', 'Experience highlights', 'Responsibilities, contributions, and measurable outcomes']]
  }, {
    id: 'education',
    name: 'Education',
    fields: [['school', 'School', 'University or institution'], ['degree', 'Degree & field of study', 'Degree, major, and graduation year'], ['activities', 'Activities & achievements', 'Clubs, awards, or research']]
  }, {
    id: 'featured',
    name: 'Featured work',
    fields: [['featured', 'Projects & links', 'Work you want people to see'], ['credentials', 'Certifications', 'Relevant certifications or credentials']]
  }]
}, {
  id: 'github',
  name: 'GitHub',
  mark: '<>',
  hint: 'Your code and contributions',
  sections: [{
    id: 'intro',
    name: 'Profile basics',
    fields: [['url', 'Profile URL', 'https://github.com/you'], ['bio', 'Bio', 'What you build and work with'], ['website', 'Website', 'Your portfolio or personal website']]
  }, {
    id: 'readme',
    name: 'Profile README',
    fields: [['readme', 'Introduction', 'A short introduction to your work'], ['stack', 'Tools & technologies', 'Your languages, frameworks, and tools'], ['focus', 'Current focus', 'What you are building or learning']]
  }, {
    id: 'projects',
    name: 'Showcase',
    fields: [['projects', 'Pinned repositories', 'Your strongest repositories'], ['demos', 'Live demos', 'Links to working projects'], ['contributions', 'Contributions', 'Open-source work you want to highlight']]
  }]
}, {
  id: 'portfolio',
  name: 'Portfolio',
  mark: '↗',
  hint: 'Your work, in your own space',
  sections: [{
    id: 'intro',
    name: 'Introduction',
    fields: [['url', 'Website URL', 'https://yourname.com'], ['intro', 'Headline', 'What you do and who you do it for'], ['about', 'About', 'Your background and approach']]
  }, {
    id: 'work',
    name: 'Selected work',
    fields: [['work', 'Featured projects', 'Your strongest projects or case studies'], ['role', 'Your contribution', 'What you owned and how you worked'], ['outcomes', 'Outcomes', 'Impact, results, and what you learned']]
  }, {
    id: 'contact',
    name: 'Get in touch',
    fields: [['email', 'Contact email', 'you@example.com'], ['links', 'Social links', 'Relevant public profiles'], ['resume', 'Resume link', 'A link to your current resume']]
  }]
}];
let profileFields = {};
export function PublicProfiles({
  onClose
}) {
  const loading = React.useSyncExternalStore(subscribePreviewLoading, networkLoadingSnapshot);
  const [values, setValues] = useState(profileFields),
    [expanded, setExpanded] = useState({}),
    [platform, setPlatform] = useState(null),
    [editing, setEditing] = useState(null),
    [draft, setDraft] = useState('');
  useScenario('Network/public-profiles-controller', s=>{if(s.platform)enter(platforms.find(p=>p.id===s.platform));});
  function enter(p) {
    setPlatform(p);
    setExpanded(Object.fromEntries(p.sections.map((section, i) => [section.id, i === 0])));
  }
  function save() {
    const next = {
      ...values,
      [editing.key]: draft.trim()
    };
    profileFields = next;
    setValues(next);
    setEditing(null);
  }
  return render("public_profiles_1", {
    "s0": {
      "key": platform?.id || 'overview',
      "aria-busy": loading && !!platform
    },
    "s1": {},
    "s2": {
      "aria-label": platform ? 'Back to public profiles' : 'Back to network',
      "onClick": () => platform ? setPlatform(null) : onClose()
    },
    "s3": {
      "component": ArrowLeft,
      "size": 20
    },
    "s4": {},
    "s5": platform ? platform.name : 'Public profiles',
    "s6": loading && platform && render("public_profiles_2", {
      "s0": {
        "role": "status"
      }
    }),
    "s7": !platform ? render("public_profiles_3", {
      "s0": {},
      "s1": platforms.map(p => render("public_profiles_4", {
        "s0": {
          "key": p.id,
          "onClick": () => enter(p)
        },
        "s1": {
          "variant": 'profile-channel-mark ' + p.id
        },
        "s2": p.mark,
        "s3": {},
        "s4": {},
        "s5": p.name,
        "s6": {},
        "s7": p.hint,
        "s8": {
          "component": ChevronRight,
          "size": 17
        }
      }))
    }) : platform.sections.map(section => render("public_profiles_5", {
      "s0": {
        "key": section.id
      },
      "s1": {
        "aria-expanded": expanded[section.id],
        "aria-controls": 'fields-' + section.id,
        "onClick": () => setExpanded({
          ...expanded,
          [section.id]: !expanded[section.id]
        })
      },
      "s2": {},
      "s3": section.name,
      "s4": {
        "component": ChevronDown,
        "size": 16
      },
      "s5": expanded[section.id] && render("public_profiles_6", {
        "s0": {
          "id": 'fields-' + section.id
        },
        "s1": section.fields.map(([id, label, placeholder]) => {
          const key = platform.id + '.' + id;
          return render("public_profiles_7", {
            "s0": {
              "key": key
            },
            "s1": {
              "disabled": loading,
              "aria-label": 'Edit ' + platform.name + ' ' + label,
              "onClick": () => {
                setEditing({
                  key,
                  label,
                  platform: platform.name,
                  placeholder
                });
                setDraft(values[key] || '');
              }
            },
            "s2": {},
            "s3": label,
            "s4": {
              "variant": loading ? "skeleton-value" : "",
              "aria-hidden": loading
            },
            "s5": values[key] || 'Not added yet',
            "s6": {
              "disabled": loading,
              "aria-label": 'Edit ' + platform.name + ' ' + label + ' field',
              "onClick": () => {
                setEditing({
                  key,
                  label,
                  platform: platform.name,
                  placeholder
                });
                setDraft(values[key] || '');
              }
            },
            "s7": {
              "component": Pencil,
              "size": 17
            }
          });
        })
      })
    })),
    "s8": editing && render("public_profiles_8", {
      "s0": {
        "onClick": () => setEditing(null)
      },
      "s1": {
        "role": "dialog",
        "aria-modal": "true",
        "aria-label": 'Edit ' + editing.platform + ' ' + editing.label,
        "onClick": e => e.stopPropagation()
      },
      "s2": {},
      "s3": {
        "aria-label": "Close editor",
        "onClick": () => setEditing(null)
      },
      "s4": {
        "component": X,
        "size": 21
      },
      "s5": {},
      "s6": editing.platform,
      "s7": {},
      "s8": editing.label,
      "s9": {},
      "s10": editing.label,
      "s11": {
        "autoFocus": true,
        "aria-label": editing.label,
        "placeholder": editing.placeholder,
        "value": draft,
        "onChange": e => setDraft(e.target.value)
      },
      "s12": {
        "onClick": save
      },
      "s13": {
        "component": Check,
        "size": 17
      },
      "s14": {}
    })
  });
}
