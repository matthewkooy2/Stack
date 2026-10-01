// Stack adaptation, 2026-09-29: retain only the parser's default; no Redux runtime.
// Original: xitanggg/open-resume, AGPL-3.0. See ../../NOTICE.md.
import type { FeaturedSkill } from './types';
export const initialFeaturedSkills: FeaturedSkill[] = Array(6).fill({ skill: '', rating: 4 });
