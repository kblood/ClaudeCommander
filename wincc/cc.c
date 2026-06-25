/* ===========================================================================
 *  Claude Commander -- native Windows console port (wincc)
 *
 *  A Norton/Volkov-style two-panel file manager that runs directly in a
 *  Windows 10/11 console (cmd, Windows Terminal, PowerShell host) as a native
 *  PE -- no DOSBox, no 16-bit subsystem.  It shares the DESIGN of the DOS
 *  cc.asm (80x25 char-cell UI, the same attribute palette, the same key map)
 *  but is a fresh C implementation on the Win32 Console + File APIs, so the
 *  64 KB segment wall of the DOS build does not apply here.
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
#include <stdio.h>
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

/* confirm dialog (delete) */
static int     g_cf_active = 0;
static wchar_t g_cf_msg[MAXCOLS];
static int     g_cf_kind = 0;       /* 1=delete */

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
static wchar_t g_view_name[MAX_PATH];

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

static void panel_add(Panel *p, const WIN32_FIND_DATAW *fd)
{
    if (p->count >= p->cap) {
        p->cap = p->cap ? p->cap * 2 : 64;
        p->items = realloc(p->items, p->cap * sizeof(Entry));
    }
    Entry *e = &p->items[p->count++];
    wcsncpy(e->name, fd->cFileName, MAX_PATH - 1);
    e->name[MAX_PATH - 1] = 0;
    e->attr = fd->dwFileAttributes;
    e->is_dir = (e->attr & FILE_ATTRIBUTE_DIRECTORY) ? 1 : 0;
    e->size = ((unsigned long long)fd->nFileSizeHigh << 32) | fd->nFileSizeLow;
    e->mtime = fd->ftLastWriteTime;
    e->tagged = 0;
}

static int is_root(const wchar_t *path)
{
    /* "C:\" -> length 3, second char ':' */
    return (path[0] && path[1] == L':' && path[2] == L'\\' && path[3] == 0);
}

static void read_dir(Panel *p)
{
    p->count = 0;
    p->cur = 0;
    p->top = 0;

    wchar_t pat[MAX_PATH];
    _snwprintf(pat, MAX_PATH, L"%s\\*", p->path);
    /* collapse a possible "C:\\\*" into "C:\*" */
    if (is_root(p->path)) _snwprintf(pat, MAX_PATH, L"%s*", p->path);

    if (!is_root(p->path)) {
        WIN32_FIND_DATAW dd = {0};
        wcscpy(dd.cFileName, L"..");
        dd.dwFileAttributes = FILE_ATTRIBUTE_DIRECTORY;
        panel_add(p, &dd);
    }

    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0) continue;
            if (wcscmp(fd.cFileName, L"..") == 0) continue;
            panel_add(p, &fd);
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
static void go_child(Panel *p, const wchar_t *name)
{
    size_t len = wcslen(p->path);
    if (len && p->path[len - 1] == L'\\')
        _snwprintf(p->path + len, MAX_PATH - len, L"%s", name);
    else
        _snwprintf(p->path + len, MAX_PATH - len, L"\\%s", name);
}

/* ---------------------------------------------------------------- file ops */
static void join(wchar_t *out, const wchar_t *dir, const wchar_t *name)
{
    size_t n = wcslen(dir);
    if (n && dir[n - 1] == L'\\') _snwprintf(out, MAX_PATH, L"%s%s", dir, name);
    else                          _snwprintf(out, MAX_PATH, L"%s\\%s", dir, name);
}

static void rm_tree(const wchar_t *path)
{
    WIN32_FIND_DATAW fd;
    wchar_t pat[MAX_PATH]; join(pat, path, L"*");
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t c[MAX_PATH]; join(c, path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) rm_tree(c);
            else { SetFileAttributesW(c, FILE_ATTRIBUTE_NORMAL); DeleteFileW(c); }
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
    SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
    RemoveDirectoryW(path);
}

static void cp_tree(const wchar_t *src, const wchar_t *dst)
{
    CreateDirectoryW(dst, NULL);
    WIN32_FIND_DATAW fd;
    wchar_t pat[MAX_PATH]; join(pat, src, L"*");
    HANDLE h = FindFirstFileW(pat, &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
            wchar_t s[MAX_PATH], d[MAX_PATH];
            join(s, src, fd.cFileName); join(d, dst, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) cp_tree(s, d);
            else CopyFileW(s, d, FALSE);
        } while (FindNextFileW(h, &fd));
        FindClose(h);
    }
}

/* collect the selected names (tagged set, else the cursor entry) */
static int collect(Panel *p, wchar_t (*out)[MAX_PATH], int max)
{
    int n = 0;
    for (int i = 0; i < p->count && n < max; i++)
        if (p->items[i].tagged && wcscmp(p->items[i].name, L"..") != 0)
            wcscpy(out[n++], p->items[i].name);
    if (n == 0 && p->count) {
        Entry *e = &p->items[p->cur];
        if (wcscmp(e->name, L"..") != 0) wcscpy(out[n++], e->name);
    }
    return n;
}

static void refresh(Panel *p)
{
    int c = p->cur, t = p->top;
    read_dir(p);
    p->cur = c; p->top = t;
    clamp_panel(p);
}
static void refresh_both(void) { refresh(&L); refresh(&R); }

#define MAXSEL 4096
static wchar_t g_sel[MAXSEL][MAX_PATH];

static void op_copy(int move)
{
    int n = collect(act, g_sel, MAXSEL);
    Panel *dstp = other();
    for (int i = 0; i < n; i++) {
        wchar_t s[MAX_PATH], d[MAX_PATH];
        join(s, act->path, g_sel[i]);
        join(d, dstp->path, g_sel[i]);
        DWORD a = GetFileAttributesW(s);
        int isdir = (a != INVALID_FILE_ATTRIBUTES) && (a & FILE_ATTRIBUTE_DIRECTORY);
        if (move) {
            if (!MoveFileExW(s, d, MOVEFILE_COPY_ALLOWED | MOVEFILE_REPLACE_EXISTING)) {
                if (isdir) { cp_tree(s, d); rm_tree(s); }
            }
        } else {
            if (isdir) cp_tree(s, d);
            else       CopyFileW(s, d, FALSE);
        }
    }
    refresh_both();
}

static void op_delete(void)
{
    int n = collect(act, g_sel, MAXSEL);
    for (int i = 0; i < n; i++) {
        wchar_t s[MAX_PATH]; join(s, act->path, g_sel[i]);
        DWORD a = GetFileAttributesW(s);
        if (a == INVALID_FILE_ATTRIBUTES) continue;
        if (a & FILE_ATTRIBUTE_DIRECTORY) rm_tree(s);
        else { SetFileAttributesW(s, FILE_ATTRIBUTE_NORMAL); DeleteFileW(s); }
    }
    refresh_both();
}

static void op_mkdir(const wchar_t *name)
{
    if (!name || !name[0]) return;
    wchar_t d[MAX_PATH]; join(d, act->path, name);
    CreateDirectoryW(d, NULL);
    refresh_both();
}

static void op_rename(const wchar_t *newname)
{
    if (!newname || !newname[0] || !act->count) return;
    Entry *e = &act->items[act->cur];
    if (wcscmp(e->name, L"..") == 0) return;
    wchar_t s[MAX_PATH], d[MAX_PATH];
    join(s, act->path, e->name);
    join(d, act->path, newname);
    MoveFileW(s, d);
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
    wchar_t path[MAX_PATH]; join(path, act->path, e->name);

    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD sz = GetFileSize(h, NULL);
    if (sz == INVALID_FILE_SIZE) sz = 0;
    long cap = sz > (8u << 20) ? (8 << 20) : (long)sz;   /* cap 8 MB */
    free(g_view_buf); g_view_buf = malloc(cap + 1);
    DWORD rd = 0;
    if (g_view_buf && cap) ReadFile(h, g_view_buf, cap, &rd, NULL);
    CloseHandle(h);
    g_view_len = rd;
    if (g_view_buf) g_view_buf[g_view_len] = 0;

    /* build line table */
    free(g_view_line);
    g_view_line = malloc(sizeof(long) * (g_view_len / 8 + 8));
    g_view_nlines = 0;
    g_view_line[g_view_nlines++] = 0;
    for (long i = 0; i < g_view_len; i++)
        if (g_view_buf[i] == '\n' && i + 1 <= g_view_len)
            g_view_line[g_view_nlines++] = i + 1;

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
        if (e->is_dir) wcscpy(sz, L"<DIR>");
        else _snwprintf(sz, 16, L"%llu", e->size);
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
    _snwprintf(hdr, MAXCOLS, L" View: %s   (%ld bytes, %d lines)",
               g_view_name, g_view_len, g_view_nlines);
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
        int w = 50, h = 5, x = (g_cols - w) / 2, y = (g_rows - h) / 2;
        fill(x, y, w, h, L' ', A_HDR);
        box(x, y, w, h, A_HDR);
        puts_at(x + 2, y, g_in_title, A_HDR);
        fill(x + 2, y + 2, w - 4, 1, L' ', A_NORM);
        puts_at(x + 2, y + 2, g_in_buf, A_NORM);
        cell(x + 2 + g_in_len, y + 2, L'_', A_NORM);
    }
    if (g_cf_active) {
        int w = 50, h = 5, x = (g_cols - w) / 2, y = (g_rows - h) / 2;
        fill(x, y, w, h, L' ', A_HDR);
        box(x, y, w, h, A_HDR);
        puts_at(x + 2, y + 1, g_cf_msg, A_HDR);
        puts_at(x + 2, y + 3, L"[Y] Yes    [N] No", A_HDR);
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
            _snwprintf(st, MAXCOLS, L" search: %s_", g_qs);
        else {
            const wchar_t *nm = act->count ? act->items[act->cur].name : L"";
            _snwprintf(st, MAXCOLS, L" %s   %d item(s)   sort:%S  theme:%S",
                       nm, act->count, SORTNAME[act->sortmode], THEMES[g_theme].name);
        }
        puts_at(0, g_rows - 2, st, A_STAT);
    }

    /* F-key bar */
    static const wchar_t *fk[10] = {
        L"Help", L"Menu", L"View", L"Edit", L"Copy",
        L"Move", L"MkDir", L"Del", L"PullDn", L"Quit"
    };
    fill(0, g_rows - 1, g_cols, 1, L' ', A_FKEY);
    int x = 0;
    for (int i = 0; i < 10; i++) {
        wchar_t num[4]; _snwprintf(num, 4, L"%d", i + 1);
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
    wchar_t path[MAX_PATH]; join(path, act->path, e->name);

    const wchar_t *ed = _wgetenv(L"EDITOR");
    wchar_t cmd[MAX_PATH * 2];
    if (ed && ed[0]) _snwprintf(cmd, MAX_PATH * 2, L"\"%s\" \"%s\"", ed, path);
    else             _snwprintf(cmd, MAX_PATH * 2, L"notepad.exe \"%s\"", path);

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {0};
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, act->path, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
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
    case ACT_COPY:   op_copy(0); break;
    case ACT_MOVE:   op_copy(1); break;
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
                else go_child(act, e->name);
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
    return ACT_NONE;
}

static void mb2w(const char *s, wchar_t *w, int cap)
{
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, cap);
}

/* headless replay: handles arg-carrying tokens (MKDIR:name, REN:name) too */
static void apply_token(const char *t)
{
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
        if (ch == L'y' || ch == L'Y') { g_cf_active = 0; if (g_cf_kind == 1) do_action(ACT_DELETE); }
        else if (ch == L'n' || ch == L'N' || k->wVirtualKeyCode == VK_ESCAPE) { g_cf_active = 0; }
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
        GetConsoleScreenBufferInfo(hOut, &bi);
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
        if (!ReadConsoleInput(hIn, &ir, 1, &nr) || nr == 0) continue;
        if (ir.EventType == WINDOW_BUFFER_SIZE_EVENT) continue;  /* re-render at new size */
        if (ir.EventType == KEY_EVENT && ir.Event.KeyEvent.bKeyDown) {
            const KEY_EVENT_RECORD *ke = &ir.Event.KeyEvent;
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
                int n = 0;
                for (int i = 0; i < act->count; i++)
                    if (act->items[i].tagged && wcscmp(act->items[i].name, L"..")) n++;
                if (n == 0 && act->count && wcscmp(act->items[act->cur].name, L"..")) n = 1;
                if (n > 0) {
                    g_cf_active = 1; g_cf_kind = 1;
                    _snwprintf(g_cf_msg, MAXCOLS, L"Delete %d item(s)?", n);
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
    FILE *fp = fopen(f, "w");
    if (!fp) return;
    char path[MAX_PATH * 2];
    int n = WideCharToMultiByte(CP_ACP, 0, act->path, -1,
                                path, sizeof(path), NULL, NULL);
    if (n > 0) fputs(path, fp);
    fclose(fp);
}

static void set_path_arg(Panel *p, const char *a)
{
    wchar_t w[MAX_PATH];
    MultiByteToWideChar(CP_ACP, 0, a, -1, w, MAX_PATH);
    /* turn it absolute */
    GetFullPathNameW(w, MAX_PATH, p->path, NULL);
    /* strip a trailing backslash unless it's a drive root */
    size_t n = wcslen(p->path);
    if (n > 3 && p->path[n - 1] == L'\\') p->path[n - 1] = 0;
}

int main(int argc, char **argv)
{
    apply_theme(0);

    /* defaults: both panels = current directory */
    GetCurrentDirectoryW(MAX_PATH, L.path);
    wcscpy(R.path, L.path);

    const char *dumpfile = NULL, *keysfile = NULL, *attrfile = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir")  && i + 1 < argc) set_path_arg(&L, argv[++i]);
        else if (!strcmp(argv[i], "--rdir") && i + 1 < argc) set_path_arg(&R, argv[++i]);
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

    run_live();
    write_exit_cwd();
    return 0;
}
