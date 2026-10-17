#!/usr/bin/env python3
"""LLM Monitor top-bar indicator for Linux desktops (#246).

A thin AppIndicator (StatusNotifierItem) client over the headless daemon's
~/.llm-monitor/ranking.json. It reads only that non-secret export — never
tokens, never usage.db — and never polls a provider itself: the daemon stays
the single poller, the tray only renders what it last wrote.

On Ubuntu's default GNOME session the `ubuntu-appindicators` extension shows
it in the top bar; KDE and other SNI hosts show it natively.

    llm-monitor-tray.py            # run the indicator
    llm-monitor-tray.py --print    # print the summary once and exit (no GTK)

Requires python3-gi and gir1.2-ayatanaappindicator3-0.1 (stock Ubuntu).
"""

import argparse
import fcntl
import json
import os
import sys
from datetime import datetime, timezone

RANKING_PATH = os.path.expanduser(
    os.environ.get("LLM_MONITOR_RANKING", "~/.llm-monitor/ranking.json")
)
# Same thresholds as the macOS status item: orange at 90 %, red above 95 %.
WARN_PCT = 90
CRIT_PCT = 95
# The daemon writes ranking.json after every poll cycle (10 min by default);
# two missed cycles plus slack means the daemon is not running.
STALE_SECONDS = 25 * 60
REFRESH_SECONDS = 60
USAGE_URLS = {
    "anthropic": "https://claude.ai/settings/usage",
}
PROVIDER_TAGS = {"anthropic": "Claude", "openai": "Codex", "zai": "z.ai"}


# --- pure model (no GTK; covered by --selftest) ----------------------------

def parse_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def load_ranking(path=RANKING_PATH):
    """Return (document, error). Never raises."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except FileNotFoundError:
        return None, "no ranking.json — is the llm-monitor daemon running?"
    except (OSError, ValueError) as e:
        return None, f"cannot read ranking.json: {e}"
    if not isinstance(doc, dict) or not isinstance(doc.get("accounts"), list):
        return None, "ranking.json has no accounts list"
    return doc, None


def peak_pct(account):
    """Highest window utilization as a percent, or None when none reported."""
    util = account.get("utilization") or {}
    vals = [v for v in util.values() if isinstance(v, (int, float))]
    return round(max(vals) * 100) if vals else None


def usable(account):
    return not account.get("absent") and account.get("status") != "blocked"


def headline(accounts):
    """The account that drives the top-bar label: most headroom wins.

    Mirrors the macOS auto-pick (most-available). Accounts with no reading
    are skipped; if nothing has a reading, there is no headline.
    """
    scored = [(peak_pct(a), a) for a in accounts if usable(a)]
    scored = [(p, a) for p, a in scored if p is not None]
    if not scored:
        return None
    return min(scored, key=lambda pa: pa[0])[1]


def severity(pct):
    if pct is None:
        return "idle"
    if pct > CRIT_PCT:
        return "crit"
    if pct >= WARN_PCT:
        return "warn"
    return "ok"


def fmt_pct(account, window):
    v = (account.get("utilization") or {}).get(window)
    return f"{round(v * 100)}%" if isinstance(v, (int, float)) else "—"


def fmt_delta(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "now"
    m = seconds // 60
    if m < 60:
        return f"{m}m"
    h, m = divmod(m, 60)
    if h < 48:
        return f"{h}h{m:02d}m" if m else f"{h}h"
    return f"{h // 24}d{h % 24}h"


def fmt_reset(account, window, now):
    t = parse_time((account.get("resets") or {}).get(window))
    if t is None:
        return ""
    return f" ↻{fmt_delta(max(0, (t - now).total_seconds()))}"


def account_name(account):
    return account.get("email") or account.get("label") or "?"


def account_line(account, now):
    tag = PROVIDER_TAGS.get(account.get("provider"), account.get("provider", "?"))
    name = account_name(account)
    if not usable(account):
        why = "absent" if account.get("absent") else account.get("status", "blocked")
        return f"{tag}  {name}  ({why})"
    parts = [
        f"5h {fmt_pct(account, '5h')}{fmt_reset(account, '5h', now)}",
        f"7d {fmt_pct(account, '7d')}{fmt_reset(account, '7d', now)}",
    ]
    status = account.get("status")
    suffix = f"  [{status}]" if status and status != "available" else ""
    return f"{tag}  {name}   " + "   ".join(parts) + suffix


def summarize(doc, error, now=None):
    """Everything the UI shows, as plain data."""
    now = now or datetime.now(timezone.utc)
    if error:
        return {"label": "—", "severity": "idle", "lines": [], "footer": error}
    accounts = doc["accounts"]
    head = headline(accounts)
    pct = peak_pct(head) if head else None
    generated = parse_time(doc.get("generated_at"))
    age = (now - generated).total_seconds() if generated else None
    if age is None:
        footer = "last update: unknown"
    else:
        delta = fmt_delta(max(0, age))
        footer = "updated just now" if delta == "now" else f"updated {delta} ago"
        if age > STALE_SECONDS:
            footer += " — stale, is the daemon running?"
    ordered = sorted(
        accounts,
        key=lambda a: (not usable(a), peak_pct(a) is None, peak_pct(a) or 0),
    )
    return {
        "label": f"{pct}%" if pct is not None else "—",
        "severity": "stale" if age is not None and age > STALE_SECONDS else severity(pct),
        "lines": [account_line(a, now) for a in ordered],
        "footer": footer,
        "providers": sorted({a.get("provider") for a in accounts if a.get("provider")}),
    }


# --- icons -----------------------------------------------------------------

ICON_COLORS = {
    "ok": "#4caf50",
    "warn": "#ff9800",
    "crit": "#f44336",
    "stale": "#9e9e9e",
    "idle": "#9e9e9e",
}


def write_icons(directory):
    """Write one small gauge SVG per severity; return the directory."""
    os.makedirs(directory, exist_ok=True)
    for sev, color in ICON_COLORS.items():
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">'
            f'<rect x="3" y="12" width="4" height="7" rx="1" fill="{color}"/>'
            f'<rect x="9" y="8" width="4" height="11" rx="1" fill="{color}"/>'
            f'<rect x="15" y="3" width="4" height="16" rx="1" fill="{color}"/>'
            "</svg>"
        )
        path = os.path.join(directory, f"llm-monitor-{sev}.svg")
        try:
            with open(path, encoding="utf-8") as f:
                if f.read() == svg:
                    continue
        except OSError:
            pass
        with open(path, "w", encoding="utf-8") as f:
            f.write(svg)
    return directory


# --- GTK indicator -----------------------------------------------------------

def single_instance_lock():
    """Hold an exclusive lock for the process lifetime; None if already held."""
    runtime = os.environ.get("XDG_RUNTIME_DIR") or os.path.expanduser("~/.llm-monitor")
    os.makedirs(runtime, exist_ok=True)
    f = open(os.path.join(runtime, "llm-monitor-tray.lock"), "w")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.close()
        return None
    return f


def run_indicator():
    lock = single_instance_lock()
    if lock is None:
        print("llm-monitor-tray: already running", file=sys.stderr)
        return
    import gi

    gi.require_version("Gtk", "3.0")
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3 as AppIndicator
    except (ValueError, ImportError):
        try:
            gi.require_version("AppIndicator3", "0.1")
            from gi.repository import AppIndicator3 as AppIndicator
        except (ValueError, ImportError):
            sys.exit(
                "llm-monitor-tray: no AppIndicator library. Install it with:\n"
                "  sudo apt install gir1.2-ayatanaappindicator3-0.1"
            )
    from gi.repository import Gio, GLib, Gtk

    icon_dir = write_icons(
        os.path.join(
            os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
            "llm-monitor-tray",
        )
    )
    ind = AppIndicator.Indicator.new(
        "llm-monitor",
        "llm-monitor-idle",
        AppIndicator.IndicatorCategory.APPLICATION_STATUS,
    )
    ind.set_icon_theme_path(icon_dir)
    ind.set_title("LLM Monitor")

    def open_url(_item, url):
        Gio.AppInfo.launch_default_for_uri(url, None)

    def refresh(*_args):
        doc, error = load_ranking()
        s = summarize(doc, error)
        ind.set_icon_full(f"llm-monitor-{s['severity']}", s["label"])
        # The guide string reserves width so the bar doesn't jitter.
        ind.set_label(s["label"], "100%")

        menu = Gtk.Menu()
        for line in s["lines"] or ["No accounts in ranking.json"]:
            item = Gtk.MenuItem(label=line)
            item.set_sensitive(False)
            menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        footer = Gtk.MenuItem(label=s["footer"])
        footer.set_sensitive(False)
        menu.append(footer)
        for provider in s.get("providers", []):
            if provider in USAGE_URLS:
                tag = PROVIDER_TAGS.get(provider, provider)
                item = Gtk.MenuItem(label=f"Open {tag} usage page")
                item.connect("activate", open_url, USAGE_URLS[provider])
                menu.append(item)
        refresh_item = Gtk.MenuItem(label="Refresh")
        refresh_item.connect("activate", refresh)
        menu.append(refresh_item)
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        menu.append(quit_item)
        menu.show_all()
        ind.set_menu(menu)
        return True  # keep the GLib timeout alive

    # ranking.json is replaced atomically (rename), so watch the directory.
    monitor = Gio.File.new_for_path(os.path.dirname(RANKING_PATH)).monitor_directory(
        Gio.FileMonitorFlags.WATCH_MOVES, None
    )

    def on_change(_mon, file, other, _event):
        names = {f.get_basename() for f in (file, other) if f is not None}
        if os.path.basename(RANKING_PATH) in names:
            refresh()

    monitor.connect("changed", on_change)
    refresh()
    ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)

    # GNOME's ubuntu-appindicators extension ignores the label an item
    # registers with and draws it only after a later label change (checked on
    # Ubuntu 24.04: a change 4 s after start shows; one inside the first
    # second, or a clear-and-set in the same main-loop turn, does not). So
    # once the item has settled, clear the label and set it again in
    # separate turns.
    def clear_label():
        ind.set_label("", "100%")
        return False

    def restore_label():
        refresh()
        return False

    GLib.timeout_add(3000, clear_label)
    GLib.timeout_add(3500, restore_label)
    GLib.timeout_add_seconds(REFRESH_SECONDS, refresh)
    Gtk.main()


# --- self-test -------------------------------------------------------------

def selftest():
    now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    doc = {
        "schema": 1,
        "generated_at": "2026-01-01T11:55:00Z",
        "accounts": [
            {"email": "a@x", "provider": "anthropic", "status": "available",
             "utilization": {"5h": 0.91, "7d": 0.40},
             "resets": {"5h": "2026-01-01T13:30:00Z"}},
            {"email": "z@x", "provider": "zai", "status": "available",
             "utilization": {"5h": 0.10, "7d": 0.35}},
            {"email": "o@x", "provider": "openai", "status": "available",
             "utilization": {"7d": 0.20}},
            {"email": "gone@x", "provider": "openai", "status": "blocked", "absent": True},
        ],
    }
    s = summarize(doc, None, now)
    checks = [
        (s["label"] == "20%", f"headline picks most headroom: {s['label']}"),
        (s["severity"] == "ok", f"severity ok: {s['severity']}"),
        ("5h —" in s["lines"][0], f"missing window shows —: {s['lines'][0]}"),
        ("z.ai" in s["lines"][1], f"zai row tagged: {s['lines'][1]}"),
        ("↻1h30m" in s["lines"][2], f"reset delta: {s['lines'][2]}"),
        ("(absent)" in s["lines"][-1], f"absent last: {s['lines'][-1]}"),
        (s["footer"] == "updated 5m ago", f"footer: {s['footer']}"),
        (severity(90) == "warn" and severity(96) == "crit", "thresholds"),
        (summarize(None, "boom", now)["label"] == "—", "error state"),
        (summarize({**doc, "generated_at": "2026-01-01T12:00:00Z"}, None, now)["footer"]
         == "updated just now", "fresh footer"),
        (summarize({**doc, "generated_at": "2026-01-01T10:00:00Z"}, None, now)["severity"]
         == "stale", "stale state"),
    ]
    failed = [msg for ok, msg in checks if not ok]
    for msg in failed:
        print("FAIL", msg)
    print(f"{len(checks) - len(failed)}/{len(checks)} passed")
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--print", action="store_true", help="print the summary once and exit")
    ap.add_argument("--selftest", action="store_true", help="run the built-in checks")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.print:
        doc, error = load_ranking()
        s = summarize(doc, error)
        print(f"[{s['severity']}] {s['label']}")
        for line in s["lines"]:
            print("  " + line)
        print(s["footer"])
        return 0 if error is None else 1
    run_indicator()
    return 0


if __name__ == "__main__":
    sys.exit(main())
