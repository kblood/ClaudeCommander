# Claude Commander — cross-platform plan (Windows + Linux + …)

Status: **planning only, deferred.** No code yet. This captures the agreed
direction so a later session can pick it up cold.

## 1. Goal & non-goals

**Goal.** One Claude Commander that runs as a native text-mode app on Windows
**and** Linux (and, with little extra, macOS / *BSD) — usable over SSH and on a
bare console — while reusing as much of the existing DOS work as is sensible.

**Non-goals.**
- Not making the DOS build cross-platform. DOS `cc.com` stays 16-bit asm.
- Not GUI. Everything stays inside the terminal ("shell-specific"): no
  `ShellExecute`/`xdg-open` hand-off to desktop apps.
- **Media (image/audio) is deferred** — out of scope for the first pass.

## 2. The key decision: DOS stays asm; portable C for modern; share the *spec*

The temptation is "one C codebase compiled for DOS (OpenWatcom) + Win + Linux."
We are **not** doing that, because of size on the DOS target:

- `cc.com` today is ~16.5 KB of hand-tuned asm, deliberately fighting the 64 KB
  single-segment wall (see ROADMAP §1, build budgets §4).
- An OpenWatcom C build links a C runtime + startup and emits less dense code —
  realistically **2–4× larger** for equivalent functionality. A sub-1 KB asm
  helper (`ctouch.com` is 791 bytes) becomes 5–15 KB once the CRT is linked.
- Irrelevant on Win/Linux (flat address space); fatal on DOS, where the whole
  modular Layer-1/Layer-3 architecture exists *specifically* to dodge that wall.

**Therefore:**
- **DOS** keeps its asm core + asm helper `.COM`s. Already small, already done.
- **Windows/Linux** get a shared **portable C** core + portable C helper tools.
- The **synergy is a shared specification and a shared test suite**, not a
  shared binary. The asm tool is the reference; the C tool must reproduce its
  behavior byte-for-byte against the same golden outputs.

Two implementations of each tool (asm for DOS, C for modern), **one contract,
one set of golden tests** keeping them in lockstep.

## 3. Architecture

Three layers, mirroring the DOS design (ROADMAP §2) so configs/keybindings/
muscle-memory carry across all targets:

```
  Layer 0  Terminal backend     (platform-specific, tiny)
             win32  : Console API (current wincc code)
             posix  : ANSI escapes + termios raw mode
  Layer 1  cc core              (portable C: panels, layout, nav, file ops,
                                 sort, themes, search, modals, dispatch)
  Layer 3  Helper tools         (portable C standalone exes: cchex, ccfind,
                                 ccgrep, ccsum, ccdiff, …) invoked in-terminal,
                                 discovered via cc.ini [tools] like DOS
```

(There is no "Layer 2 = external because of the segment wall" pressure on
modern OSes; a feature can be built-in or external purely on taste. We keep the
external-helper model anyway, because that *is* the DOS synergy: same tool
names, same args, same keys, same `cc.ini`.)

### 3.1 The one genuinely new piece: the terminal backend seam

wincc today calls Win32 directly. Abstract that behind a small backend so the
panel/layout/logic code above it is unchanged. Proposed interface (`tcell.h`):

```c
typedef unsigned short cell_attr;   /* keep the VGA-style fg|bg<<4 nibble model
                                       so existing palette values 0x17/0x1F/…
                                       carry straight over */
void  tc_init(void);                /* raw mode / alt screen / hide cursor   */
void  tc_shutdown(void);            /* restore everything                    */
void  tc_size(int *cols, int *rows);
void  tc_present(const cell_ch *buf, int cols, int rows);  /* blit a frame   */
int   tc_read_key(key_event *out, int timeout_ms);         /* -1 = resize    */
```

- **win32 backend** = the code already in `wincc/cc.c`
  (`WriteConsoleOutputW`, `ReadConsoleInput`, `GetConsoleScreenBufferInfo`,
  `WINDOW_BUFFER_SIZE_EVENT`).
- **posix backend** = ANSI: alt-screen `\e[?1049h`, truecolor/16-color SGR for
  attrs, `termios` raw mode, `read()` + an escape-sequence decoder for arrows/
  Fn keys, `SIGWINCH`/`ioctl(TIOCGWINSZ)` for resize.
- Filesystem already needs a split too: `FindFirstFileW`/`CopyFileW`/… vs
  `opendir`/`stat`/`rename`/manual copy. Put behind `fsfile.h` (same shape).

Everything else in wincc (Entry/Panel structs, `render_panel`, sort, file ops,
viewer, quick search, cd-on-exit via `CC_CWD_FILE`) is already
platform-neutral C and moves up into Layer 1 untouched.

## 4. Tool inventory & port classification

From the DOS sources (`*.asm` helpers + `mod/*.inc` built-ins). "Logic" ports
1:1 to portable C; "hardware" would need per-platform backends and is deferred.

| DOS tool / module | Kind | Port to C? | Notes |
|---|---|---|---|
| `chex.asm` (CHEX) hex view | logic | yes | could be built-in F3-toggle instead of external |
| `chexed.asm` (CHEXED) hex edit | logic | yes | |
| `cfind.asm` (CFIND) find files | logic | yes | recursive walk + mask |
| `cgrep.asm` (CGREP) grep | logic | yes | + results panel (`mod/results.inc`) |
| `csum.asm` (CSUM) checksum | logic | yes | trivial |
| `cdiff.asm` (CDIFF) diff | logic | yes | |
| `csplit.asm`/`cjoin.asm` | logic | yes | |
| `cren.asm` (CREN) batch rename | logic | yes | |
| `ctouch.asm` (CTOUCH) timestamp | logic | yes | already built (DOS); C port easy |
| `cce.asm`/`ted.asm` editors | logic | yes | or keep launching `$EDITOR` (already in wincc) |
| `czip.asm` + `mod/vfs.inc` zip browse | logic | yes | use a portable zip reader; VFS panel model |
| `carj/crar/cd64/ct64` container browse | logic | maybe | niche formats; later |
| `cimg.asm` (CIMG) image | hardware | **deferred** | would be in-terminal ANSI/sixel, not GUI |
| `cwav.asm` (CWAV) audio | hardware | **deferred** | per-platform audio out |
| `mod/tree.inc` tree view | logic | yes | built-in |
| `mod/attr.inc` attribute editor | logic | yes | chmod/attrib per platform |
| `mod/mouse.inc` | backend | yes | xterm mouse on posix; already have win32 |

## 5. Test-sharing scheme (the real synergy)

The DOS tools already have headless harnesses producing known-good output
(`run_hex.ps1`, `run_find.ps1`, `run_grep.ps1`, `run_sum.ps1`, …, plus cc's own
`/T` dump harness). Plan:

1. Freeze each DOS tool's harness output into a **golden file** under
   `tests/golden/<tool>/`.
2. Give every portable C tool the same CLI contract and a matching headless
   mode, so the C build can be diffed against the *same* goldens
   (cross-platform: run on Linux CI and Windows).
3. cc core reuses the existing `--dir/--keys/--dump/--dumpa` seam (already in
   wincc, validated by `wincc/run_test.ps1`, 38/38) — port the harness to a
   shell script so the same key-scripts/expected-frames run on Linux too.

Net: one behavioral spec, three implementations (DOS asm, Win C, Linux C),
guarded by one golden suite.

## 6. Build & layout (proposed)

```
  cc/                 DOS asm (unchanged)
  port/               NEW: portable C core + tools (replaces wincc/ long-term)
    core/             Layer-1 cc + tcell/fsfile headers
    backend/win32/    Console API backend
    backend/posix/    ANSI + termios backend
    tools/            cchex.c ccfind.c ccgrep.c …
    tests/            shared golden suite + runner (sh + ps1)
    Makefile          posix build (gcc/clang)
    build.ps1         windows build (mingw) — evolve wincc/build.ps1
```

wincc/ becomes the win32 backend + proves the model; its portable parts migrate
up into `port/core/` as Layer 1.

## 7. Milestones (when this resumes)

- **P0** Carve wincc into Layer-1 (portable) + win32 backend behind `tcell.h`/
  `fsfile.h`. No behavior change; `run_test.ps1` still 38/38.
- **P1** Add the posix backend; get cc building & running on Linux (panels,
  nav, file ops, viewer, resize, cd-on-exit). Port the test runner to `sh`.
- **P2** First portable helper: `cchex` (smallest, clear spec) end-to-end with a
  shared golden — establishes the tool contract + test-sharing pattern.
- **P3** `ccfind` + `ccgrep` + results panel.
- **P4** `ccsum`/`ccdiff`/`csplit`/`cjoin`/`cren`/`ctouch`.
- **P5** zip browsing (VFS) with a portable zip reader.
- **Later / deferred** image (in-terminal), audio, exotic containers.

## 8. Open questions

- Built-in vs external for the logic tools on modern builds — leaning *external*
  to preserve the DOS architecture/synergy, but built-in is cheaper to ship.
- Color depth on posix: map the VGA 16-color attrs to ANSI 16-color (safe
  everywhere) vs truecolor (nicer, needs capable terminals). Probably detect.
- cd-on-exit on Linux: same `CC_CWD_FILE` trick + a `cc()` shell function for
  bash/zsh/fish, mirroring the Windows `cc.ps1`/`cc.cmd` wrappers.
