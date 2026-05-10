/* global settings */
import Component from "@glimmer/component";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";

const ACTIVITY_EVENTS = [
  "pointermove",
  "pointerdown",
  "keydown",
  "touchstart",
  "wheel",
  "scroll",
];

const MODES = ["grid", "spiral", "sorting", "slots"];
const CYCLE_MS = 22000;
const MAX_GLYPHS = 1100;

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function smoothstep(edge0, edge1, value) {
  const t = clamp((value - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
}

function parseRgb(value, fallback) {
  const numbers = (value || "")
    .match(/[\d.]+/g)
    ?.map((part) => Number.parseFloat(part))
    .filter((number) => Number.isFinite(number));

  if (numbers?.length >= 3) {
    return numbers.slice(0, 3);
  }

  return fallback;
}

function parseVisibleRgb(value) {
  const numbers = (value || "")
    .match(/[\d.]+/g)
    ?.map((part) => Number.parseFloat(part))
    .filter((number) => Number.isFinite(number));

  if (!numbers || numbers.length < 3 || numbers[3] === 0) {
    return null;
  }

  return numbers.slice(0, 3);
}

function mixRgb(from, to, amount) {
  return from.map((channel, index) =>
    Math.round(channel + (to[index] - channel) * amount)
  );
}

function relativeLuminance(rgb) {
  const [red, green, blue] = rgb.map((channel) => {
    const normalized = channel / 255;
    return normalized <= 0.03928
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4;
  });

  return red * 0.2126 + green * 0.7152 + blue * 0.0722;
}

function rgbString(rgb, alpha) {
  return `rgba(${rgb.join(", ")}, ${alpha})`;
}

function stripHtml(html) {
  const document = new DOMParser().parseFromString(html || "", "text/html");

  document
    .querySelectorAll("blockquote, pre, code, aside, script, style")
    .forEach((element) => element.remove());

  return [...document.querySelectorAll("p, li")]
    .map((element) => element.textContent.replace(/\s+/g, " ").trim())
    .filter(Boolean);
}

function topicListUrl(source) {
  if (source === "top_weekly") {
    return "/top.json?period=weekly";
  }

  if (source === "top_monthly") {
    return "/top.json?period=monthly";
  }

  return "/latest.json";
}

export default class TextJumbleScreenSaver extends Component {
  @service router;

  @tracked isVisible = false;
  @tracked sourceTitle = "";

  animationFrame = null;
  canvas = null;
  context = null;
  glyphs = [];
  idleTimer = null;
  paragraph = "";
  paragraphTimer = null;
  resizeObserver = null;
  root = null;
  stage = null;
  startedAt = 0;

  @action
  setup(element) {
    this.root = element;
    this.boundActivity = () => this.handleActivity();
    this.boundRouteChange = () => this.handleActivity();
    this.boundVisibilityChange = () => this.handleVisibilityChange();
    this.boundResize = () => this.resize();

    ACTIVITY_EVENTS.forEach((eventName) => {
      window.addEventListener(eventName, this.boundActivity, { passive: true });
    });
    document.addEventListener("visibilitychange", this.boundVisibilityChange);
    window.addEventListener("resize", this.boundResize, { passive: true });
    this.router.on("routeDidChange", this.boundRouteChange);

    this.scheduleIdle();
  }

  @action
  setupStage(element) {
    this.stage = element;
    this.resizeObserver = new ResizeObserver(() => this.resize());
    this.resizeObserver.observe(element);
    this.applyBackgroundPalette();
    this.resize();
  }

  @action
  setupCanvas(element) {
    this.canvas = element;
    this.context = element.getContext("2d", { alpha: true });
    this.startedAt = performance.now();
    this.resize();
    this.startAnimation();
  }

  @action
  teardownStage() {
    this.stopAnimation();
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.stage = null;
    this.canvas = null;
    this.context = null;
  }

  @action
  teardown() {
    this.stopAnimation();
    clearTimeout(this.idleTimer);
    clearTimeout(this.paragraphTimer);
    this.resizeObserver?.disconnect();

    ACTIVITY_EVENTS.forEach((eventName) => {
      window.removeEventListener(eventName, this.boundActivity);
    });
    document.removeEventListener(
      "visibilitychange",
      this.boundVisibilityChange
    );
    window.removeEventListener("resize", this.boundResize);
    this.router.off("routeDidChange", this.boundRouteChange);
  }

  async show() {
    this.isVisible = true;
    await this.loadParagraph();
    this.scheduleNextParagraph();
  }

  hide() {
    this.isVisible = false;
    clearTimeout(this.paragraphTimer);
    this.stopAnimation();
  }

  handleActivity() {
    if (this.isVisible) {
      this.hide();
    }

    this.scheduleIdle();
  }

  handleVisibilityChange() {
    if (document.hidden) {
      this.hide();
      clearTimeout(this.idleTimer);
    } else {
      this.scheduleIdle();
    }
  }

  scheduleIdle() {
    clearTimeout(this.idleTimer);

    if (document.hidden || !settings.text_jumble_enabled) {
      return;
    }

    const waitMs = settings.text_jumble_idle_seconds * 1000;
    this.idleTimer = setTimeout(() => this.show(), waitMs);
  }

  scheduleNextParagraph() {
    clearTimeout(this.paragraphTimer);

    if (!this.isVisible) {
      return;
    }

    const seconds = Math.max(settings.text_jumble_cycle_seconds, 10);
    this.paragraphTimer = setTimeout(async () => {
      await this.loadParagraph();
      this.scheduleNextParagraph();
    }, seconds * 1000);
  }

  async loadParagraph() {
    const fallbackText = settings.text_jumble_fallback_text;

    try {
      const list = await ajax(
        getURL(topicListUrl(settings.text_jumble_topic_source))
      );
      const topics = list?.topic_list?.topics || [];
      const candidates = topics.filter(
        (topic) => !topic.pinned && !topic.closed
      );
      const topic = candidates[Math.floor(Math.random() * candidates.length)];

      if (!topic) {
        throw new Error("No topics available");
      }

      const topicJson = await ajax(getURL(`/t/${topic.slug}/${topic.id}.json`));
      const posts = topicJson?.post_stream?.posts || [];
      const paragraphs = posts.flatMap((post) => stripHtml(post.cooked));
      const minLength = settings.text_jumble_min_paragraph_length;
      const paragraph =
        paragraphs.find((text) => text.length >= minLength) || paragraphs[0];

      if (!paragraph) {
        throw new Error("No usable paragraph found");
      }

      this.paragraph = paragraph;
      this.sourceTitle = topicJson.title || topic.title || "";
    } catch {
      this.paragraph = fallbackText;
      this.sourceTitle = "";
    }

    this.prepareGlyphs();
  }

  resize() {
    if (!this.canvas || !this.stage) {
      return;
    }

    this.applyBackgroundPalette();

    const rect = this.stage.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 1.75);
    this.canvas.width = Math.max(Math.floor(rect.width * ratio), 1);
    this.canvas.height = Math.max(Math.floor(rect.height * ratio), 1);
    this.canvas.style.width = `${rect.width}px`;
    this.canvas.style.height = `${rect.height}px`;

    this.prepareGlyphs();
  }

  prepareGlyphs() {
    if (!this.context || !this.canvas || !this.paragraph) {
      return;
    }

    const ctx = this.context;
    const width = this.canvas.width;
    const height = this.canvas.height;
    const fontSize = clamp(Math.round(width / 54), 18, 34);
    const lineHeight = Math.round(fontSize * 1.45);
    const maxTextWidth = width * 0.72;
    const words = this.paragraph.split(/\s+/).filter(Boolean);
    const lines = [];
    let line = "";

    ctx.font = `${fontSize}px Georgia, serif`;

    for (const word of words) {
      const nextLine = line ? `${line} ${word}` : word;

      if (ctx.measureText(nextLine).width > maxTextWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = nextLine;
      }

      if (lines.join(" ").length + line.length > MAX_GLYPHS) {
        break;
      }
    }

    if (line) {
      lines.push(line);
    }

    const totalHeight = lines.length * lineHeight;
    const startY = height / 2 - totalHeight / 2;
    const glyphs = [];

    lines.forEach((textLine, lineIndex) => {
      let x = width / 2 - ctx.measureText(textLine).width / 2;
      const y = startY + lineIndex * lineHeight;

      [...textLine].forEach((char, columnIndex) => {
        const charWidth = ctx.measureText(char).width;

        if (char !== " ") {
          glyphs.push({
            char,
            columnIndex,
            fontSize,
            index: glyphs.length,
            lineIndex,
            width: charWidth,
            x: x + charWidth / 2,
            y,
          });
        }

        x += charWidth;
      });
    });

    const sorted = [...glyphs].sort((a, b) => {
      const charCompare = a.char.localeCompare(b.char);
      return (
        charCompare ||
        a.lineIndex - b.lineIndex ||
        a.columnIndex - b.columnIndex
      );
    });
    sorted.forEach((glyph, rank) => (glyph.sortedRank = rank));

    this.glyphs = glyphs;
    this.startedAt = performance.now();
  }

  startAnimation() {
    if (this.animationFrame || !this.context) {
      return;
    }

    const draw = () => {
      this.drawFrame(performance.now());
      this.animationFrame = requestAnimationFrame(draw);
    };

    this.animationFrame = requestAnimationFrame(draw);
  }

  stopAnimation() {
    cancelAnimationFrame(this.animationFrame);
    this.animationFrame = null;
  }

  drawFrame(now) {
    const ctx = this.context;

    if (!ctx || !this.canvas) {
      return;
    }

    const width = this.canvas.width;
    const height = this.canvas.height;
    const elapsed = now - this.startedAt;
    const cycle = (elapsed % CYCLE_MS) / CYCLE_MS;
    const mode = this.currentMode(elapsed);
    const jumbleAmount =
      smoothstep(0.18, 0.48, cycle) * (1 - smoothstep(0.76, 0.96, cycle));

    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = this.canvasWashColor();
    ctx.fillRect(0, 0, width, height);

    const palette = this.activeTextPalette();
    this.drawGuideGeometry(ctx, width, height, mode, jumbleAmount, now);

    for (const glyph of this.glyphs) {
      const target = this.targetForGlyph(glyph, mode, now, width, height);
      const wave =
        Math.sin(now * 0.0017 + glyph.index * 0.37) * 7 * jumbleAmount;
      const x = glyph.x + (target.x - glyph.x) * jumbleAmount + wave;
      const y = glyph.y + (target.y - glyph.y) * jumbleAmount;
      const rotation = (target.rotation || 0) * jumbleAmount;
      const scale = 1 + ((target.scale || 1) - 1) * jumbleAmount;
      const colorIndex =
        (glyph.index + glyph.lineIndex * 3 + Math.floor(now / 2800)) %
        palette.fills.length;
      const fillColor = palette.fills[colorIndex];
      const glowColor = palette.glows[colorIndex];

      ctx.save();
      ctx.translate(x, y);
      ctx.rotate(rotation);
      ctx.scale(scale, scale);
      ctx.font = `${glyph.fontSize}px Georgia, serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.lineWidth = Math.max(glyph.fontSize * 0.08, 1.4);
      ctx.strokeStyle = palette.stroke;
      ctx.fillStyle = fillColor;
      ctx.shadowColor = glowColor;
      ctx.shadowBlur = 10 + 18 * jumbleAmount;
      ctx.strokeText(glyph.char, 0, 0);
      ctx.fillText(glyph.char, 0, 0);
      ctx.restore();
    }
  }

  currentMode(elapsed) {
    const configured = settings.text_jumble_animation_mode;

    if (configured && configured !== "mixed") {
      return configured;
    }

    return MODES[Math.floor(elapsed / CYCLE_MS) % MODES.length];
  }

  canvasWashColor() {
    const stageRgb = this.stage?.style
      .getPropertyValue("--text-jumble-background-rgb")
      .trim();

    return stageRgb ? `rgba(${stageRgb}, 0.18)` : "rgba(8, 11, 16, 0.18)";
  }

  applyBackgroundPalette() {
    if (!this.stage) {
      return;
    }

    const style = getComputedStyle(document.documentElement);
    const secondary = this.currentPageBackgroundRgb(style);
    const primary = parseRgb(
      style.getPropertyValue("--primary-rgb"),
      [235, 238, 242]
    );
    const isLightBackground = relativeLuminance(secondary) > 0.5;
    const shiftedBackground = mixRgb(
      secondary,
      isLightBackground ? [0, 0, 0] : [255, 255, 255],
      isLightBackground ? 0.06 : 0.08
    );
    const filter = mixRgb(
      primary,
      isLightBackground ? [0, 0, 0] : [255, 255, 255],
      0.06
    );

    this.stage.style.setProperty(
      "--text-jumble-background-rgb",
      shiftedBackground.join(", ")
    );
    this.stage.style.setProperty("--text-jumble-filter-rgb", filter.join(", "));
    this.stage.style.setProperty(
      "--text-jumble-filter-opacity-start",
      isLightBackground ? "0.08" : "0.06"
    );
    this.stage.style.setProperty(
      "--text-jumble-filter-opacity-end",
      isLightBackground ? "0.13" : "0.1"
    );
  }

  currentPageBackgroundRgb(rootStyle) {
    const selectors = [
      "body",
      "#main-outlet-wrapper",
      "#main-outlet",
      ".d-header-wrap",
    ];

    for (const selector of selectors) {
      const element = document.querySelector(selector);
      const rgb = parseVisibleRgb(
        element ? getComputedStyle(element).backgroundColor : ""
      );

      if (rgb) {
        return rgb;
      }
    }

    return parseRgb(rootStyle.getPropertyValue("--secondary-rgb"), [8, 11, 16]);
  }

  activeTextPalette() {
    const style = getComputedStyle(document.documentElement);
    const primary = parseRgb(
      style.getPropertyValue("--primary-rgb"),
      [235, 238, 242]
    );
    const secondary = parseRgb(
      style.getPropertyValue("--secondary-rgb"),
      [8, 11, 16]
    );
    const tertiary = parseRgb(
      style.getPropertyValue("--tertiary-rgb"),
      primary
    );
    const quaternary = parseRgb(
      style.getPropertyValue("--quaternary-rgb"),
      tertiary
    );
    const headerPrimary = parseRgb(
      style.getPropertyValue("--header_primary-rgb"),
      primary
    );
    const foregroundStops = [primary, headerPrimary, tertiary, quaternary];
    const levelCount = 12;
    const fills = [];
    const glows = [];

    for (let level = 0; level < levelCount; level++) {
      const position = level / (levelCount - 1);
      const scaled = position * (foregroundStops.length - 1);
      const stopIndex = Math.min(
        Math.floor(scaled),
        foregroundStops.length - 2
      );
      const localAmount = scaled - stopIndex;
      const color = mixRgb(
        foregroundStops[stopIndex],
        foregroundStops[stopIndex + 1],
        localAmount
      );
      const glow = mixRgb(color, primary, 0.28);

      fills.push(rgbString(color, 0.94));
      glows.push(rgbString(glow, 0.44));
    }

    return {
      fills,
      glows,
      stroke: rgbString(secondary, 0.76),
    };
  }

  drawGuideGeometry(ctx, width, height, mode, amount, now) {
    if (amount < 0.05) {
      return;
    }

    ctx.save();
    ctx.globalAlpha = amount * 0.28;
    ctx.strokeStyle = "rgba(255, 255, 255, 0.5)";
    ctx.lineWidth = Math.max(width / 900, 1);

    if (mode === "spiral") {
      ctx.beginPath();
      for (let i = 0; i < 280; i++) {
        const angle = i * 0.22 + now * 0.0002;
        const radius = i * Math.min(width, height) * 0.0009;
        const x = width / 2 + Math.cos(angle) * radius;
        const y = height / 2 + Math.sin(angle) * radius;
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
    } else {
      const gap = Math.max(Math.min(width, height) / 12, 48);
      for (let x = width * 0.12; x < width * 0.88; x += gap) {
        ctx.beginPath();
        ctx.moveTo(x, height * 0.16);
        ctx.lineTo(x + Math.sin(now * 0.001 + x) * 24 * amount, height * 0.84);
        ctx.stroke();
      }
    }

    ctx.restore();
  }

  targetForGlyph(glyph, mode, now, width, height) {
    if (mode === "grid") {
      const columns = Math.max(
        Math.floor(Math.sqrt(this.glyphs.length) * 1.45),
        1
      );
      const cell = Math.min(
        (width * 0.68) / columns,
        (height * 0.7) / Math.ceil(this.glyphs.length / columns)
      );
      const column = glyph.index % columns;
      const row = Math.floor(glyph.index / columns);

      return {
        rotation: ((column + row) % 4) * Math.PI * 0.5,
        x: width / 2 - (columns * cell) / 2 + column * cell,
        y: height * 0.18 + row * cell,
      };
    }

    if (mode === "spiral") {
      const angle = glyph.index * 0.31 + now * 0.00035;
      const radius = Math.sqrt(glyph.index) * Math.min(width, height) * 0.017;

      return {
        rotation: angle + Math.PI / 2,
        scale: 0.95 + Math.sin(angle) * 0.12,
        x: width / 2 + Math.cos(angle) * radius,
        y: height / 2 + Math.sin(angle) * radius,
      };
    }

    if (mode === "sorting") {
      const columns = 28;
      const rows = Math.ceil(this.glyphs.length / columns);
      const rank = glyph.sortedRank;

      return {
        rotation: Math.sin(rank * 0.2 + now * 0.001) * 0.45,
        x: width * 0.16 + (rank % columns) * ((width * 0.68) / columns),
        y:
          height / 2 -
          (rows * glyph.fontSize * 0.66) / 2 +
          Math.floor(rank / columns) * glyph.fontSize * 0.66,
      };
    }

    const railCount = Math.max(
      5,
      Math.min(11, Math.ceil(this.glyphs.length / 85))
    );
    const rail = glyph.index % railCount;
    const slotWidth = width * 0.7;
    const offset =
      ((now * 0.032 + glyph.index * 19) % slotWidth) - slotWidth / 2;

    return {
      rotation: rail % 2 ? -0.18 : 0.18,
      x: width / 2 + offset,
      y: height * 0.24 + rail * ((height * 0.52) / Math.max(railCount - 1, 1)),
    };
  }

  <template>
    <div
      class="text-jumble-screen-saver-host"
      {{didInsert this.setup}}
      {{willDestroy this.teardown}}
    >
      {{#if this.isVisible}}
        <section
          class="text-jumble-screen-saver"
          aria-label="Text jumble screensaver"
          {{didInsert this.setupStage}}
          {{willDestroy this.teardownStage}}
        >
          <canvas
            class="text-jumble-screen-saver__canvas"
            {{didInsert this.setupCanvas}}
          ></canvas>

          {{#if this.sourceTitle}}
            <div class="text-jumble-screen-saver__source">
              {{this.sourceTitle}}
            </div>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
}
