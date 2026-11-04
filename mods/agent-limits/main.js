// Usage limits of the coding agents on this computer, one line per agent, under the Agents list.
// limits.sh beside this file reads them: Claude's statusline cache and Codex's session logs.
// Agents running now are drawn in full; the others are dimmed.

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, exec, appHome, theme, layout, readTextFile, writeTextFile } from "herdr";

const ICON = { claude: "icons/claude.svg", codex: "icons/codex.svg", kimi: "icons/kimi.svg", grok: "icons/grok.svg" };
const KIND = { "claude-code": "claude", claude: "claude", codex: "codex", kimi: "kimi", "kimi-code": "kimi", grok: "grok" };
const WARN = 70;
const CRIT = 90;
// Stepped gradient: one colour per 10% band, green -> yellow -> red.
const band = (pct) => {
  const p = Math.max(0, Math.min(100, Math.floor(pct / 10) * 10));
  const h = Math.round(120 * (1 - p / 100));
  const f = (n) => {
    const k = (n + h / 30) % 12;
    const v = 0.65 - 0.35 * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return Math.round(255 * v).toString(16).padStart(2, "0");
  };
  return `#${f(0)}${f(8)}${f(4)}`;
};
const DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const CELL = 78;

const isShort = (w) => (w.minutes ?? (w.label.endsWith("h") ? 300 : 10080)) < 1440;

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// Same rule as the agents mod: the sidebar is a rail below 160 px.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

const pad = (n) => String(n).padStart(2, "0");

function resetText(w) {
  if (w.resets_at == null) return "";
  const d = new Date(w.resets_at * 1000);
  const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  if (isShort(w)) return time;
  if ((w.minutes ?? 0) > 10080) return `${d.getMonth() + 1}/${d.getDate()} ${time}`;
  return `${DAYS[d.getDay()]} ${time}`;
}

function ago(seconds) {
  const m = Math.floor(seconds / 60);
  if (m < 1) return "just now";
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h ago` : `${Math.floor(h / 24)}d ago`;
}

export default class AgentLimits extends View {
  init(_props, cx) {
    this.limits = [];
    this.error = null;
    this.liveError = null;
    this.fetching = false;
    this.paused = false;
    this.pauseSaved = null;
    this.hidden = new Set();
    this.hiddenSaved = null;
    this.menuOpen = false;
    this.seq = 0;
    this.applied = 0;
    // Local data shows at once and every 30 s (agents update it as they work); the servers
    // are asked at start, every 5 minutes, and from the refresh button. While paused, the
    // timers keep ticking but skip every fetch; the toggle survives restarts.
    this.pauseFile = `${appHome()}/data/agent-limits-paused.json`;
    this.filterFile = `${appHome()}/data/agent-limits-hidden.json`;
    cx.spawn(async (cx) => {
      try {
        const text = await readTextFile(this.pauseFile);
        this.paused = text != null && JSON.parse(text)?.paused === true;
      } catch { /* no saved state yet */ }
      try {
        const text = await readTextFile(this.filterFile);
        if (text != null) this.hidden = new Set(JSON.parse(text)?.hidden ?? []);
      } catch { /* no saved state yet */ }
      this.refresh(cx);
      this.refresh(cx, true);
      cx.notify();
    });
    cx.timer.every(30000, (cx) => this.refresh(cx));
    cx.timer.every(5 * 60 * 1000, (cx) => this.refresh(cx, true));
  }

  togglePause(cx) {
    this.paused = !this.paused;
    const text = JSON.stringify({ paused: this.paused });
    cx.spawn(async (cx) => {
      try { await writeTextFile(this.pauseFile, text, this.pauseSaved); this.pauseSaved = text; } catch { /* keep the in-memory state */ }
      cx.notify();
    });
    if (!this.paused) { this.refresh(cx); this.refresh(cx, true); }
    cx.notify();
  }

  toggleAgent(agent, cx) {
    if (this.hidden.has(agent)) this.hidden.delete(agent); else this.hidden.add(agent);
    const text = JSON.stringify({ hidden: [...this.hidden] });
    cx.spawn(async (cx) => {
      try { await writeTextFile(this.filterFile, text, this.hiddenSaved); this.hiddenSaved = text; } catch { /* keep the in-memory state */ }
      cx.notify();
    });
    cx.notify();
  }

  // live: ask Claude's and Codex's servers first (the refresh button); otherwise read local data.
  refresh(cx, live = false, force = false) {
    if (this.paused && !force) return;
    if (live && this.fetching) return;
    if (live) this.fetching = true;
    const seq = ++this.seq;
    cx.spawn(async (cx) => {
      let error = null;
      try {
        const shown = Object.keys(ICON).filter((a) => !this.hidden.has(a));
        const args = [`${appHome()}/mods/agent-limits/limits.sh`, ...(live ? ["--live"] : []), ...shown];
        const r = await exec("sh", args);
        if (r.code !== 0) throw new Error(r.stderr.trim() || `limits.sh exited ${r.code}`);
        // A server answer is the newest data there is; a local read that started before
        // another applied run must not put older numbers back.
        if (live || seq > this.applied) {
          this.limits = JSON.parse(r.stdout || "[]");
          this.applied = Math.max(this.applied, seq);
        }
        error = r.stderr.trim() || null;
      } catch (e) {
        error = String(e?.message ?? e);
      }
      if (live) {
        this.liveError = error;
        this.fetching = false;
      } else {
        this.error = error;
      }
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const now = Date.now() / 1000;
    const running = new Set(agents().map((a) => KIND[a.app] ?? KIND[a.program?.key]).filter(Boolean));
    const color = (pct) => band(pct);
    // A window whose reset time has passed starts again from zero.
    const rows = this.limits.map((r) => ({
      ...r,
      on: running.has(r.agent),
      windows: r.windows.map((w) => (w.resets_at != null && w.resets_at <= now ? { ...w, pct: 0 } : w)),
    }));
    const problem = [this.liveError, this.error].filter(Boolean).join("\n");
    // limits.sh prefixes each stderr line with the agent's name ("Claude: …"), so an
    // error can be shown on that agent's row instead of a shared "!" in the header.
    const errByAgent = {};
    for (const line of problem.split("\n")) {
      const m = /^(\w+):\s*(.+)$/.exec(line.trim());
      if (m) errByAgent[m[1].toLowerCase()] = m[2];
    }
    const pic = (r) => image(ICON[r.agent]).w(14).h(14).flex_none().when(!r.on, (el) => el.opacity(0.5));
    const visible = rows.filter((r) => !this.hidden.has(r.agent));

    if (narrow()) {
      return v_flex().size_full().bg(t.chrome).border_t(1).border_color(t.border).pt(10).gap(8).items_center().children(
        rows.map((r) => {
          const top = r.windows.length > 0 ? Math.max(...r.windows.map((w) => w.pct)) : null;
          return v_flex().id(`lim-${r.agent}`).items_center().gap(2)
            .child(pic(r))
            .child(div().text_size(10).text_color(color(top ?? 0) ?? t.dim).child(top == null ? "–" : `${Math.floor(top)}%`));
        }),
      );
    }

    // Every row has the same two slots, a short window (under a day, usually 5h) and a long one
    // (7d, 30d), so plans without one still line up; a missing window leaves its slot empty.
    const cell = (w, on) => {
      if (!w) return div().w(CELL).flex_none();
      const c = color(w.pct);
      const fill = Math.max(0, Math.min(100, w.pct));
      return h_flex().w(CELL).flex_none().gap(4).items_center()
        .child(div().w(22).whitespace_nowrap().text_size(11).text_color(t.dim).child(w.label))
        .child(div().w(20).h(4).rounded(2).bg(t.border)
          .child(div().h_full().w(Math.max(fill > 0 ? 2 : 0, (20 * fill) / 100)).rounded(2).bg(c ?? (on ? t.muted : t.dim))))
        .child(div().w(28).whitespace_nowrap().text_right().text_size(11.5)
          .text_color(c ?? (on ? t.muted : t.dim))
          .when(c != null, (el) => el.font_semibold())
          .child(`${Math.floor(w.pct)}%`));
    };

    const row = (r) => {
      const resets = r.windows.filter((w) => w.resets_at != null).map((w) => `${w.label} resets ${resetText(w)}`);
      const tip = [r.name, ...resets, r.updated_at ? `updated ${ago(now - r.updated_at)}` : null].filter(Boolean).join(" · ");
      return h_flex().id(`lim-${r.agent}`).px(8).h(28).flex_none().rounded(8).items_center().gap(6)
        .hover((s) => s.bg(t.hover))
        .tooltip(tip)
        .child(pic(r))
        .child(div().flex_1().min_w(0).truncate().text_color(r.on ? t.foreground : t.muted).child(r.name))
        .when(r.unlimited, (el) => el.child(div().flex_none().text_size(11.5).text_color(t.dim).child("No limit")))
        .when(!r.unlimited, (el) => el.child(h_flex().flex_none().gap(8)
          .child(cell(r.windows.find(isShort), r.on))
          .child(cell(r.windows.find((w) => !isShort(w)), r.on))))
        .when(errByAgent[r.agent], (el) => el.child(
          div().id(`lim-err-${r.agent}`).flex_none().text_size(11).font_semibold().text_color(t.blocked)
            .tooltip(errByAgent[r.agent])
            .child("Err")));
    };

    return v_flex().size_full().min_h(0).bg(t.chrome).border_t(1).border_color(t.border).text_size(12.5)
      .child(h_flex().px(16).h(41).pt(14).pb(5).flex_none().items_center().justify_between()
        .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Limits"))
        .child(h_flex().gap(8).items_center()
          .child(div()
            .id("lim-pause")
            .text_size(11)
            .px(6).rounded(6)
            .text_color(this.paused ? t.accent : t.dim)
            .when(this.paused, (el) => el.bg(t.selected))
            .hover((s) => s.bg(t.hover))
            .on_click((_e, cx) => this.togglePause(cx))
            .tooltip(this.paused ? "Auto-refresh paused — click to resume" : "Pause auto-refresh")
            .child(this.paused ? "▶" : "⏸"))
          .child(div()
            .id("lim-filter")
            .text_size(11)
            .px(6).rounded(6)
            .text_color(this.menuOpen || this.hidden.size > 0 ? t.accent : t.dim)
            .when(this.menuOpen || this.hidden.size > 0, (el) => el.bg(t.selected))
            .hover((s) => s.bg(t.hover))
            .on_click((_e, cx) => { this.menuOpen = !this.menuOpen; cx.notify(); })
            .tooltip("Choose which agents to show")
            .child("⚙"))
          .child(div()
            .id("lim-refresh")
            .text_color(t.dim)
            .hover((s) => s.text_color(t.foreground))
            .on_click((_e, cx) => this.refresh(cx, true, true))
            .tooltip("Fetch usage from Claude, Codex, Kimi and Grok")
            .child(svg("mods/agent-limits/refresh.svg").size(14)))))
      .when(rows.length === 0, (el) => el.child(div().px(16).text_size(12).text_color(t.dim).child("No limit data yet.")))
      .when(this.menuOpen, (el) => el.child(
        v_flex().id("lim-menu").mx(8).mb(6).flex_none().rounded(8).border(1).border_color(t.border).bg(t.raised).py(4)
          .child(...Object.entries(ICON).map(([agent, icon]) => {
            const known = rows.find((r) => r.agent === agent);
            const name = known?.name ?? agent[0].toUpperCase() + agent.slice(1);
            const shown = !this.hidden.has(agent);
            return h_flex().id(`lim-menu-${agent}`).px(10).h(26).gap(8).items_center().cursor_pointer()
              .hover((s) => s.bg(t.hover))
              .on_click((_e, cx) => this.toggleAgent(agent, cx))
              .child(image(icon).w(14).h(14).flex_none().when(!known, (i) => i.opacity(0.4)))
              .child(div().flex_1().min_w(0).truncate().text_size(12).text_color(shown ? t.foreground : t.dim).child(name))
              .child(div().w(14).text_size(12).text_right().text_color(shown ? t.accent : t.dim).child(shown ? "☑" : "☐"));
          }))))
      .child(v_flex().px(8).children(visible.map(row)));
  }
}
