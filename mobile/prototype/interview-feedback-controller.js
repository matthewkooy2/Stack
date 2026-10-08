import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState } from 'react';
import { ArrowLeft, ChevronDown, Check, RotateCcw } from 'lucide-react-native';
import { subscribePreviewLoading, prepLoadingSnapshot } from './loading';
const reviews = {
  project: {
    score: 78,
    metrics: [['Structure', 85], ['Specificity', 72], ['Reflection', 77]],
    strength: 'Your ownership is clear.',
    evidence: '“I owned the signup experience.”',
    explanation: 'You distinguish your contribution from the team’s work.',
    improvement: 'Give the result more weight.',
    coach: 'You explain what shipped, but not what changed. Add what you observed in testing or how the new flow helped students. Use a real result; a number is optional.',
    retry: 'End with one concrete outcome, then your lesson.'
  },
  disagreement: {
    score: 81,
    metrics: [['Structure', 85], ['Specificity', 75], ['Reflection', 83]],
    strength: 'You show a constructive response.',
    evidence: '“Compare both ideas against our deadline and user feedback.”',
    explanation: 'You explain how you moved the discussion toward a shared decision.',
    improvement: 'Make the disagreement concrete.',
    coach: 'Briefly name the two competing ideas and what mattered to your teammate. That makes your listening and reasoning easier to follow.',
    retry: 'Name both perspectives before explaining your action.'
  },
  setback: {
    score: 80,
    metrics: [['Structure', 84], ['Specificity', 73], ['Reflection', 83]],
    strength: 'You take responsibility.',
    evidence: '“I underestimated the testing needed.”',
    explanation: 'You own the mistake and describe how you responded.',
    improvement: 'Show how the lesson stuck.',
    coach: 'Give one example of how scheduling tests earlier changed a later project. That turns a stated lesson into evidence of growth.',
    retry: 'Close with what you did differently the next time.'
  }
};
export function InterviewFeedback({
  question,
  transcript,
  onRetry,
  onDone,
  pending = false,
  live = null,
  stage = ''
}) {
  const held = React.useSyncExternalStore(subscribePreviewLoading, prepLoadingSnapshot);
  const loading = pending || held;
  const [breakdown, setBreakdown] = useState(false),
    [showTranscript, setShowTranscript] = useState(false);
  // Live: the coach's rubric, or (when coaching is not set up) your saved answer with the bundled self-check.
  const review = live ? live.review || {
    score: '—',
    metrics: [],
    strength: 'Your answer is saved.',
    evidence: transcript ? '“' + transcript.split(/\s+/).slice(0, 18).join(' ') + (transcript.split(/\s+/).length > 18 ? '…' : '') + '”' : '',
    explanation: live.message,
    improvement: 'Check it yourself',
    coach: question.guide || '',
    retry: question.check || ''
  } : reviews[question.id] || reviews.project;
  return render("interview_feedback_1", {
    "s0": {
      "variant": "feedback-page" + (loading ? " feedback-skeleton" : ""),
      "aria-busy": loading
    },
    "s1": {},
    "s2": {
      "aria-label": "Back to behavioral questions",
      "onClick": onDone
    },
    "s3": {
      "component": ArrowLeft,
      "size": 21
    },
    "s4": {},
    "s5": {
      "style": {
        width: 38
      }
    },
    "s6": {},
    "s7": loading && render("interview_feedback_2", {
      "s0": {
        "role": "status"
      }
    }),
    "s8": {},
    "s9": question.title,
    "s10": {
      "aria-hidden": loading
    },
    "s11": {},
    "s12": review.score,
    "s13": {},
    "s14": {},
    "s15": {},
    "s16": loading ? stage || "Reviewing your answer…" : live ? live.review ? "Coached from your recorded answer" : "Coaching unavailable · Your answer is saved" : "Sample score · Based on the demo transcript",
    "s17": {
      "aria-expanded": breakdown,
      "onClick": () => setBreakdown(!breakdown)
    },
    "s18": {
      "component": ChevronDown,
      "size": 16
    },
    "s19": breakdown && render("interview_feedback_3", {
      "s0": {
        "aria-hidden": loading
      },
      "s1": review.metrics.map(([label, score]) => render("interview_feedback_4", {
        "s0": {
          "key": label
        },
        "s1": {},
        "s2": label,
        "s3": {},
        "s4": {
          "style": {
            width: score + '%'
          }
        },
        "s5": {},
        "s6": score
      }))
    }),
    "s20": {},
    "s21": {},
    "s22": {
      "aria-hidden": loading
    },
    "s23": review.strength,
    "s24": {
      "aria-hidden": loading
    },
    "s25": review.evidence,
    "s26": {
      "aria-hidden": loading
    },
    "s27": review.explanation,
    "s28": {},
    "s29": {},
    "s30": {
      "aria-hidden": loading
    },
    "s31": review.improvement,
    "s32": {
      "aria-hidden": loading
    },
    "s33": review.coach,
    "s34": {},
    "s35": {
      "component": RotateCcw,
      "size": 16
    },
    "s36": {
      "aria-hidden": loading
    },
    "s37": review.retry,
    "s38": {
      "aria-expanded": showTranscript,
      "onClick": () => setShowTranscript(!showTranscript)
    },
    "s39": {
      "component": ChevronDown,
      "size": 16
    },
    "s40": showTranscript && render("interview_feedback_5", {
      "s0": {},
      "s1": {},
      "s2": {},
      "s3": transcript
    }),
    "s41": {},
    "s42": {
      "disabled": loading,
      "onClick": onRetry
    },
    "s43": {
      "component": RotateCcw,
      "size": 16
    },
    "s44": {
      "onClick": onDone
    },
    "s45": {
      "component": Check,
      "size": 17
    }
  });
}
