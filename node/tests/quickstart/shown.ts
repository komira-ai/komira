// The docs show the quickstart: the check that a Markdown document holds a
// file's text as one of its fenced blocks, the expected output with its
// placeholders put in, and the ABI version the output prints.
//
// A document holds a file as a ```<fence> block when it has a line that is
// exactly "```<fence>", then lines whose concatenation (each with its line
// feed) is the file's text byte for byte, then a line that is exactly "```".
// A document with CRLF line ends, a trailing space or another line in the
// block does not hold it. This is the rule python/smoke/src/readme.zig holds
// the Python docs to, with the same refusal.

/** A document and the file one of its blocks must be. */
export interface Shown {
  /** The document's path, as the refusal names it. */
  readonly doc: string;
  /** The fence's info word: "js" for "```js". */
  readonly fence: string;
  /** The path of the file the block must equal. */
  readonly source: string;
}

/** One fenced block of a document: its lines, and whether a "```" line closes it. */
export interface Block {
  readonly lines: readonly string[];
  readonly closed: boolean;
}

/** The ```<fence> blocks of `docText`, in order. A block that is never closed runs to the document's end. */
export function fencedBlocks(docText: string, fence: string): Block[] {
  const open = "```" + fence;
  // A document that ends with a line feed has no empty last line.
  const all = (docText.endsWith("\n") ? docText.slice(0, -1) : docText).split("\n");
  const blocks: Block[] = [];
  let i = 0;
  while (i < all.length) {
    if (all[i] !== open) {
      i += 1;
      continue;
    }
    let j = i + 1;
    while (j < all.length && all[j] !== "```") j += 1;
    blocks.push({ lines: all.slice(i + 1, j), closed: j < all.length });
    i = j + 1;
  }
  return blocks;
}

/**
 * null when `docText` holds `wantText` as a ```<fence> block; else the
 * refusal, naming the first line where the block that agrees with
 * `wantText` for the most lines differs from it.
 */
export function docShowsBlock(shown: Shown, docText: string, wantText: string): string | null {
  const head = `${shown.doc} shows no \`\`\`${shown.fence} block equal to ${shown.source}: `;
  if (!wantText.endsWith("\n")) return `${head}${shown.source} does not end with a line feed`;
  const want = wantText.slice(0, -1).split("\n");
  let best: { agree: number; have: string; want: string } | null = null;
  for (const block of fencedBlocks(docText, shown.fence)) {
    let k = 0;
    while (k < block.lines.length && k < want.length && block.lines[k] === want[k]) k += 1;
    if (block.closed && block.lines.length === want.length && k === want.length) return null;
    if (best === null || k > best.agree) {
      const ends = block.closed ? "(the block ends)" : `(${shown.doc} ends)`;
      best = { agree: k, have: block.lines[k] ?? ends, want: want[k] ?? `(${shown.source} ends)` };
    }
  }
  if (best === null) return `${head}${shown.doc} has no line that is exactly \`\`\`${shown.fence}`;
  return `${head}line ${best.agree + 1} of the closest block reads '${best.have}', ${shown.source}'s reads '${best.want}'`;
}

/** `text` with every `<key>` of `values` replaced by its value, taken literally; other placeholders are left as written. */
export function fill(text: string, values: Readonly<Record<string, string>>): string {
  let out = text;
  for (const [key, value] of Object.entries(values)) out = out.replaceAll(`<${key}>`, () => value);
  return out;
}

/**
 * The C ABI version the ABI table `tableText` (the file at `path`) states,
 * as `abiVersion()` returns it: `major * 1000 + minor`. Its first line must be
 * exactly `version<TAB><major>.<minor>`.
 */
export function abiVersionOf(path: string, tableText: string): number {
  const first = tableText.split("\n")[0] as string;
  const match = /^version\t(\d{1,4})\.(\d{1,3})$/.exec(first);
  if (match === null) throw new Error(`the first line of ${path} is '${first}', not \`version<TAB><major>.<minor>\``);
  return Number(match[1]) * 1000 + Number(match[2]);
}
