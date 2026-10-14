import {useScenario} from './scenarios';
import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useState, useEffect } from 'react';
import { InterviewFeedback } from './interview-feedback-controller';
import { backend, describeError } from './backend';
import { liveState } from './live-store';
import { useRecording, recordingContent, deleteLocalRecording } from '../audio-recording.js';
import { pcTranscript, coachAnswer } from './interview-live';
import { ArrowLeft, SlidersHorizontal, X, Mic, Video, VideoOff, AlignLeft, Volume2, RotateCcw, Square, Play, Check, UserRound } from 'lucide-react-native';
const samples = {
  project: 'In my final year, our team built a campus events app. I owned the signup experience. After talking with students, I simplified the form and tested it with five classmates. We shipped the revised flow, and I learned to validate assumptions before committing to a design.',
  disagreement: 'On a group project, we disagreed about which feature to build first. I suggested we compare both ideas against our deadline and user feedback. We agreed on a smaller version, delivered on time, and learned to make tradeoffs together.',
  setback: 'I underestimated the testing needed for a class project. When we found a bug before the demo, I told the team and helped narrow the scope. We fixed the critical flow, and I started scheduling testing earlier on later projects.'
};
export function MockInterview({
  question,
  onFinish,
  onExit,
  applicationId = ''
}) {
  // Build-time constant: live builds record your real answer and coach it; mock builds replay the sample answer.
  const real = backend.live;
  const owner = real ? liveState().boot?.user_id || '' : '';
  const capture = real ? useRecording(owner) : null;
  const [error, setError] = useState(''),
    [stage, setStage] = useState(''),
    [liveResult, setLiveResult] = useState(null),
    [spoken, setSpoken] = useState('');
  const [phase, setPhase] = useState('ready'),
    [camera, setCamera] = useState(false),
    [transcript, setTranscript] = useState(false),
    [seconds, setSeconds] = useState(0),
    [playing, setPlaying] = useState(true),
    [settings, setSettings] = useState(false),
    [repeat, setRepeat] = useState(0),
    [reviewText, setReviewText] = useState(false);
  useScenario('Prep/mock-interview-controller', s=>{setPhase(s.phase||'ready');setSettings(!!s.settings);});
  const sample = real ? spoken : samples[question.id] || samples.project;
  useEffect(() => {
    if (phase !== 'recording') return;
    const id = setInterval(() => setSeconds(s => s + 1), 1000);
    return () => clearInterval(id);
  }, [phase]);
  useEffect(() => {
    if (!playing) return;
    const id = setTimeout(() => setPlaying(false), 6000);
    return () => clearTimeout(id);
  }, [playing, repeat]);
  useEffect(() => {
    if (real || phase !== 'evaluating') return;
    const id = setTimeout(() => setPhase('feedback'), 1400);
    return () => clearTimeout(id);
  }, [phase]);
  const time = String(Math.floor(seconds / 60)).padStart(2, '0') + ':' + String(seconds % 60).padStart(2, '0');
  async function startLive() {
    setError('');
    setPlaying(false);
    try {
      await capture.start();
      setSeconds(0);
      setPhase('recording');
    } catch (e) {
      setError(describeError(e));
    }
  }
  // Stop, get the transcript (on the phone, else the PC worker), save it, and coach it.
  async function finishLive() {
    setPhase('evaluating');
    setError('');
    try {
      const row = await capture.stop();
      if (!row) throw new Error('No recording was saved. Record your answer again.');
      let text = (row.transcript || '').trim();
      if (!text) text = (await pcTranscript(row.client_id, (await recordingContent(row)).content, setStage)).trim();
      if (!text) throw new Error('No speech was heard. Record your answer again.');
      setSpoken(text);
      const result = await coachAnswer({
        questionId: question.id,
        applicationId,
        transcript: text,
        seconds: Math.max(1, Math.round((row.duration_ms || seconds * 1000) / 1000))
      }, setStage);
      setLiveResult(result);
      setPhase('feedback');
    } catch (e) {
      setError(describeError(e));
      setPhase('ready');
    }
  }
  function start() {
    if (real) {
      startLive();
      return;
    }
    setPlaying(false);
    setSeconds(0);
    setPhase('recording');
  }
  function retry() {
    setLiveResult(null);
    setSpoken('');
    setPhase('ready');
    setSeconds(0);
    setReviewText(false);
  }
  if (phase === 'feedback') return render("mock_interview_1", {
    "s0": {
      "component": InterviewFeedback,
      "question": question,
      "transcript": sample,
      "live": real ? liveResult : null,
      "onRetry": retry,
      "onDone": onFinish
    }
  });
  if (phase === 'evaluating') return render("mock_interview_2", {
    "s0": {
      "component": InterviewFeedback,
      "question": question,
      "transcript": sample,
      "pending": true,
      "stage": stage,
      "onRetry": retry,
      "onDone": onExit
    }
  });
  return render("mock_interview_3", {
    "s0": {},
    "s1": {},
    "s2": {
      "aria-label": "Exit interview",
      "onClick": onExit
    },
    "s3": {
      "component": ArrowLeft,
      "size": 21
    },
    "s4": {},
    "s5": phase === 'recording' ? time : phase === 'review' ? 'Review' : 'Interview',
    "s6": {
      "aria-label": "Interview settings",
      "aria-expanded": settings,
      "onClick": () => setSettings(true)
    },
    "s7": {
      "component": SlidersHorizontal,
      "size": 21
    },
    "s8": {
      "variant": 'interviewer-stage ' + (playing ? 'is-playing' : '')
    },
    "s9": {},
    "s10": {
      "component": UserRound,
      "size": 55
    },
    "s11": {
      "aria-hidden": "true"
    },
    "s12": [1, 2, 3, 4, 5, 6, 7].map(n => render("mock_interview_4", {
      "s0": {
        "key": n,
        "style": {
          animationDelay: n * .1 + 's'
        }
      }
    })),
    "s13": {},
    "s14": error ? error : phase === 'recording' ? 'Your turn' : phase === 'review' ? 'Answer complete' : playing ? 'Interviewer speaking…' : 'Ready when you are',
    "s15": {},
    "s16": question.prompt,
    "s17": camera && render("mock_interview_5", {
      "s0": {},
      "s1": {
        "component": UserRound,
        "size": 28
      },
      "s2": {}
    }),
    "s18": {},
    "s19": transcript && phase === 'recording' && render("mock_interview_6", {
      "s0": {
        "aria-live": "polite"
      },
      "s1": {},
      "s2": {},
      "s3": real ? capture.liveText || 'Listening…' : sample.split(' ').slice(0, Math.max(1, seconds * 3)).join(' ')
    }),
    "s20": phase === 'ready' ? render("mock_interview_7", {
      "s0": {},
      "s1": {
        "onClick": () => {
          setPlaying(true);
          setRepeat(n => n + 1);
        }
      },
      "s2": {
        "component": RotateCcw,
        "size": 16
      },
      "s3": {
        "onClick": start
      },
      "s4": {
        "component": Mic,
        "size": 17
      }
    }) : phase === 'recording' ? render("mock_interview_8", {
      "s0": {
        "onClick": () => real ? finishLive() : setPhase('evaluating')
      },
      "s1": {
        "component": Square,
        "size": 15,
        "fill": "currentColor"
      },
      "s2": {},
      "s3": time
    }) : render("mock_interview_9", {
      "s0": {},
      "s1": {
        "aria-expanded": reviewText,
        "onClick": () => setReviewText(!reviewText)
      },
      "s2": {
        "component": AlignLeft,
        "size": 17
      },
      "s3": reviewText ? 'Hide transcript' : 'Review transcript',
      "s4": reviewText && render("mock_interview_10", {
        "s0": {},
        "s1": {},
        "s2": {},
        "s3": sample.split(' ').slice(0, Math.max(1, seconds * 3)).join(' ')
      }),
      "s5": {},
      "s6": {
        "onClick": retry
      },
      "s7": {
        "component": RotateCcw,
        "size": 17
      },
      "s8": {
        "onClick": onFinish
      },
      "s9": {
        "component": Check,
        "size": 17
      }
    }),
    "s21": settings && render("mock_interview_11", {
      "s0": {
        "onClick": () => setSettings(false)
      },
      "s1": {
        "role": "dialog",
        "aria-modal": "true",
        "aria-label": "Interview settings",
        "onClick": e => e.stopPropagation()
      },
      "s2": {},
      "s3": {
        "autoFocus": true,
        "aria-label": "Close settings",
        "onClick": () => setSettings(false)
      },
      "s4": {
        "component": X,
        "size": 21
      },
      "s5": {},
      "s6": {
        "omit": real,
        "role": "switch",
        "aria-checked": camera,
        "onClick": () => setCamera(!camera)
      },
      "s7": {},
      "s8": {},
      "s9": {},
      "s10": {
        "variant": camera ? 'on' : ''
      },
      "s11": {
        "role": "switch",
        "aria-checked": transcript,
        "onClick": () => setTranscript(!transcript)
      },
      "s12": {},
      "s13": {},
      "s14": {},
      "s15": {
        "variant": transcript ? 'on' : ''
      },
      "s16": {}
    })
  });
}
