import { storage, events as serviceEvents, services } from './services';
import { renderTemplate as render } from './render';
import React, { useEffect, useState } from 'react';
import { loadFile } from './application-store';
import { backend } from './backend';
import { originalPdf, tailoredFile } from './resume-live';
export function ApplicationDocument({
  resume,
  task,
  onClose
}) {
  const [url, setUrl] = useState(''),
    [error, setError] = useState('');
  useEffect(() => {
    let live = true,
      objectUrl = '';
    if (backend.live && resume?.blobId) {
      // The account's own PDF (original or tailored), opened directly.
      const [kind, id] = resume.blobId.split(':');
      (kind === 'tailored' ? tailoredFile(id).then(f => f.uri) : originalPdf(id)).then(uri => {
        if (live) setUrl(uri);
      }).catch(() => {
        if (live) setError('Could not open this PDF. Check your connection and try again.');
      });
    } else if (resume?.blobId) loadFile(resume.blobId).then(blob => {
      if (!live) return;
      if (!blob) {
        setError('This file is unavailable on this device. Reattach it from the application.');
        return;
      }
      objectUrl = services.fileUri(blob);
      setUrl(objectUrl);
    }).catch(() => setError('Could not open the PDF. Try reattaching it.'));
    return () => {
      live = false;
      if (objectUrl) services.releaseFile(objectUrl);
    };
  }, [resume?.blobId]);
  return render("application_document_1", {
    "s0": {},
    "s1": {
      "onClick": onClose
    },
    "s2": {},
    "s3": task ? 'Proposed resume' : resume?.name,
    "s4": error ? render("application_document_2", {
      "s0": {
        "role": "alert"
      },
      "s1": error
    }) : url ? render("application_document_3", {
      "s0": {
        "title": "Attached resume PDF",
        "src": url
      }
    }) : resume?.blobId ? render("application_document_4", {
      "s0": {
        "role": "status"
      }
    }) : render("application_document_5", {
      "s0": {},
      "s1": {},
      "s2": (task?.original || resume?.details)?.name || 'Sample candidate',
      "s3": Object.entries(task?.original || resume?.details || {}).filter(([k]) => k !== 'name').map(([k, v]) => render("application_document_6", {
        "s0": {
          "key": k
        },
        "s1": {},
        "s2": k,
        "s3": {},
        "s4": v || 'Not provided'
      }))
    }),
    "s5": task && render("application_document_7", {
      "s0": {},
      "s1": task.changes.map(c => render("application_document_8", {
        "s0": {
          "key": c.id
        },
        "s1": {},
        "s2": c.kept ? 'Proposed wording' : 'Original wording retained',
        "s3": {},
        "s4": c.kept ? c.after : c.before
      }))
    })
  });
}
