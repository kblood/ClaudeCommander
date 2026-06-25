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

#define COLS 80
#define ROWS 25
#define PANEL_W 40
#define LIST_Y0 1            /* first file row inside a panel box */
#define VIS 21               /* visible file rows per panel       */

/* ---- attribute palette (same low-nibble fg / high-nibble bg as VGA text) -- */
#define A_NORM  0x17         /* light grey on blue   */
#define A_DIR   0x1F         /* bright white on blue  */
#define A_TAG   0x1E         /* yellow on blue        */
#define A_CUR   0x30         /* black on cyan (cursor bar) */
#define A_CURT  0x3E         /* yellow on cyan (tagged under cursor) */
#define A_FRAME 0x17
#define A_HDR   0x1F
#define A_STAT  0x17
#define A_FKEY  0x30
#define A_FKNUM 0x07

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
} Panel;

static CHAR_INFO scr[ROWS * COLS];
static Panel L, R;
static Panel *act = &L;

/* ---------------------------------------------------------------- framebuffer */
static void cell(int x, int y, wchar_t ch, WORD at)
{
    if (x < 0 || x >= COLS || y < 0 || y >= ROWS) return;
    CHAR_INFO *c = &scr[y * COLS + x];
    c->Char.UnicodeChar = ch;
    c->Attributes = at;
}
static void puts_at(int x, int y, const wchar_t *s, WORD at)
{
    for (; *s && x < COLS; s++, x++) cell(x, y, *s, at);
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
static int ent_cmp(const void *a, const void *b)
{
    const Entry *x = a, *y = b;
    int xdd = (wcscmp(x->name, L"..") == 0);
    int ydd = (wcscmp(y->name, L"..") == 0);
    if (xdd != ydd) return ydd - xdd;            /* ".." first */
    if (x->is_dir != y->is_dir) return y->is_dir - x->is_dir;  /* dirs first */
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

/* ---------------------------------------------------------------- rendering */
static void render_panel(Panel *p, int px, int active)
{
    box(px, 0, PANEL_W, 23, A_FRAME);

    /* path on the top border */
    wchar_t hdr[PANEL_W];
    _snwprintf(hdr, PANEL_W - 4, L" %s ", p->path);
    puts_at(px + 2, 0, hdr, A_HDR);

    for (int i = 0; i < VIS; i++) {
        int y = LIST_Y0 + i;
        int idx = p->top + i;
        if (idx >= p->count) { fill(px + 1, y, PANEL_W - 2, 1, L' ', A_NORM); continue; }
        Entry *e = &p->items[idx];

        WORD at = e->is_dir ? A_DIR : A_NORM;
        if (e->tagged) at = A_TAG;
        if (active && idx == p->cur) at = e->tagged ? A_CURT : A_CUR;

        fill(px + 1, y, PANEL_W - 2, 1, L' ', at);

        wchar_t nm[32];
        _snwprintf(nm, 30, L"%s", e->name);
        nm[29] = 0;
        puts_at(px + 1, y, nm, at);

        wchar_t sz[16];
        if (e->is_dir) wcscpy(sz, L"<DIR>");
        else _snwprintf(sz, 16, L"%llu", e->size);
        int slen = (int)wcslen(sz);
        puts_at(px + (PANEL_W - 1) - slen, y, sz, at);
    }
}

static void compose_frame(void)
{
    fill(0, 0, COLS, ROWS, L' ', A_NORM);
    render_panel(&L, 0, act == &L);
    render_panel(&R, PANEL_W, act == &R);

    /* status row */
    fill(0, 23, COLS, 1, L' ', A_STAT);
    if (act->count) {
        Entry *e = &act->items[act->cur];
        wchar_t st[COLS];
        _snwprintf(st, COLS, L" %s   %d item(s)", e->name, act->count);
        puts_at(0, 23, st, A_STAT);
    }

    /* F-key bar */
    static const wchar_t *fk[10] = {
        L"Help", L"Menu", L"View", L"Edit", L"Copy",
        L"Move", L"MkDir", L"Del", L"PullDn", L"Quit"
    };
    fill(0, 24, COLS, 1, L' ', A_FKEY);
    int x = 0;
    for (int i = 0; i < 10; i++) {
        wchar_t num[4]; _snwprintf(num, 4, L"%d", i + 1);
        puts_at(x, 24, num, A_FKNUM); x += (int)wcslen(num);
        puts_at(x, 24, fk[i], A_FKEY); x += (int)wcslen(fk[i]) + 1;
    }
}

/* ---------------------------------------------------------------- actions */
enum { ACT_NONE, ACT_UP, ACT_DOWN, ACT_PGUP, ACT_PGDN, ACT_HOME, ACT_END,
       ACT_ENTER, ACT_TAB, ACT_TAG, ACT_QUIT };

static void clamp_panel(Panel *p)
{
    if (p->cur < 0) p->cur = 0;
    if (p->cur >= p->count) p->cur = p->count - 1;
    if (p->cur < 0) p->cur = 0;
    if (p->cur < p->top) p->top = p->cur;
    if (p->cur >= p->top + VIS) p->top = p->cur - VIS + 1;
    if (p->top < 0) p->top = 0;
}

/* returns 1 to quit */
static int do_action(int a)
{
    switch (a) {
    case ACT_UP:   act->cur--; break;
    case ACT_DOWN: act->cur++; break;
    case ACT_PGUP: act->cur -= VIS - 1; break;
    case ACT_PGDN: act->cur += VIS - 1; break;
    case ACT_HOME: act->cur = 0; break;
    case ACT_END:  act->cur = act->count - 1; break;
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
    for (int y = 0; y < ROWS; y++) {
        wchar_t line[COLS + 1];
        for (int x = 0; x < COLS; x++) {
            wchar_t ch = scr[y * COLS + x].Char.UnicodeChar;
            line[x] = ch ? ch : L' ';
        }
        line[COLS] = 0;
        char utf8[COLS * 4 + 1];
        int n = WideCharToMultiByte(CP_UTF8, 0, line, COLS, utf8, sizeof(utf8) - 1, NULL, NULL);
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
    for (int y = 0; y < ROWS; y++) {
        for (int x = 0; x < COLS; x++)
            fprintf(f, "%02x ", scr[y * COLS + x].Attributes & 0xFF);
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
    return ACT_NONE;
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
    }
    return ACT_NONE;
}

static void run_live(void)
{
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE hIn  = GetStdHandle(STD_INPUT_HANDLE);

    DWORD inMode = 0; GetConsoleMode(hIn, &inMode);
    CONSOLE_SCREEN_BUFFER_INFO saved; GetConsoleScreenBufferInfo(hOut, &saved);
    CONSOLE_CURSOR_INFO ci; GetConsoleCursorInfo(hOut, &ci);
    CONSOLE_CURSOR_INFO hide = ci; hide.bVisible = FALSE;

    SetConsoleMode(hIn, ENABLE_EXTENDED_FLAGS);   /* raw: no line/echo/quickedit */
    SetConsoleCursorInfo(hOut, &hide);

    SMALL_RECT minr = {0, 0, 1, 1};
    SetConsoleWindowInfo(hOut, TRUE, &minr);
    COORD sz = {COLS, ROWS};
    SetConsoleScreenBufferSize(hOut, sz);
    SMALL_RECT full = {0, 0, COLS - 1, ROWS - 1};
    SetConsoleWindowInfo(hOut, TRUE, &full);

    int quit = 0;
    while (!quit) {
        compose_frame();
        COORD bufsz = {COLS, ROWS}, org = {0, 0};
        SMALL_RECT reg = {0, 0, COLS - 1, ROWS - 1};
        WriteConsoleOutputW(hOut, scr, bufsz, org, &reg);

        INPUT_RECORD ir;
        DWORD nr = 0;
        if (!ReadConsoleInput(hIn, &ir, 1, &nr) || nr == 0) continue;
        if (ir.EventType == KEY_EVENT && ir.Event.KeyEvent.bKeyDown) {
            int a = key_to_action(&ir.Event.KeyEvent);
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
    }

    read_dir(&L);
    read_dir(&R);

    if (dumpfile || attrfile) {
        if (keysfile) {
            FILE *kf = fopen(keysfile, "r");
            if (kf) {
                char tok[64];
                while (fscanf(kf, "%63s", tok) == 1) {
                    int a = token_action(tok);
                    if (a != ACT_NONE) do_action(a);
                }
                fclose(kf);
            }
        }
        compose_frame();
        if (dumpfile) dump_frame(dumpfile);
        if (attrfile) dump_attr(attrfile);
        return 0;
    }

    run_live();
    return 0;
}
