/* ===========================================================================
 *  Claude Commander -- native Windows console port (wincc)
 *
 *  A Norton/Volkov-style two-panel file manager that runs directly in a
 *  Windows 10/11 console (cmd, Windows Terminal, PowerShell host) as a native
 *  PE -- no DOSBox, no 16-bit subsystem.  It shares the DESIGN of the DOS
 *  cc.asm (80x25 char-cell UI, the same attribute palette, a similar -- not
 *  identical -- key map; see README.md) but is a fresh C implementation on the
 *  Win32 Console + File APIs, so the 64 KB segment wall of the DOS build does
 *  not apply here.
 *
 *  File-op safety rules (see op_copy / op_delete / rm_tree / cp_tree):
 *   - a directory is never copied/moved into itself or its own subtree;
 *   - a move that falls back to copy+delete deletes the source only after the
 *     whole tree copied without a single failure;
 *   - name-surrogate reparse points (junctions, symlinks) are never recursed
 *     into: delete removes the link itself, copy skips directory links (counted
 *     as a failure) and copies file symlinks as their target's contents;
 *   - existing targets are not overwritten without a Y/N confirm;
 *   - every failure is counted and reported on the status row.
 *
 *  Milestone 1: console framebuffer, dual panels, directory read (native LFN
 *  via FindFirstFileW), navigation (arrows/pgup/pgdn/home/end), Tab to switch
 *  panel, Enter to descend / ".." to ascend, tag (Ins/Space), quit (F10/Esc).
 *
 *  Headless self-test seam (so it can be verified without an interactive TTY):
 *      cc.exe --dir <path> [--rdir <path>] [--keys <file>] --dump <outfile>
 *  composes frames purely in memory and writes the final 80x25 screen as UTF-8
 *  text, never touching the real console.  Mirrors the DOS /T + CCDUMP harness.
 *
 *  Build:  gcc -O2 -Wall -o cc.exe cc.c
 * =========================================================================== */
#include <windows.h>
#include <shellapi.h>        /* CommandLineToArgvW */
#ifdef _MSC_VER
#pragma comment(lib, "shell32.lib")
#endif
#include <stdio.h>
#include <stdarg.h>
#include <limits.h>
#include <stdlib.h>
#include <wchar.h>
#include <string.h>

#define MAXCOLS 512          /* allocation ceiling; logic uses g_cols/g_rows */
#define MAXROWS 256
#define LIST_Y0 1            /* first file row inside a panel box */

/* live dimensions (default 80x25; tracks the console window in run_live) */
static int g_cols = 80, g_rows = 25;

static int vis_rows(void) { int v = g_rows - 4; return v < 1 ? 1 : v; }   /* file rows per panel */

/* ---- attribute palette (same low-nibble fg / high-nibble bg as VGA text) --
 * Runtime variables (not #defines) so colour themes can swap them live. */
static WORD A_NORM, A_DIR, A_TAG, A_CUR, A_CURT, A_FRAME, A_HDR, A_STAT, A_FKEY, A_FKNUM;

typedef struct {
    const char *name;
    WORD norm, dir, tag, cur, curt, frame, hdr, stat, fkey, fknum;
} Theme;
static const Theme THEMES[] = {
    { "blue",  0x17, 0x1F, 0x1E, 0x30, 0x3E, 0x17, 0x1F, 0x17, 0x30, 0x07 },
    { "black", 0x07, 0x0F, 0x0E, 0x70, 0x7E, 0x08, 0x0F, 0x07, 0x70, 0x7F },
    { "mono",  0x07, 0x0F, 0x0F, 0x70, 0x70, 0x07, 0x0F, 0x07, 0x70, 0x70 },
};
#define NTHEMES ((int)(sizeof(THEMES) / sizeof(THEMES[0])))
static int g_theme = 0;

static void apply_theme(int i)
{
    g_theme = ((i % NTHEMES) + NTHEMES) % NTHEMES;
    const Theme *t = &THEMES[g_theme];
    A_NORM = t->norm; A_DIR = t->dir; A_TAG = t->tag; A_CUR = t->cur; A_CURT = t->curt;
    A_FRAME = t->frame; A_HDR = t->hdr; A_STAT = t->stat; A_FKEY = t->fkey; A_FKNUM = t->fknum;
}

static const char *SORTNAME[] = { "name", "ext", "size", "date" };

typedef struct {
    wchar_t           name[MAX_PATH];
    unsigned long long size;
    FILETIME          mtime;
    DWORD             attr;
    int               is_dir;
    int               tagged;
} Entry;

typedef struct {
    wchar_t path[MAX_PATH];
    Entry  *items;
    int     count, cap;
    int     cur, top;
    int     sortmode;       /* 0=name 1=ext 2=size 3=date */
} Panel;

static CHAR_INFO scr[MAXROWS * MAXCOLS];
static Panel L, R;
static Panel *act = &L;

static Panel *other(void) { return act == &L ? &R : &L; }
static void clamp_panel(Panel *p);   /* defined with the action handlers */

/* modal text input (mkdir / rename) */
static int     g_in_active = 0;
static int     g_in_kind   = 0;     /* 1=mkdir 2=rename */
static wchar_t g_in_title[40];
static wchar_t g_in_buf[MAX_PATH];
static int     g_in_len = 0;

/* confirm dialog (delete / overwrite) */
static int     g_cf_active = 0;
static wchar_t g_cf_msg[MAXCOLS];
static int     g_cf_kind = 0;       /* 1=delete 2=copy-overwrite 3=move-overwrite */

/* one-shot status-row message (op results / errors); cleared on the next key */
static wchar_t g_msg[MAXCOLS];

/* quick incremental search */
static wchar_t g_qs[64];
static int     g_qs_len = 0;

/* drive picker */
static int     g_drv_active = 0;
static wchar_t g_drv[32];        /* available drive letters, e.g. "ACD" */
static int     g_drv_n = 0;
static int     g_drv_sel = 0;
static Panel  *g_drv_target = NULL;

/* F3 viewer */
static int    g_view_active = 0;
static char  *g_view_buf = NULL;
static long   g_view_len = 0;
static long  *g_view_line = NULL;   /* byte offset of each line */
static int    g_view_nlines = 0;
static int    g_view_top = 0;
static int    g_view_trunc = 0;     /* file larger than the viewer cap */
static wchar_t g_view_name[MAX_PATH];
static void view_close(void);

/* ---------------------------------------------------------------- strings */
/* bounded wide printf that ALWAYS terminates; returns 0 if the output was
 * truncated (msvcrt's _vsnwprintf returns <0 and leaves no terminator then) */
static int swfmt(wchar_t *buf, size_t cap, const wchar_t *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnwprintf(buf, cap, fmt, ap);
    va_end(ap);
    buf[cap - 1] = 0;
    return n >= 0 && (size_t)n < cap;
}

/* set the status-row message; "what: <system error text>" when err != 0 */
static void set_msg(const wchar_t *what, DWORD err)
{
    if (!err) { swfmt(g_msg, MAXCOLS, L" %s", what); return; }
    wchar_t es[256] = L"";
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, err, 0, es, 256, NULL);
    for (size_t n = wcslen(es); n && (es[n - 1] == L'\r' || es[n - 1] == L'\n' || es[n - 1] == L'.'); )
        es[--n] = 0;
    swfmt(g_msg, MAXCOLS, L" %s: %s (%lu)", what, es, (unsigned long)err);
}

/* ---------------------------------------------------------------- framebuffer */
static void cell(int x, int y, wchar_t ch, WORD at)
{
    if (x < 0 || x >= g_cols || y < 0 || y >= g_rows) return;
    CHAR_INFO *c = &scr[y * g_cols + x];
    c->Char.UnicodeChar = ch;
    c->Attributes = at;
}
static void puts_at(int x, int y, const wchar_t *s, WORD at)
{
    for (; *s && x < g_cols; s++, x++) cell(x, y, *s, at);
}
/* like puts_at but never draws more than maxw cells (keeps text inside a box) */
static void puts_n(int x, int y, const wchar_t *s, int maxw, WORD at)
{
    for (; *s && maxw > 0 && x < g_cols; s++, x++, maxw--) cell(x, y, *s, at);
}
static void fill(int x, int y, int w, int h, wchar_t ch, WORD at)
{
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) cell(x + i, y + j, ch, at);
}
static void box(int x, int y, int w, int h, WORD at)
{
    cell(x, y, L'\x250C', at);            cell(x + w - 1, y, L'\x2510', at);
    cell(x, y + h - 1, L'\x2514', at);    cell(x + w - 1, y + h - 1, L'\x2518', at);
    for (int i = 1; i < w - 1; i++) { cell(x + i, y, L'\x2500', at); cell(x + i, y + h - 1, L'\x2500', at); }
    for (int j = 1; j < h - 1; j++) { cell(x, y + j, L'\x2502', at); cell(x + w - 1, y + j, L'\x2502', at); }
}

/* ---------------------------------------------------------------- directory io */
static int g_sortmode = 0;   /* set by read_dir before qsort */

static const wchar_t *ext_of(const wchar_t *n)
{
    const wchar_t *d = wcsrchr(n, L'.');
    return (d && d != n) ? d + 1 : L"";
}

static int ent_cmp(const void *a, const void *b)
{
    const Entry *x = a, *y = b;
    int xdd = (wcscmp(x->name, L"..") == 0);
    int ydd = (wcscmp(y->name, L"..") == 0);
    if (xdd != ydd) return ydd - xdd;            /* ".." first */
    if (x->is_dir != y->is_dir) return y->is_dir - x->is_dir;  /* dirs first */
    switch (g_sortmode) {
    case 1: { int e = _wcsicmp(ext_of(x->name), ext_of(y->name)); if (e) return e; break; }
    case 2: if (x->size < y->size) return -1; if (x->size > y->size) return 1; break;
    case 3: { LONG c = CompareFileTime(&y->mtime, &x->mtime); if (c) return c; break; }  /* newest first */
    default: break;
    }
    return _wcsicmp(x->name, y->name);
}

static int panel_add(Panel *p, const WIN32_FIND_DATAW *fd)
{
    if (p->count >= p->cap) {
        int ncap = p->cap ? p->cap * 2 : 64;
        Entry *ni = realloc(p->items, (size_t)ncap * sizeof(Entry));
        if (!ni) return 0;               /* keep the entries we already have */
        p->items = ni; p->cap = ncap;
    }
    Entry *e = &p->items[p->count++];
    wcsncpy(e->name, fd->cFileName, MAX_PATH - 1);
    e->name[MAX_PATH - 1] = 0;
    e->attr = fd->dwFileAttributes;
    e->is_dir = (e->attr & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
    e->size = ((unsigned long long)fd->nFileSizeHigh << 32) | fd->nFileSizeLow;
    e->mtime = fd->ftLastWriteTime;
    e->tagged = 0;
    return 1;
}

static int is_root(const wchar_t *path)
{
    /* "C:\" -> length 3, second char ':' */
    return (path[0] && path[1] == L':' && path[2] == L'\\' && path[3] == 0);
}

/* dir + "\" + name into a MAX_PATH buffer.  Returns 0 (and an empty out) when
 * the result would not fit -- callers must refuse the operation then, never
 * act on a silently truncated path. */
static int join(wchar_t *out, const wchar_t *dir, const wchar_t *name)
{
    size_t n = wcslen(dir), m = wcslen(name);
    int sep = !(n && dir[n - 1] == L'\\');
    if (n + sep + m + 1 > MAX_PATH) { out[0] = 0; return 0; }
    wmemcpy(out, dir, n);
    if (sep) out[n++] = L'\\';
    wmemcpy(out + n, name, m + 1);
    return 1;
}

static void read_dir(Panel *p)
{
    p->count = 0;
    p->cur = 0;
    p->top = 0;

    wchar_t pat[MAX_PATH];
    int ok = join(pat, p->path, L"*");   /* join avoids "C:\\*" on a root */

    if (!is_root(p->path)) {
        WIN32_FIND_DATAW dd = {0};
        wcscpy(dd.cFileName, L"..");
        dd.dwFileAttributes = FILE_ATTRIBUTE_DIRECTORY;
        panel_add(p, &dd);
    }

    WIN32_FIND_DATAW fd;
    HANDLE h = ok ? FindFirstFileW(pat, &fd) : INVALID_HANDLE_VALUE;
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0) continue;
            if (wcscmp(fd.cFileName, L"..") == 0) continue;
            if (!panel_add(p, &fd)) { set_msg(L"Out of memory: listing truncated", 0); break; }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    g_sortmode = p->sortmode;
    qsort(p->items, p->count, sizeof(Entry), ent_cmp);
}

static void go_parent(Panel *p)
{
    if (is_root(p->path)) return;
    wchar_t *bs = wcsrchr(p->path, L'\\');
    if (!bs) return;
    if (bs == p->path + 2) bs[1] = 0;   /* "C:\subdir" -> keep "C:\" */
    else *bs = 0;
}
static int go_child(Panel *p, const wchar_t *name)
{
    wchar_t np[MAX_PATH];
    if (!join(np, p->path, name)) { set_msg(L"Path too long", 0); return 0; }
    wcscpy(p->path, np);
    return 1;
}

/* ---------------------------------------------------------------- file ops */
#ifndef IsReparseTagNameSurrogate
#define IsReparseTagNameSurrogate(t) (((t) & 0x20000000) != 0)
#endif
static DWORD g_last_err = 0;         /* last Win32 error seen by a file op */
static void note_err(void) { g_last_err = GetLastError(); }
static int   g_link_skip = 0;        /* directory links cp_tree refused to follow */

/* A "link" is a name-surrogate reparse point: junction / mount point / dir or
 * file symlink / WSL symlink.  Other reparse points (OneDrive placeholders,
 * dedup, WOF-compressed files) are ordinary data and are treated normally. */
static int is_link(DWORD attr, DWORD tag)
{
    return (attr & FILE_ATTRIBUTE_REPARSE_POINT) && IsReparseTagNameSurrogate(tag);
}

/* attributes + reparse tag of the entry itself (never follows a link) */
static int path_info(const wchar_t *path, DWORD *attr, DWORD *tag)
{
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(path, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    FindClose(h);
    *attr = fd.dwFileAttributes;
    *tag  = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? fd.dwReserved0 : 0;
    return 1;
}

/* delete one file or empty dir / link; the read-only bit is cleared only right
 * before this item's own delete, and put back if the delete still fails */
static int rm_one(const wchar_t *path, DWORD attr)
{
    if (attr & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(path, attr & ~FILE_ATTRIBUTE_READONLY);
    BOOL ok = (attr & FILE_ATTRIBUTE_DIRECTORY) ? RemoveDirectoryW(path) : DeleteFileW(path);
    if (ok) return 0;
    note_err();
    if (attr & FILE_ATTRIBUTE_READONLY) SetFileAttributesW(path, attr);
    return 1;
}

/* recursive delete; returns the number of items that could not be removed.
 * A link is removed as a link (RemoveDirectoryW for a directory junction /
 * symlink, DeleteFileW for a file symlink) and is never recursed into. */
static int rm_tree(const wchar_t *path, DWORD attr, DWORD tag)
{
    if (is_link(attr, tag) || !(attr & FILE_ATTRIBUTE_DIRECTORY)) return rm_one(path, attr);
    int fail = 0;
    WIN32_FIND_DATAW fd;
    wchar_t pat[MAX_PATH];
    if (!join(pat, path, L"*")) { g_last_err = ERROR_FILENAME_EXCED_RANGE; return 1; }
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t c[MAX_PATH];
            if (!join(c, path, fd.cFileName)) { g_last_err = ERROR_FILENAME_EXCED_RANGE; fail++; continue; }
            DWORD t = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? fd.dwReserved0 : 0;
            fail += rm_tree(c, fd.dwFileAttributes, t);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    return fail + rm_one(path, attr);
}

/* recursive copy; returns the number of items that failed.  Directory links
 * are NOT followed (that is how junction cycles looped forever): they are
 * skipped and counted as failures, so a move falling back to copy keeps its
 * source.  File symlinks are copied as the contents of their target. */
static int cp_tree(const wchar_t *src, const wchar_t *dst, DWORD attr, DWORD tag, int overwrite)
{
    if (is_link(attr, tag) && (attr & FILE_ATTRIBUTE_DIRECTORY)) {
        g_link_skip++;
        return 1;
    }
    if (!(attr & FILE_ATTRIBUTE_DIRECTORY)) {
        if (CopyFileW(src, dst, !overwrite)) return 0;
        note_err(); return 1;
    }
    if (!CreateDirectoryW(dst, NULL)) {
        DWORD e = GetLastError(), da = GetFileAttributesW(dst);
        /* merging into an existing directory is allowed only when confirmed */
        if (!(e == ERROR_ALREADY_EXISTS && overwrite && da != INVALID_FILE_ATTRIBUTES
              && (da & FILE_ATTRIBUTE_DIRECTORY))) { g_last_err = e; return 1; }
    }
    int fail = 0;
    WIN32_FIND_DATAW fd;
    wchar_t pat[MAX_PATH];
    if (!join(pat, src, L"*")) { g_last_err = ERROR_FILENAME_EXCED_RANGE; return 1; }
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) { note_err(); return 1; }
    do {
        if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
        wchar_t s[MAX_PATH], d[MAX_PATH];
        if (!join(s, src, fd.cFileName) || !join(d, dst, fd.cFileName)) {
            g_last_err = ERROR_FILENAME_EXCED_RANGE; fail++; continue;
        }
        DWORD t = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ? fd.dwReserved0 : 0;
        fail += cp_tree(s, d, fd.dwFileAttributes, t, overwrite);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
    return fail;
}

/* Canonical form of an existing path for containment checks: the final path
 * (resolves junctions, subst, 8.3 names) when it can be opened, else the full
 * path; no "\\?\" prefix and no trailing backslash. */
static int canon_path(const wchar_t *in, wchar_t *out)
{
    wchar_t tmp[MAX_PATH + 8];
    int ok = 0;
    HANDLE h = CreateFileW(in, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD n = GetFinalPathNameByHandleW(h, tmp, MAX_PATH + 8, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        CloseHandle(h);
        if (n > 0 && n < MAX_PATH + 8) {
            const wchar_t *p = tmp;
            if (!wcsncmp(p, L"\\\\?\\UNC\\", 8)) { tmp[6] = L'\\'; p = tmp + 6; }  /* -> \\server\share */
            else if (!wcsncmp(p, L"\\\\?\\", 4)) p += 4;
            if (wcslen(p) < MAX_PATH) { wcscpy(out, p); ok = 1; }
        }
    }
    if (!ok) {
        DWORD n = GetFullPathNameW(in, MAX_PATH, out, NULL);
        if (n == 0 || n >= MAX_PATH) return 0;
    }
    size_t n = wcslen(out);
    while (n > 3 && out[n - 1] == L'\\') out[--n] = 0;
    return 1;
}

/* 1 if dir 'd' is 'src' itself or anywhere below it (case-insensitive, with a
 * separator boundary so "C:\A2" is not inside "C:\A").  Unresolvable -> 1
 * (refuse rather than risk it). */
static int inside_or_same(const wchar_t *d, const wchar_t *src)
{
    wchar_t cd[MAX_PATH], cs[MAX_PATH];
    if (!canon_path(d, cd) || !canon_path(src, cs)) return 1;
    size_t n = wcslen(cs);
    if (_wcsnicmp(cd, cs, n) != 0) return 0;
    return cd[n] == 0 || cd[n] == L'\\' || cs[n - 1] == L'\\';
}

/* the selection: tagged entries, else the cursor entry; ".." never counts.
 * Returns a malloc'd index list (caller frees) -- no fixed cap, so the confirm
 * dialog's count and the operation always agree. */
static int sel_count(Panel *p)
{
    int n = 0;
    for (int i = 0; i < p->count; i++)
        if (p->items[i].tagged && wcscmp(p->items[i].name, L"..") != 0) n++;
    if (n == 0 && p->count && wcscmp(p->items[p->cur].name, L"..") != 0) n = 1;
    return n;
}
static int *sel_list(Panel *p, int *n)
{
    *n = sel_count(p);
    if (!*n) return NULL;
    int *ix = malloc(sizeof(int) * (size_t)*n);
    if (!ix) { *n = 0; set_msg(L"Out of memory", 0); return NULL; }
    int k = 0;
    for (int i = 0; i < p->count; i++)
        if (p->items[i].tagged && wcscmp(p->items[i].name, L"..") != 0) ix[k++] = i;
    if (k == 0) ix[k++] = p->cur;
    return ix;
}

static void refresh(Panel *p)
{
    int c = p->cur, t = p->top;
    read_dir(p);
    p->cur = c; p->top = t;
    clamp_panel(p);
}
static void refresh_both(void) { refresh(&L); refresh(&R); }

/* both panels on the same folder (after resolving links / case / 8.3)? */
static int same_dir(const wchar_t *a, const wchar_t *b)
{
    wchar_t ca[MAX_PATH], cb[MAX_PATH];
    if (!canon_path(a, ca) || !canon_path(b, cb)) return 0;
    return _wcsicmp(ca, cb) == 0;
}

/* how many selected items already exist in the other panel (overwrite check) */
static int count_existing(void)
{
    int n, hit = 0, *ix = sel_list(act, &n);
    for (int k = 0; k < n; k++) {
        wchar_t d[MAX_PATH];
        if (join(d, other()->path, act->items[ix[k]].name)
            && GetFileAttributesW(d) != INVALID_FILE_ATTRIBUTES) hit++;
    }
    free(ix);
    return hit;
}

/* copy / move the selection to the other panel.  overwrite=0: items whose
 * target already exists are skipped (never silently replaced). */
static void op_copy(int move, int overwrite)
{
    const wchar_t *verb = move ? L"Move" : L"Copy";
    wchar_t m[MAXCOLS];
    Panel *dstp = other();
    if (same_dir(act->path, dstp->path)) {
        swfmt(m, MAXCOLS, L"%s: source and target are the same folder", verb);
        set_msg(m, 0);
        return;
    }
    int n, *ix = sel_list(act, &n);
    if (!n) return;
    int done = 0, fail = 0, skipped = 0, self = 0, kept = 0;
    g_last_err = 0; g_link_skip = 0;
    for (int k = 0; k < n; k++) {
        const wchar_t *nm = act->items[ix[k]].name;
        wchar_t s[MAX_PATH], d[MAX_PATH];
        DWORD a, t;
        if (!join(s, act->path, nm) || !join(d, dstp->path, nm)) {
            g_last_err = ERROR_FILENAME_EXCED_RANGE; fail++; continue;
        }
        if (!path_info(s, &a, &t)) { note_err(); fail++; continue; }
        int isdir = (a & FILE_ATTRIBUTE_DIRECTORY) && !is_link(a, t);
        /* a folder can never go into itself or its own subtree */
        if (isdir && inside_or_same(dstp->path, s)) { self++; fail++; continue; }
        if (!overwrite && GetFileAttributesW(d) != INVALID_FILE_ATTRIBUTES) { skipped++; continue; }
        if (move) {
            DWORD fl = MOVEFILE_COPY_ALLOWED | (overwrite ? MOVEFILE_REPLACE_EXISTING : 0);
            if (MoveFileExW(s, d, fl)) { done++; continue; }
            if (!(a & FILE_ATTRIBUTE_DIRECTORY)) { note_err(); fail++; continue; }
            /* directory rename failed (other volume, locked file, ...): copy the
             * tree, and delete the source ONLY if every single item copied */
            int f = cp_tree(s, d, a, t, overwrite);
            if (f) { fail += f; kept++; continue; }
            f = rm_tree(s, a, t);
            if (f) { fail += f; continue; }
            done++;
        } else {
            int f = cp_tree(s, d, a, t, overwrite);
            if (f) fail += f; else done++;
        }
    }
    free(ix);
    refresh_both();
    if (fail) {
        wchar_t lk[48] = L"";
        if (g_link_skip) swfmt(lk, 48, L" (%d folder link(s) not copied)", g_link_skip);
        swfmt(m, MAXCOLS, L"%s: %d done, %d failed%s%s%s", verb, done, fail,
              self ? L" (folder into itself refused)" : L"", lk,
              kept ? L" (source kept)" : L"");
        set_msg(m, (self + g_link_skip == fail) ? 0 : g_last_err);
    } else if (skipped) {
        swfmt(m, MAXCOLS, L"%s: %d done, %d skipped (already exist)", verb, done, skipped);
        set_msg(m, 0);
    } else {
        swfmt(m, MAXCOLS, L"%s: %d item(s) done", verb, done);
        set_msg(m, 0);
    }
}

static void op_delete(void)
{
    int n, *ix = sel_list(act, &n);
    if (!n) return;
    int done = 0, fail = 0;
    g_last_err = 0;
    for (int k = 0; k < n; k++) {
        wchar_t s[MAX_PATH];
        DWORD a, t;
        if (!join(s, act->path, act->items[ix[k]].name)) {
            g_last_err = ERROR_FILENAME_EXCED_RANGE; fail++; continue;
        }
        if (!path_info(s, &a, &t)) { note_err(); fail++; continue; }
        int f = rm_tree(s, a, t);      /* a link is removed as a link */
        if (f) fail += f; else done++;
    }
    free(ix);
    refresh_both();
    wchar_t m[MAXCOLS];
    if (fail) { swfmt(m, MAXCOLS, L"Delete: %d done, %d failed", done, fail); set_msg(m, g_last_err); }
    else      { swfmt(m, MAXCOLS, L"Delete: %d item(s) done", done);          set_msg(m, 0); }
}

static void op_mkdir(const wchar_t *name)
{
    if (!name || !name[0]) return;
    wchar_t d[MAX_PATH];
    if (!join(d, act->path, name)) { set_msg(L"MkDir: path too long", 0); return; }
    if (!CreateDirectoryW(d, NULL)) { set_msg(L"MkDir failed", GetLastError()); return; }
    refresh_both();
}

static void op_rename(const wchar_t *newname)
{
    if (!newname || !newname[0] || !act->count) return;
    Entry *e = &act->items[act->cur];
    if (wcscmp(e->name, L"..") == 0) return;
    wchar_t s[MAX_PATH], d[MAX_PATH];
    if (!join(s, act->path, e->name) || !join(d, act->path, newname)) {
        set_msg(L"Rename: path too long", 0); return;
    }
    if (!MoveFileW(s, d)) { set_msg(L"Rename failed", GetLastError()); return; }
    refresh_both();
}

/* ---------------------------------------------------------------- quick search */
static void qs_reset(void) { g_qs_len = 0; g_qs[0] = 0; }

static void qs_find(void)
{
    for (int i = 0; i < act->count; i++)
        if (_wcsnicmp(act->items[i].name, g_qs, g_qs_len) == 0) {
            act->cur = i;
            clamp_panel(act);
            return;
        }
}
static void qs_char(wchar_t c)
{
    if (g_qs_len < 63) { g_qs[g_qs_len++] = c; g_qs[g_qs_len] = 0; }
    qs_find();
}
static void qs_back(void)
{
    if (g_qs_len > 0) { g_qs[--g_qs_len] = 0; if (g_qs_len) qs_find(); }
}

/* ---------------------------------------------------------------- drives */
static void set_drive(wchar_t d)
{
    wchar_t p[4] = { (wchar_t)towupper(d), L':', L'\\', 0 };
    if (GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES) {
        wcscpy(act->path, p);
        read_dir(act);
    }
}
static void drive_open(Panel *target)
{
    DWORD mask = GetLogicalDrives();
    g_drv_n = 0;
    for (int i = 0; i < 26; i++)
        if (mask & (1u << i)) g_drv[g_drv_n++] = (wchar_t)(L'A' + i);
    g_drv[g_drv_n] = 0;
    g_drv_sel = 0;
    /* preselect the target's current drive */
    for (int i = 0; i < g_drv_n; i++)
        if (towupper(target->path[0]) == g_drv[i]) g_drv_sel = i;
    g_drv_target = target;
    g_drv_active = 1;
}

/* ---------------------------------------------------------------- F3 viewer */
static void view_open(void)
{
    if (!act->count) return;
    Entry *e = &act->items[act->cur];
    if (e->is_dir) return;
    wchar_t path[MAX_PATH];
    if (!join(path, act->path, e->name)) { set_msg(L"View: path too long", 0); return; }

    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { set_msg(L"View failed", GetLastError()); return; }
    LARGE_INTEGER fsz;
    if (!GetFileSizeEx(h, &fsz)) fsz.QuadPart = 0;
    const long VIEW_CAP = 8L << 20;                  /* show at most the first 8 MB */
    long cap = fsz.QuadPart > VIEW_CAP ? VIEW_CAP : (long)fsz.QuadPart;
    char *buf = malloc((size_t)cap + 1);
    if (!buf) { CloseHandle(h); set_msg(L"View: out of memory", 0); return; }
    long len = 0;
    while (len < cap) {                              /* ReadFile may return short */
        DWORD rd = 0;
        if (!ReadFile(h, buf + len, (DWORD)(cap - len), &rd, NULL) || rd == 0) break;
        len += (long)rd;
    }
    CloseHandle(h);
    buf[len] = 0;

    /* line table: count first, then allocate exactly one entry per line
     * (the old len/8 estimate overflowed on newline-dense files) */
    long nl = 1;
    for (long i = 0; i < len; i++) if (buf[i] == '\n') nl++;
    if (nl > INT_MAX) nl = INT_MAX;
    long *lines = malloc(sizeof(long) * (size_t)nl);
    if (!lines) { free(buf); set_msg(L"View: out of memory", 0); return; }
    int nlines = 0;
    lines[nlines++] = 0;
    for (long i = 0; i < len && nlines < nl; i++)
        if (buf[i] == '\n') lines[nlines++] = i + 1;

    view_close();
    g_view_buf = buf;   g_view_len = len;
    g_view_line = lines; g_view_nlines = nlines;
    g_view_trunc = fsz.QuadPart > len;
    g_view_top = 0;
    wcscpy(g_view_name, e->name);
    g_view_active = 1;
}

static void view_close(void)
{
    g_view_active = 0;
    free(g_view_buf);  g_view_buf = NULL;
    free(g_view_line); g_view_line = NULL;
}

static void view_scroll(int d)
{
    g_view_top += d;
    if (g_view_top > g_view_nlines - 1) g_view_top = g_view_nlines - 1;
    if (g_view_top < 0) g_view_top = 0;
}

/* ---------------------------------------------------------------- rendering */

/* Human-readable size: fits result into exactly 'width' chars (right-aligned
 * number + space + unit letter).  Caller must supply a buffer of width+1.
 * val is clamped to (width-2) decimal digits so snprintf never truncates.
 * E.g. width=9 → "9999999 G" caps at ~9.3 PB, which is fine for display. */
static void fmt_size(UINT64 sz, char *out, int width)
{
    const char *unit; UINT64 val;
    if      (sz < 1024ULL)           { val = sz;       unit = "B"; }
    else if (sz < 1024ULL*1024)      { val = sz >> 10; unit = "K"; }
    else if (sz < 1024ULL*1024*1024) { val = sz >> 20; unit = "M"; }
    else                             { val = sz >> 30; unit = "G"; }
    /* clamp to (width-2) digits so the snprintf output is exactly 'width' chars */
    UINT64 maxval = 1;
    { int d; for (d = 0; d < width - 2; d++) maxval *= 10; }
    if (val >= maxval) val = maxval - 1;
    snprintf(out, (size_t)(width + 1), "%*llu %s", width-2, (unsigned long long)val, unit);
}

static void render_panel(Panel *p, int px, int pw, int active)
{
    int ph = g_rows - 2;                 /* panel box height (rows above status) */
    box(px, 0, pw, ph, A_FRAME);

    /* path on the top border (truncated to fit) */
    wchar_t hdr[MAXCOLS];
    int hcap = pw - 4; if (hcap < 1) hcap = 1; if (hcap > MAXCOLS - 1) hcap = MAXCOLS - 1;
    _snwprintf(hdr, hcap, L" %s ", p->path);
    hdr[hcap] = 0;
    puts_at(px + 2, 0, hdr, A_HDR);

    int interior = pw - 2;
    int namew = interior - 10;           /* leave 10 cols for the size/<DIR> */
    if (namew < 4) namew = (interior > 4 ? interior - 1 : interior);

    for (int i = 0; i < ph - 2; i++) {
        int y = LIST_Y0 + i;
        int idx = p->top + i;
        if (idx >= p->count) { fill(px + 1, y, interior, 1, L' ', A_NORM); continue; }
        Entry *e = &p->items[idx];

        WORD at = e->is_dir ? A_DIR : A_NORM;
        if (e->tagged) at = A_TAG;
        if (active && idx == p->cur) at = e->tagged ? A_CURT : A_CUR;

        fill(px + 1, y, interior, 1, L' ', at);

        wchar_t nm[MAXCOLS];
        _snwprintf(nm, namew + 1, L"%s", e->name);
        nm[namew] = 0;
        puts_at(px + 1, y, nm, at);

        wchar_t sz[16];
        if (e->is_dir) {
            wcscpy(sz, L"<DIR>");
        } else {
            char buf[16];
            fmt_size(e->size, buf, 9);
            /* fmt_size produces ASCII-only output; widen char-by-char */
            int k;
            for (k = 0; k < 15 && buf[k]; k++) sz[k] = (wchar_t)(unsigned char)buf[k];
            sz[k] = L'\0';
        }
        int slen = (int)wcslen(sz);
        puts_at(px + (pw - 1) - slen, y, sz, at);
    }
}

static void render_view(void)
{
    fill(0, 0, g_cols, g_rows, L' ', A_NORM);
    /* header */
    fill(0, 0, g_cols, 1, L' ', A_HDR);
    wchar_t hdr[MAXCOLS];
    swfmt(hdr, MAXCOLS, L" View: %s   (%ld bytes%s, %d lines)",
          g_view_name, g_view_len, g_view_trunc ? L" shown, file truncated" : L"", g_view_nlines);
    puts_at(0, 0, hdr, A_HDR);

    int body = g_rows - 2;               /* rows 1 .. g_rows-2 */
    for (int row = 0; row < body; row++) {
        int ln = g_view_top + row;
        if (ln >= g_view_nlines) break;
        long off = g_view_line[ln];
        int x = 0;
        for (long i = off; i < g_view_len && g_view_buf[i] != '\n' && x < g_cols; i++) {
            unsigned char c = (unsigned char)g_view_buf[i];
            if (c == '\r') continue;
            if (c == '\t') { do { cell(x++, row + 1, L' ', A_NORM); } while (x % 8 && x < g_cols); continue; }
            if (c < 32 || c == 127) c = '.';
            cell(x++, row + 1, (wchar_t)c, A_NORM);
        }
    }
    /* footer */
    fill(0, g_rows - 1, g_cols, 1, L' ', A_FKEY);
    puts_at(0, g_rows - 1, L" PgUp/PgDn/Up/Down scroll   Esc/F3 close ", A_FKEY);
}

static void render_overlays(void)
{
    if (g_in_active) {
        int w = g_cols < 50 ? g_cols : 50, h = 5, x = (g_cols - w) / 2, y = (g_rows - h) / 2;
        int fw = w - 4;                      /* field width inside the box */
        fill(x, y, w, h, L' ', A_HDR);
        box(x, y, w, h, A_HDR);
        puts_n(x + 2, y, g_in_title, fw, A_HDR);
        fill(x + 2, y + 2, fw, 1, L' ', A_NORM);
        /* scroll the text so the tail + cursor always stay inside the field */
        int first = g_in_len - (fw - 1); if (first < 0) first = 0;
        puts_n(x + 2, y + 2, g_in_buf + first, fw - 1, A_NORM);
        cell(x + 2 + (g_in_len - first), y + 2, L'_', A_NORM);
    }
    if (g_cf_active) {
        int w = g_cols < 50 ? g_cols : 50, h = 5, x = (g_cols - w) / 2, y = (g_rows - h) / 2;
        fill(x, y, w, h, L' ', A_HDR);
        box(x, y, w, h, A_HDR);
        puts_n(x + 2, y + 1, g_cf_msg, w - 4, A_HDR);
        puts_n(x + 2, y + 3, g_cf_kind == 1 ? L"[Y] Yes    [N] No"
                                            : L"[Y] Overwrite  [N] Skip  [Esc] Cancel", w - 4, A_HDR);
    }
    if (g_drv_active) {
        int h = g_drv_n + 2, w = 14, x = (g_cols - w) / 2, y = (g_rows - h) / 2;
        fill(x, y, w, h, L' ', A_HDR);
        box(x, y, w, h, A_HDR);
        puts_at(x + 2, y, L" Drive ", A_HDR);
        for (int i = 0; i < g_drv_n; i++) {
            WORD at = (i == g_drv_sel) ? A_CUR : A_HDR;
            wchar_t line[8]; _snwprintf(line, 8, L" %c:\\ ", g_drv[i]);
            fill(x + 1, y + 1 + i, w - 2, 1, L' ', at);
            puts_at(x + 2, y + 1 + i, line, at);
        }
    }
}

static void compose_frame(void)
{
    if (g_view_active) { render_view(); return; }

    fill(0, 0, g_cols, g_rows, L' ', A_NORM);
    int leftw = g_cols / 2;
    render_panel(&L, 0, leftw, act == &L);
    render_panel(&R, leftw, g_cols - leftw, act == &R);

    /* status row */
    fill(0, g_rows - 2, g_cols, 1, L' ', A_STAT);
    {
        wchar_t st[MAXCOLS];
        if (g_qs_len)
            swfmt(st, MAXCOLS, L" search: %s_", g_qs);
        else if (g_msg[0])
            swfmt(st, MAXCOLS, L"%s", g_msg);
        else {
            const wchar_t *nm = act->count ? act->items[act->cur].name : L"";
            swfmt(st, MAXCOLS, L" %s   %d item(s)   sort:%S  theme:%S",
                  nm, act->count, SORTNAME[act->sortmode], THEMES[g_theme].name);
        }
        puts_at(0, g_rows - 2, st, A_STAT);
    }

    /* F-key bar: only keys that are actually bound get a label (F1 and F9
     * have no function in this port, so their slots stay blank) */
    static const wchar_t *fk[10] = {
        L"", L"Rename", L"View", L"Edit", L"Copy",
        L"Move", L"MkDir", L"Del", L"", L"Quit"
    };
    fill(0, g_rows - 1, g_cols, 1, L' ', A_FKEY);
    int x = 0;
    for (int i = 0; i < 10; i++) {
        wchar_t num[4]; swfmt(num, 4, L"%d", i + 1);
        puts_at(x, g_rows - 1, num, A_FKNUM); x += (int)wcslen(num);
        puts_at(x, g_rows - 1, fk[i], A_FKEY); x += (int)wcslen(fk[i]) + 1;
    }

    render_overlays();
}

/* ---------------------------------------------------------------- actions */
enum { ACT_NONE, ACT_UP, ACT_DOWN, ACT_PGUP, ACT_PGDN, ACT_HOME, ACT_END,
       ACT_ENTER, ACT_TAB, ACT_TAG, ACT_QUIT,
       ACT_VIEW, ACT_COPY, ACT_MOVE, ACT_MKDIR, ACT_DELETE, ACT_RENAME,
       ACT_SORT, ACT_THEME, ACT_EDIT, ACT_DRIVEL, ACT_DRIVER };

static void set_sort(int m)
{
    act->sortmode = ((m % 4) + 4) % 4;
    read_dir(act);
    clamp_panel(act);
}

static void clamp_panel(Panel *p)
{
    if (p->cur < 0) p->cur = 0;
    if (p->cur >= p->count) p->cur = p->count - 1;
    if (p->cur < 0) p->cur = 0;
    if (p->cur < p->top) p->top = p->cur;
    if (p->cur >= p->top + vis_rows()) p->top = p->cur - vis_rows() + 1;
    if (p->top < 0) p->top = 0;
}

static void open_input(int kind, const wchar_t *title, const wchar_t *prefill)
{
    g_in_active = 1;
    g_in_kind = kind;
    wcsncpy(g_in_title, title, 39); g_in_title[39] = 0;
    wcsncpy(g_in_buf, prefill, MAX_PATH - 1); g_in_buf[MAX_PATH - 1] = 0;
    g_in_len = (int)wcslen(g_in_buf);
}

static void launch_editor(void)
{
    if (!act->count) return;
    Entry *e = &act->items[act->cur];
    if (e->is_dir) return;
    wchar_t path[MAX_PATH];
    if (!join(path, act->path, e->name)) { set_msg(L"Edit: path too long", 0); return; }

    const wchar_t *ed = _wgetenv(L"EDITOR");
    wchar_t cmd[MAX_PATH * 2];
    int ok = (ed && ed[0]) ? swfmt(cmd, MAX_PATH * 2, L"\"%s\" \"%s\"", ed, path)
                           : swfmt(cmd, MAX_PATH * 2, L"notepad.exe \"%s\"", path);
    if (!ok) { set_msg(L"Edit: command line too long", 0); return; }

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {0};
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, act->path, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        set_msg(L"Edit: cannot start editor", GetLastError());
    }
}

/* F5/F6: ask before overwriting anything that already exists in the target */
static void begin_copy(int move)
{
    int ex = count_existing();
    if (ex > 0) {
        g_cf_active = 1; g_cf_kind = move ? 3 : 2;
        swfmt(g_cf_msg, MAXCOLS, L"%d item(s) already exist in target. Overwrite?", ex);
    } else {
        op_copy(move, 0);
    }
}

/* answer the open confirm dialog: 1 = Y, 0 = N, -1 = Esc */
static void cf_answer(int ans)
{
    int kind = g_cf_kind;
    g_cf_active = 0;
    if (kind == 1) { if (ans == 1) op_delete(); }
    else if (ans >= 0) op_copy(kind == 3, ans == 1);   /* N = skip existing */
    clamp_panel(act);
}

/* returns 1 to quit */
static int do_action(int a)
{
    /* drive picker captures navigation while open */
    if (g_drv_active) {
        switch (a) {
        case ACT_UP:    if (--g_drv_sel < 0) g_drv_sel = 0; break;
        case ACT_DOWN:  if (++g_drv_sel >= g_drv_n) g_drv_sel = g_drv_n - 1; break;
        case ACT_ENTER: {
            Panel *sv = act; act = g_drv_target;
            set_drive(g_drv[g_drv_sel]);
            act = sv; g_drv_active = 0;
            break;
        }
        case ACT_QUIT:  g_drv_active = 0; break;
        }
        return 0;
    }

    /* viewer captures navigation while open */
    if (g_view_active) {
        switch (a) {
        case ACT_UP:   view_scroll(-1); break;
        case ACT_DOWN: view_scroll(+1); break;
        case ACT_PGUP: view_scroll(-22); break;
        case ACT_PGDN: view_scroll(+22); break;
        case ACT_HOME: g_view_top = 0; break;
        case ACT_END:  g_view_top = g_view_nlines - 1; if (g_view_top < 0) g_view_top = 0; break;
        case ACT_VIEW:
        case ACT_QUIT: view_close(); break;
        }
        return 0;
    }

    qs_reset();   /* any explicit action ends an in-progress quick search */

    switch (a) {
    case ACT_UP:   act->cur--; break;
    case ACT_DOWN: act->cur++; break;
    case ACT_PGUP: act->cur -= vis_rows() - 1; break;
    case ACT_PGDN: act->cur += vis_rows() - 1; break;
    case ACT_HOME: act->cur = 0; break;
    case ACT_END:  act->cur = act->count - 1; break;
    case ACT_VIEW:   view_open(); break;
    case ACT_COPY:   begin_copy(0); break;
    case ACT_MOVE:   begin_copy(1); break;
    case ACT_DELETE: op_delete(); break;
    case ACT_MKDIR:  open_input(1, L" Create directory ", L""); break;
    case ACT_RENAME:
        if (act->count) {
            Entry *e = &act->items[act->cur];
            if (wcscmp(e->name, L"..") != 0) open_input(2, L" Rename to ", e->name);
        }
        break;
    case ACT_SORT:  set_sort(act->sortmode + 1); break;
    case ACT_THEME: apply_theme(g_theme + 1); break;
    case ACT_EDIT:  launch_editor(); break;
    case ACT_DRIVEL: drive_open(&L); break;
    case ACT_DRIVER: drive_open(&R); break;
    case ACT_TAB:  act = (act == &L) ? &R : &L; break;
    case ACT_TAG:
        if (act->count) {
            Entry *e = &act->items[act->cur];
            if (wcscmp(e->name, L"..") != 0) e->tagged = !e->tagged;
            act->cur++;
        }
        break;
    case ACT_ENTER:
        if (act->count) {
            Entry *e = &act->items[act->cur];
            if (e->is_dir) {
                if (wcscmp(e->name, L"..") == 0) go_parent(act);
                else if (!go_child(act, e->name)) break;   /* too long: stay put */
                read_dir(act);
            }
        }
        break;
    case ACT_QUIT: return 1;
    }
    clamp_panel(act);
    return 0;
}

/* ---------------------------------------------------------------- headless dump */
static void dump_frame(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) return;
    for (int y = 0; y < g_rows; y++) {
        wchar_t line[MAXCOLS + 1];
        for (int x = 0; x < g_cols; x++) {
            wchar_t ch = scr[y * g_cols + x].Char.UnicodeChar;
            line[x] = ch ? ch : L' ';
        }
        line[g_cols] = 0;
        char utf8[MAXCOLS * 4 + 1];
        int n = WideCharToMultiByte(CP_UTF8, 0, line, g_cols, utf8, sizeof(utf8) - 1, NULL, NULL);
        utf8[n] = 0;
        fputs(utf8, f);
        fputc('\n', f);
    }
    fclose(f);
}

static void dump_attr(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) return;
    for (int y = 0; y < g_rows; y++) {
        for (int x = 0; x < g_cols; x++)
            fprintf(f, "%02x ", scr[y * g_cols + x].Attributes & 0xFF);
        fputc('\n', f);
    }
    fclose(f);
}

static int token_action(const char *t)
{
    if (!_stricmp(t, "UP"))     return ACT_UP;
    if (!_stricmp(t, "DOWN"))   return ACT_DOWN;
    if (!_stricmp(t, "PGUP"))   return ACT_PGUP;
    if (!_stricmp(t, "PGDN"))   return ACT_PGDN;
    if (!_stricmp(t, "HOME"))   return ACT_HOME;
    if (!_stricmp(t, "END"))    return ACT_END;
    if (!_stricmp(t, "ENTER"))  return ACT_ENTER;
    if (!_stricmp(t, "TAB"))    return ACT_TAB;
    if (!_stricmp(t, "TAG"))    return ACT_TAG;
    if (!_stricmp(t, "QUIT"))   return ACT_QUIT;
    if (!_stricmp(t, "COPY"))   return ACT_COPY;
    if (!_stricmp(t, "MOVE"))   return ACT_MOVE;
    if (!_stricmp(t, "DEL"))    return ACT_DELETE;
    if (!_stricmp(t, "VIEW"))   return ACT_VIEW;
    if (!_stricmp(t, "SORT"))   return ACT_SORT;
    if (!_stricmp(t, "THEME"))  return ACT_THEME;
    if (!_stricmp(t, "EDIT"))   return ACT_EDIT;
    if (!_stricmp(t, "DRIVESL")) return ACT_DRIVEL;
    if (!_stricmp(t, "DRIVESR")) return ACT_DRIVER;
    if (!_stricmp(t, "RENBOX"))  return ACT_RENAME;   /* opens the F2 input box */
    return ACT_NONE;
}

static void mb2w(const char *s, wchar_t *w, int cap)
{
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, cap);
}

/* headless replay: handles arg-carrying tokens (MKDIR:name, REN:name) too */
static void apply_token(const char *t)
{
    g_msg[0] = 0;                        /* like a keypress: drop the last message */
    /* an open confirm dialog takes only YES / NO / CANCEL (live: Y / N / Esc) */
    if (g_cf_active) {
        if      (!_stricmp(t, "YES"))    cf_answer(1);
        else if (!_stricmp(t, "NO"))     cf_answer(0);
        else if (!_stricmp(t, "CANCEL")) cf_answer(-1);
        return;
    }
    if (!_strnicmp(t, "MKDIR:", 6)) { wchar_t w[MAX_PATH]; mb2w(t + 6, w, MAX_PATH); op_mkdir(w); return; }
    if (!_strnicmp(t, "REN:", 4))   { wchar_t w[MAX_PATH]; mb2w(t + 4, w, MAX_PATH); op_rename(w); return; }
    if (!_strnicmp(t, "SORT:", 5)) {
        const char *m = t + 5;
        if (!_stricmp(m, "name")) set_sort(0);
        else if (!_stricmp(m, "ext"))  set_sort(1);
        else if (!_stricmp(m, "size")) set_sort(2);
        else if (!_stricmp(m, "date")) set_sort(3);
        return;
    }
    if (!_strnicmp(t, "TYPE:", 5)) {
        wchar_t w[64]; mb2w(t + 5, w, 64);
        for (int i = 0; w[i]; i++) qs_char(w[i]);
        return;
    }
    if (!_strnicmp(t, "DRIVE:", 6)) { set_drive((wchar_t)t[6]); return; }
    int a = token_action(t);
    if (a != ACT_NONE) do_action(a);
}

/* ---------------------------------------------------------------- live console */
static int key_to_action(const KEY_EVENT_RECORD *k)
{
    switch (k->wVirtualKeyCode) {
    case VK_UP:     return ACT_UP;
    case VK_DOWN:   return ACT_DOWN;
    case VK_PRIOR:  return ACT_PGUP;
    case VK_NEXT:   return ACT_PGDN;
    case VK_HOME:   return ACT_HOME;
    case VK_END:    return ACT_END;
    case VK_RETURN: return ACT_ENTER;
    case VK_TAB:    return ACT_TAB;
    case VK_INSERT: return ACT_TAG;
    case VK_SPACE:  return ACT_TAG;
    case VK_ESCAPE: return ACT_QUIT;
    case VK_F10:    return ACT_QUIT;
    case VK_F2:     return ACT_RENAME;
    case VK_F3:     return ACT_VIEW;
    case VK_F4:     return ACT_EDIT;
    case VK_F5:     return ACT_COPY;
    case VK_F6:     return ACT_MOVE;
    case VK_F7:     return ACT_MKDIR;
    }
    return ACT_NONE;
}

/* handle a key while a modal (input / confirm) is open; returns 1 if consumed */
static int handle_modal(const KEY_EVENT_RECORD *k)
{
    if (g_in_active) {
        WORD vk = k->wVirtualKeyCode;
        wchar_t ch = k->uChar.UnicodeChar;
        if (vk == VK_RETURN) {
            g_in_active = 0;
            if (g_in_kind == 1) op_mkdir(g_in_buf);
            else if (g_in_kind == 2) op_rename(g_in_buf);
        } else if (vk == VK_ESCAPE) {
            g_in_active = 0;
        } else if (vk == VK_BACK) {
            if (g_in_len > 0) g_in_buf[--g_in_len] = 0;
        } else if (ch >= 32 && g_in_len < MAX_PATH - 1) {
            g_in_buf[g_in_len++] = ch;
            g_in_buf[g_in_len] = 0;
        }
        return 1;
    }
    if (g_cf_active) {
        wchar_t ch = k->uChar.UnicodeChar;
        if (ch == L'y' || ch == L'Y')              cf_answer(1);
        else if (ch == L'n' || ch == L'N')         cf_answer(0);
        else if (k->wVirtualKeyCode == VK_ESCAPE)  cf_answer(-1);
        return 1;
    }
    return 0;
}

static void run_live(void)
{
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE hIn  = GetStdHandle(STD_INPUT_HANDLE);

    DWORD inMode = 0; GetConsoleMode(hIn, &inMode);
    CONSOLE_SCREEN_BUFFER_INFO saved; GetConsoleScreenBufferInfo(hOut, &saved);
    CONSOLE_CURSOR_INFO ci; GetConsoleCursorInfo(hOut, &ci);
    CONSOLE_CURSOR_INFO hide = ci; hide.bVisible = FALSE;

    /* ENABLE_WINDOW_INPUT delivers resize events; ENABLE_EXTENDED_FLAGS without
     * ENABLE_QUICK_EDIT_MODE turns off quick-edit/line/echo so we get raw keys. */
    SetConsoleMode(hIn, ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS);
    SetConsoleCursorInfo(hOut, &hide);

    int quit = 0;
    while (!quit) {
        /* follow the live console window size each frame */
        CONSOLE_SCREEN_BUFFER_INFO bi;
        if (!GetConsoleScreenBufferInfo(hOut, &bi)) break;   /* console went away */
        int W = bi.srWindow.Right - bi.srWindow.Left + 1;
        int H = bi.srWindow.Bottom - bi.srWindow.Top + 1;
        if (W < 24) W = 24;
        if (W > MAXCOLS) W = MAXCOLS;
        if (H < 8) H = 8;
        if (H > MAXROWS) H = MAXROWS;
        g_cols = W; g_rows = H;
        clamp_panel(&L); clamp_panel(&R);

        compose_frame();
        COORD bufsz = { (SHORT)g_cols, (SHORT)g_rows }, org = {0, 0};
        SMALL_RECT reg = bi.srWindow;
        reg.Right  = reg.Left + (SHORT)g_cols - 1;
        reg.Bottom = reg.Top  + (SHORT)g_rows - 1;
        WriteConsoleOutputW(hOut, scr, bufsz, org, &reg);

        INPUT_RECORD ir;
        DWORD nr = 0;
        /* a failing read would otherwise spin this loop at 100% CPU */
        if (!ReadConsoleInputW(hIn, &ir, 1, &nr)) break;
        if (nr == 0) continue;
        if (ir.EventType == WINDOW_BUFFER_SIZE_EVENT) continue;  /* re-render at new size */
        if (ir.EventType == KEY_EVENT && ir.Event.KeyEvent.bKeyDown) {
            const KEY_EVENT_RECORD *ke = &ir.Event.KeyEvent;
            g_msg[0] = 0;                    /* a key dismisses the last op message */
            if (handle_modal(ke)) continue;

            /* drive picker captures keys while open */
            if (g_drv_active) {
                int a = key_to_action(ke);
                if (a != ACT_NONE) do_action(a);
                continue;
            }

            DWORD alt  = ke->dwControlKeyState & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED);
            DWORD ctrl = ke->dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED);

            /* Alt+F1 / Alt+F2 open the drive picker for left / right panel */
            if (alt && ke->wVirtualKeyCode == VK_F1) { do_action(ACT_DRIVEL); continue; }
            if (alt && ke->wVirtualKeyCode == VK_F2) { do_action(ACT_DRIVER); continue; }

            /* Ctrl+S cycle sort, Ctrl+T cycle theme */
            if (ctrl && !g_view_active) {
                if (ke->wVirtualKeyCode == 'S') { do_action(ACT_SORT);  continue; }
                if (ke->wVirtualKeyCode == 'T') { do_action(ACT_THEME); continue; }
            }

            /* quick-search editing */
            if (!g_view_active) {
                if (ke->wVirtualKeyCode == VK_BACK   && g_qs_len) { qs_back();  continue; }
                if (ke->wVirtualKeyCode == VK_ESCAPE && g_qs_len) { qs_reset(); continue; }
            }
            /* F8 / Del opens a confirm dialog rather than deleting outright */
            if ((ke->wVirtualKeyCode == VK_F8 || ke->wVirtualKeyCode == VK_DELETE)
                && !g_view_active) {
                int n = sel_count(act);      /* same selection op_delete acts on */
                if (n > 0) {
                    g_cf_active = 1; g_cf_kind = 1;
                    swfmt(g_cf_msg, MAXCOLS, L"Delete %d item(s)?", n);
                }
                continue;
            }

            /* printable char (not space — space tags) starts/extends quick search */
            wchar_t uc = ke->uChar.UnicodeChar;
            if (uc > 32 && !ctrl && !alt && !g_view_active) { qs_char(uc); continue; }

            int a = key_to_action(ke);
            if (a != ACT_NONE) quit = do_action(a);
        }
    }

    /* restore */
    SetConsoleCursorInfo(hOut, &ci);
    SetConsoleScreenBufferSize(hOut, saved.dwSize);
    SetConsoleWindowInfo(hOut, TRUE, &saved.srWindow);
    SetConsoleMode(hIn, inMode);
}

/* ---------------------------------------------------------------- main */
/* "cd on exit": a Windows process can't change its parent shell's current
 * directory, so on quit we write the active panel's path to the file named by
 * %CC_CWD_FILE% (if set). The cc.cmd / cc.ps1 wrappers read it back and cd
 * there — the same mechanism Far Manager and Midnight Commander use. */
static void write_exit_cwd(void)
{
    const char *f = getenv("CC_CWD_FILE");
    if (!f || !*f) return;
    /* UTF-8, no BOM, no newline: cc.ps1 reads it with -Encoding UTF8 and
     * cc.cmd with chcp 65001 active, so non-ANSI folder names survive */
    FILE *fp = fopen(f, "wb");
    if (!fp) return;
    char path[MAX_PATH * 4];
    int n = WideCharToMultiByte(CP_UTF8, 0, act->path, -1,
                                path, sizeof(path), NULL, NULL);
    if (n > 1) fwrite(path, 1, (size_t)(n - 1), fp);
    fclose(fp);
}

/* w: the argument as UTF-16 (from CommandLineToArgvW, so folder names outside
 * the ANSI codepage survive) */
static void set_path_arg(Panel *p, const wchar_t *w)
{
    wchar_t full[MAX_PATH];
    /* turn it absolute (keep the default if it doesn't fit) */
    DWORD fn = GetFullPathNameW(w, MAX_PATH, full, NULL);
    if (fn == 0 || fn >= MAX_PATH) return;
    wcscpy(p->path, full);
    /* strip a trailing backslash unless it's a drive root */
    size_t n = wcslen(p->path);
    if (n > 3 && p->path[n - 1] == L'\\') p->path[n - 1] = 0;
}

int main(int argc, char **argv)
{
    apply_theme(0);

    /* defaults: both panels = current directory (or C:\ if it can't be had) */
    DWORD cn = GetCurrentDirectoryW(MAX_PATH, L.path);
    if (cn == 0 || cn >= MAX_PATH) wcscpy(L.path, L"C:\\");
    wcscpy(R.path, L.path);

    int wargc = 0;
    wchar_t **wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
    if (!wargv || wargc != argc) wargv = NULL;   /* fall back to the ANSI argv */

    const char *dumpfile = NULL, *keysfile = NULL, *attrfile = NULL;
    for (int i = 1; i < argc; i++) {
        if ((!strcmp(argv[i], "--dir") || !strcmp(argv[i], "--rdir")) && i + 1 < argc) {
            Panel *p = argv[i][2] == 'r' ? &R : &L;
            i++;
            if (wargv) set_path_arg(p, wargv[i]);
            else {
                wchar_t w[MAX_PATH];
                if (MultiByteToWideChar(CP_ACP, 0, argv[i], -1, w, MAX_PATH)) set_path_arg(p, w);
            }
        }
        else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dumpfile = argv[++i];
        else if (!strcmp(argv[i], "--dumpa") && i + 1 < argc) attrfile = argv[++i];
        else if (!strcmp(argv[i], "--keys") && i + 1 < argc) keysfile = argv[++i];
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) {
            int w = 0, h = 0;
            if (sscanf(argv[++i], "%dx%d", &w, &h) == 2) {
                if (w >= 24 && w <= MAXCOLS) g_cols = w;
                if (h >= 8  && h <= MAXROWS) g_rows = h;
            }
        }
    }

    read_dir(&L);
    read_dir(&R);

    if (dumpfile || attrfile) {
        if (keysfile) {
            FILE *kf = fopen(keysfile, "r");
            if (kf) {
                char tok[MAX_PATH];
                while (fscanf(kf, "%259s", tok) == 1)
                    apply_token(tok);
                fclose(kf);
            }
        }
        compose_frame();
        if (dumpfile) dump_frame(dumpfile);
        if (attrfile) dump_attr(attrfile);
        write_exit_cwd();
        return 0;
    }

    /* interactive mode needs a real console on both ends; with redirected or
     * piped stdin, ReadConsoleInput fails and the loop used to spin at 100% */
    {
        DWORD m;
        CONSOLE_SCREEN_BUFFER_INFO bi;
        if (!GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &m) ||
            !GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &bi)) {
            fprintf(stderr, "cc: needs an interactive console (stdin/stdout must not be "
                            "redirected); use --dump for headless mode\n");
            return 2;
        }
    }
    run_live();
    write_exit_cwd();
    return 0;
}
