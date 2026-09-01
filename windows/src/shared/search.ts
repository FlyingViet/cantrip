export interface SearchCandidate {
  name: string;
  isRunning?: boolean;
}

export interface SearchScore {
  tier: number;
  gaps: number;
  start: number;
  nameLength: number;
}

function normalize(value: string): string {
  return value
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .toLocaleLowerCase();
}

export function searchableQuery(rawQuery: string): string {
  return normalize(rawQuery)
    .trim()
    .replace(/^(?:open|launch)\s+/, "");
}

function wordStarts(name: string): number[] {
  const starts: number[] = [];
  for (let index = 0; index < name.length; index += 1) {
    if (/[a-z0-9]/i.test(name[index]) && (index === 0 || !/[a-z0-9]/i.test(name[index - 1]))) {
      starts.push(index);
    }
  }
  return starts;
}

export function scoreApp(rawQuery: string, rawName: string): SearchScore | null {
  const query = searchableQuery(rawQuery);
  const name = normalize(rawName);
  if (query.length < 2 || name.length === 0) return null;

  if (name === query) return { tier: 0, gaps: 0, start: 0, nameLength: name.length };

  const starts = wordStarts(name);
  const words = starts.map((start) => ({
    start,
    value: name.slice(start).match(/^[a-z0-9]+/i)?.[0] ?? "",
  }));
  const initials = words.map((word) => word.value[0]).join("");
  if (initials === query) {
    return { tier: 1, gaps: 0, start: 0, nameLength: name.length };
  }
  const exactWord = words.find((word) => word.value === query);
  if (exactWord) return { tier: 1, gaps: 0, start: exactWord.start, nameLength: name.length };

  if (name.startsWith(query)) return { tier: 2, gaps: 0, start: 0, nameLength: name.length };

  const prefixWord = words.find((word) => word.value.startsWith(query));
  if (prefixWord) return { tier: 3, gaps: 0, start: prefixWord.start, nameLength: name.length };

  const substringIndex = name.indexOf(query);
  if (substringIndex >= 0) {
    return { tier: 4, gaps: 0, start: substringIndex, nameLength: name.length };
  }

  if (query.length < 3) return null;
  const positions: number[] = [];
  let cursor = 0;
  for (const character of query) {
    cursor = name.indexOf(character, cursor);
    if (cursor < 0) return null;
    positions.push(cursor);
    cursor += 1;
  }

  const first = positions[0];
  const last = positions[positions.length - 1];
  const span = last - first + 1;
  if (span > Math.max(query.length * 2, query.length + 3)) return null;

  return {
    tier: 5,
    gaps: span - query.length,
    start: first,
    nameLength: name.length,
  };
}

function compareScores(
  left: { candidate: SearchCandidate; score: SearchScore },
  right: { candidate: SearchCandidate; score: SearchScore },
): number {
  if (left.score.tier !== right.score.tier) return left.score.tier - right.score.tier;
  if (Boolean(left.candidate.isRunning) !== Boolean(right.candidate.isRunning)) {
    return left.candidate.isRunning ? -1 : 1;
  }
  if (left.score.gaps !== right.score.gaps) return left.score.gaps - right.score.gaps;
  if (left.score.start !== right.score.start) return left.score.start - right.score.start;
  if (left.score.nameLength !== right.score.nameLength) {
    return left.score.nameLength - right.score.nameLength;
  }
  return left.candidate.name.localeCompare(right.candidate.name, undefined, {
    sensitivity: "base",
  });
}

export function rankApps<T extends SearchCandidate>(query: string, candidates: T[]): T[] {
  return candidates
    .map((candidate) => ({ candidate, score: scoreApp(query, candidate.name) }))
    .filter(
      (entry): entry is { candidate: T; score: SearchScore } => entry.score !== null,
    )
    .sort(compareScores)
    .map(({ candidate }) => candidate);
}
