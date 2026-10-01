// OpenResume's extraction stages are unchanged; PDF IO is handled by run.mjs.
import { groupTextItemsIntoLines } from 'lib/parse-resume-from-pdf/group-text-items-into-lines';
import { groupLinesIntoSections } from 'lib/parse-resume-from-pdf/group-lines-into-sections';
import { extractResumeFromSections } from 'lib/parse-resume-from-pdf/extract-resume-from-sections';
import type { TextItems } from 'lib/parse-resume-from-pdf/types';
import { getSectionLinesByKeywords } from 'lib/parse-resume-from-pdf/extract-resume-from-sections/lib/get-section-lines';

export function parse(items: TextItems) {
  const lines = groupTextItemsIntoLines(items);
  const sections = groupLinesIntoSections(lines);
  const resume = extractResumeFromSections(sections);
  const used = new Set([sections.profile, ...[['education'], ['work', 'experience', 'employment', 'history', 'job'], ['project'], ['skill'], ['summary'], ['objective'], ['course']].map(keywords => getSectionLinesByKeywords(sections, keywords))]);
  const additional = Object.entries(sections).filter(([, lines]) => !used.has(lines)).map(([title, lines]) => title + '\n' + lines.map(line => line.map(item => item.text).join(' ')).join('\n')).join('\n\n');
  return { resume: { ...resume, additional: { descriptions: additional } }, text: lines.map(line => line.map(item => item.text).join(' ')).join('\n') };
}
