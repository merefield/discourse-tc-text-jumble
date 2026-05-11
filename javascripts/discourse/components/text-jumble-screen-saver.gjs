/* global settings */
import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { tracked } from "@glimmer/tracking";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";

import {
  isScreenSaverDisabled,
  selectedAnimationModes,
  setSelectedAnimationModes,
  TEXT_JUMBLE_ANIMATION_MODES,
  TEXT_JUMBLE_ANIMATION_STYLES_CHANGED,
  TEXT_JUMBLE_SCREEN_SAVER_PREFERENCE_CHANGED,
} from "../lib/text-jumble-preferences";

const ACTIVITY_EVENTS = [
  "pointermove",
  "pointerdown",
  "keydown",
  "touchstart",
  "wheel",
  "scroll",
];

const ANIMATION_MS = 18000;
const ANIMATION_RETURN_RATIO = 0.28;
const SPECTRUM_PALETTE_LEVEL_COUNT = 8;
const STRUCTURED_PALETTE_LEVEL_COUNT = 12;
const MAX_GLYPHS = 1100;
const TEXT_TRANSITION_MS = 1600;
const TEXT_TYPE_TRANSITION_MS = 3200;
const TEXT_TYPE_FADE_OUT_MS = 1000;
const HEAP_FORCE_RESTORE_AFTER_LAST_FALL_MS = 10000;
const HEAP_FORCED_RESTORE_MS = ANIMATION_MS * ANIMATION_RETURN_RATIO;
const FONT_FAMILY = "Georgia, serif";
const VERTEX_SHADER_SOURCE = `
  attribute vec2 a_position;
  attribute vec2 a_tex_coord;
  uniform vec2 u_resolution;
  varying vec2 v_tex_coord;

  void main() {
    vec2 zero_to_one = a_position / u_resolution;
    vec2 clip_space = zero_to_one * 2.0 - 1.0;

    gl_Position = vec4(clip_space * vec2(1.0, -1.0), 0.0, 1.0);
    v_tex_coord = a_tex_coord;
  }
`;
const FRAGMENT_SHADER_SOURCE = `
  precision mediump float;

  uniform sampler2D u_texture;
  uniform float u_alpha;
  varying vec2 v_tex_coord;

  void main() {
    vec4 color = texture2D(u_texture, v_tex_coord);
    gl_FragColor = vec4(color.rgb, color.a * u_alpha);
  }
`;

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

function rgbString(rgb, alpha) {
  return `rgba(${rgb.join(", ")}, ${alpha})`;
}

function normalizedRotation(angle) {
  return Math.atan2(Math.sin(angle), Math.cos(angle));
}

function seededUnit(seed) {
  const value = Math.sin(seed * 12.9898) * 43758.5453;
  return value - Math.floor(value);
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
  @service currentUser;
  @service router;

  @tracked isAnimationMenuOpen = false;
  @tracked isVisible = false;
  @tracked selectedAnimationModes = [];
  @tracked sourceTitle = "";
  @tracked sourceUrl = "";

  animationFrame = null;
  animationModeIndex = -1;
  canvas = null;
  colorPaletteMode = "spectrum";
  context = null;
  glyphs = [];
  glyphSpriteCache = new Map();
  heapPhysics = null;
  idleTimer = null;
  animationMenuElement = null;
  lastQuoteText = null;
  lastTopicId = null;
  outgoingGlyphs = [];
  paragraph = "";
  paragraphTimer = null;
  pixelRatio = 1;
  renderer = "canvas";
  resizeObserver = null;
  root = null;
  slotMachineSeed = 0;
  stage = null;
  startedAt = 0;
  transitionMode = "crossfade";
  transitionStartedAt = null;
  webgl = null;
  resizeListenerStarted = false;
  screenSaverListenersStarted = false;

  get isPageMode() {
    return this.args.displayMode === "page";
  }

  get sectionClass() {
    return this.isPageMode
      ? "text-jumble-screen-saver text-jumble-screen-saver--page"
      : "text-jumble-screen-saver";
  }

  get ariaLabel() {
    return this.isPageMode
      ? "Text jumble animation"
      : "Text jumble screensaver";
  }

  get isTextJumbleRoute() {
    return this.router.currentRouteName === "text-jumble";
  }

  get isScreenSaverLocallyDisabled() {
    return isScreenSaverDisabled(this.currentUser);
  }

  get hasSelectedAnimationModes() {
    return this.selectedAnimationModes.length > 0;
  }

  get animationStyleOptions() {
    const selected = new Set(this.selectedAnimationModes);

    return TEXT_JUMBLE_ANIMATION_MODES.map((mode) => ({
      ...mode,
      selected: selected.has(mode.id),
    }));
  }

  @action
  setup(element) {
    this.root = element;
    this.boundResize = () => this.resize();
    this.refreshSelectedAnimationModes();
    this.boundAnimationStylesChange = () => this.handleAnimationStylesChange();
    window.addEventListener(
      TEXT_JUMBLE_ANIMATION_STYLES_CHANGED,
      this.boundAnimationStylesChange
    );

    if (this.isPageMode) {
      this.boundAnimationMenuOutside = (event) =>
        this.handleAnimationMenuOutside(event);
      document.addEventListener("pointerdown", this.boundAnimationMenuOutside, {
        capture: true,
      });
      this.startResizeListener();
      this.show();
    } else {
      this.boundPreferenceChange = () => this.handlePreferenceChange();
      window.addEventListener(
        TEXT_JUMBLE_SCREEN_SAVER_PREFERENCE_CHANGED,
        this.boundPreferenceChange
      );
      this.startScreenSaverListeners();
    }
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
    this.webgl = null;
    this.renderer = this.chooseRenderer();

    if (this.renderer === "disabled") {
      this.context = null;
      return;
    }

    if (this.renderer === "webgl") {
      const gl = element.getContext("webgl", {
        alpha: true,
        antialias: true,
        premultipliedAlpha: false,
      });

      if (gl) {
        this.webgl = this.setupWebgl(gl);
      }
    }

    if (this.renderer === "webgl" && !this.webgl) {
      this.renderer = "canvas";
    }

    this.context = this.webgl
      ? document.createElement("canvas").getContext("2d")
      : element.getContext("2d", { alpha: true });
    this.startedAt = performance.now();
    this.resize();
    this.startAnimation();
  }

  @action
  setupAnimationMenu(element) {
    this.animationMenuElement = element;
  }

  @action
  teardownStage() {
    this.stopAnimation();
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.stage = null;
    this.canvas = null;
    this.context = null;
    this.webgl = null;
  }

  @action
  teardown() {
    this.stopAnimation();
    clearTimeout(this.idleTimer);
    clearTimeout(this.paragraphTimer);
    this.resizeObserver?.disconnect();

    if (this.isPageMode) {
      document.removeEventListener(
        "pointerdown",
        this.boundAnimationMenuOutside,
        { capture: true }
      );
      this.stopResizeListener();
    } else {
      this.stopScreenSaverListeners();
      window.removeEventListener(
        TEXT_JUMBLE_SCREEN_SAVER_PREFERENCE_CHANGED,
        this.boundPreferenceChange
      );
    }

    window.removeEventListener(
      TEXT_JUMBLE_ANIMATION_STYLES_CHANGED,
      this.boundAnimationStylesChange
    );
  }

  startResizeListener() {
    if (this.resizeListenerStarted) {
      return;
    }

    window.addEventListener("resize", this.boundResize, { passive: true });
    this.resizeListenerStarted = true;
  }

  stopResizeListener() {
    if (!this.resizeListenerStarted) {
      return;
    }

    window.removeEventListener("resize", this.boundResize);
    this.resizeListenerStarted = false;
  }

  startScreenSaverListeners() {
    if (
      this.screenSaverListenersStarted ||
      this.isScreenSaverLocallyDisabled ||
      !this.hasSelectedAnimationModes
    ) {
      return;
    }

    this.startResizeListener();
    this.boundActivity = () => this.handleActivity();
    this.boundRouteChange = () => this.handleRouteChange();
    this.boundVisibilityChange = () => this.handleVisibilityChange();

    ACTIVITY_EVENTS.forEach((eventName) => {
      window.addEventListener(eventName, this.boundActivity, {
        passive: true,
      });
    });
    document.addEventListener("visibilitychange", this.boundVisibilityChange);
    this.router.on("routeDidChange", this.boundRouteChange);
    this.screenSaverListenersStarted = true;

    this.scheduleIdle();
  }

  stopScreenSaverListeners() {
    if (!this.screenSaverListenersStarted) {
      return;
    }

    ACTIVITY_EVENTS.forEach((eventName) => {
      window.removeEventListener(eventName, this.boundActivity);
    });
    document.removeEventListener(
      "visibilitychange",
      this.boundVisibilityChange
    );
    this.router.off("routeDidChange", this.boundRouteChange);
    clearTimeout(this.idleTimer);
    this.stopResizeListener();
    this.screenSaverListenersStarted = false;
  }

  async show() {
    if (!this.isPageMode && !this.hasSelectedAnimationModes) {
      return;
    }

    this.glyphs = [];
    this.outgoingGlyphs = [];
    this.transitionMode = Math.random() < 0.5 ? "crossfade" : "type";
    this.transitionStartedAt = null;
    this.isVisible = true;
    await this.loadParagraph();
    this.scheduleNextParagraph();
  }

  hide() {
    this.isVisible = false;
    clearTimeout(this.paragraphTimer);
    this.stopAnimation();
  }

  chooseRenderer() {
    const configured = settings.text_jumble_renderer;

    if (settings.text_jumble_disable_on_low_power && this.isLowPowerDevice()) {
      return "disabled";
    }

    if (configured === "canvas") {
      return "canvas";
    }

    if (configured === "webgl") {
      return this.canUseWebgl() ? "webgl" : "canvas";
    }

    return this.canUseWebgl() ? "webgl" : "canvas";
  }

  isLowPowerDevice() {
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      return true;
    }

    if (navigator.deviceMemory && navigator.deviceMemory <= 2) {
      return true;
    }

    if (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2) {
      return true;
    }

    return false;
  }

  canUseWebgl() {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl", {
      alpha: true,
      antialias: false,
      failIfMajorPerformanceCaveat: true,
      premultipliedAlpha: false,
    });

    if (!gl) {
      return false;
    }

    return gl.getParameter(gl.MAX_TEXTURE_SIZE) >= 2048;
  }

  handleActivity() {
    if (this.isVisible) {
      this.hide();
    }

    this.scheduleIdle();
  }

  handleRouteChange() {
    if (this.isVisible || this.isTextJumbleRoute) {
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

  handlePreferenceChange() {
    if (this.isScreenSaverLocallyDisabled) {
      this.hide();
      this.stopScreenSaverListeners();
    } else {
      this.startScreenSaverListeners();
    }
  }

  handleAnimationStylesChange() {
    this.refreshSelectedAnimationModes();

    if (this.hasSelectedAnimationModes) {
      this.animationModeIndex = -1;
      this.prepareGlyphs();

      if (!this.isPageMode) {
        this.startScreenSaverListeners();
      }
    } else {
      if (this.isPageMode) {
        this.prepareGlyphs();
      } else {
        this.hide();
        this.stopScreenSaverListeners();
      }
    }
  }

  scheduleIdle() {
    clearTimeout(this.idleTimer);

    if (
      document.hidden ||
      !settings.text_jumble_screen_saver_enabled ||
      this.isScreenSaverLocallyDisabled ||
      !this.hasSelectedAnimationModes ||
      this.isTextJumbleRoute
    ) {
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

    this.paragraphTimer = setTimeout(async () => {
      if (this.currentMode() === "heap" && !this.heapMostlySettled()) {
        this.scheduleNextParagraph();
        return;
      }

      await this.loadParagraph();
      this.scheduleNextParagraph();
    }, this.msUntilNextParagraph());
  }

  async loadParagraph() {
    const fallbackText = settings.text_jumble_fallback_text;

    if (settings.text_jumble_text_source === "quotes") {
      this.loadQuoteParagraph(fallbackText);
      this.prepareGlyphs({ transition: true });
      return;
    }

    try {
      const list = await ajax(
        getURL(topicListUrl(settings.text_jumble_topic_source))
      );
      const topics = list?.topic_list?.topics || [];
      const candidates = topics.filter(
        (topic) => !topic.pinned && !topic.closed
      );
      const topicCandidates =
        candidates.length > 1
          ? candidates.filter((topic) => topic.id !== this.lastTopicId)
          : candidates;
      const topic =
        topicCandidates[Math.floor(Math.random() * topicCandidates.length)];

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
      this.lastTopicId = topic.id;
      this.sourceTitle = topicJson.title || topic.title || "";
      this.sourceUrl = getURL(`/t/${topic.slug}/${topic.id}`);
    } catch {
      this.paragraph = fallbackText;
      this.sourceTitle = "";
      this.sourceUrl = "";
    }

    this.prepareGlyphs({ transition: true });
  }

  loadQuoteParagraph(fallbackText) {
    const quotes = [
      settings.text_jumble_quote_1,
      settings.text_jumble_quote_2,
      settings.text_jumble_quote_3,
      settings.text_jumble_quote_4,
      settings.text_jumble_quote_5,
    ]
      .map((quote) => quote?.trim())
      .filter(Boolean);

    const quoteCandidates =
      quotes.length > 1
        ? quotes.filter((quote) => quote !== this.lastQuoteText)
        : quotes;
    this.paragraph =
      quoteCandidates[Math.floor(Math.random() * quoteCandidates.length)] ||
      fallbackText;
    this.lastQuoteText = this.paragraph;
    this.sourceTitle = "";
    this.sourceUrl = "";
  }

  resize() {
    if (!this.canvas || !this.stage) {
      return;
    }

    this.applyBackgroundPalette();

    const rect = this.stage.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 1.75);
    this.pixelRatio = ratio;
    this.canvas.width = Math.max(Math.floor(rect.width * ratio), 1);
    this.canvas.height = Math.max(Math.floor(rect.height * ratio), 1);
    this.canvas.style.width = `${rect.width}px`;
    this.canvas.style.height = `${rect.height}px`;

    this.prepareGlyphs();
  }

  prepareGlyphs({ transition = false } = {}) {
    if (!this.context || !this.canvas || !this.paragraph) {
      return;
    }

    if (transition || this.animationModeIndex < 0) {
      this.animationModeIndex =
        (this.animationModeIndex + 1) %
        Math.max(this.selectedAnimationModes.length, 1);
    }
    this.slotMachineSeed = Math.random() * 10000;

    const ctx = this.context;
    const width = this.canvas.width;
    const height = this.canvas.height;
    const fontSize =
      clamp(Math.round(width / this.pixelRatio / 54), 18, 34) * this.pixelRatio;
    const lineHeight = Math.round(fontSize * 1.45);
    const maxTextWidth = width * 0.72;
    const words = this.paragraph.split(/\s+/).filter(Boolean);
    const lines = [];
    let line = "";

    ctx.font = `400 ${fontSize}px ${FONT_FAMILY}`;

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
    let globalWordIndex = 0;
    const colorPaletteMode = Math.random() < 0.5 ? "spectrum" : "structured";
    const colorPaletteOffset =
      colorPaletteMode === "structured"
        ? Math.floor(Math.random() * STRUCTURED_PALETTE_LEVEL_COUNT)
        : 0;

    lines.forEach((textLine, lineIndex) => {
      let x = width / 2 - ctx.measureText(textLine).width / 2;
      const y = startY + lineIndex * lineHeight;
      let isInsideWord = false;
      let lineWordIndex = globalWordIndex;

      [...textLine].forEach((char, columnIndex) => {
        const charWidth = ctx.measureText(char).width;

        if (char !== " ") {
          if (!isInsideWord) {
            isInsideWord = true;
          }

          glyphs.push({
            char,
            columnIndex,
            colorIndex: this.wordColorIndex(
              lineWordIndex,
              colorPaletteMode,
              colorPaletteOffset
            ),
            colorPaletteMode,
            fontSize,
            index: glyphs.length,
            lineIndex,
            width: charWidth,
            wordIndex: lineWordIndex,
            x: x + charWidth / 2,
            y,
          });
        } else if (isInsideWord) {
          isInsideWord = false;
          lineWordIndex++;
        }

        x += charWidth;
      });

      if (isInsideWord) {
        lineWordIndex++;
      }

      globalWordIndex = lineWordIndex;
    });

    this.prepareWordMetadata(glyphs, globalWordIndex);

    let dominoIndex = 0;
    const glyphsByLine = new Map();
    glyphs.forEach((glyph) => {
      const lineGlyphs = glyphsByLine.get(glyph.lineIndex) || [];
      lineGlyphs.push(glyph);
      glyphsByLine.set(glyph.lineIndex, lineGlyphs);
    });
    [...glyphsByLine.keys()]
      .sort((a, b) => a - b)
      .forEach((lineIndex) => {
        const lineGlyphs = glyphsByLine
          .get(lineIndex)
          .sort((a, b) => (lineIndex % 2 === 0 ? a.x - b.x : b.x - a.x));

        lineGlyphs.forEach((glyph) => {
          glyph.dominoIndex = dominoIndex++;
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

    if (transition) {
      if (this.glyphs.length) {
        this.outgoingGlyphs = this.glyphs;
        this.transitionMode = Math.random() < 0.5 ? "crossfade" : "type";
        this.transitionStartedAt = performance.now();
      } else if (this.transitionMode === "type") {
        this.outgoingGlyphs = [];
        this.transitionStartedAt = performance.now();
      } else {
        this.outgoingGlyphs = [];
        this.transitionStartedAt = null;
      }
    } else {
      this.outgoingGlyphs = [];
      this.transitionMode = "crossfade";
      this.transitionStartedAt = null;
    }

    this.glyphs = glyphs;
    this.heapPhysics = null;
    this.startedAt = performance.now();
  }

  wordColorIndex(wordIndex, paletteMode, paletteOffset = 0) {
    if (paletteMode === "structured") {
      const position =
        (wordIndex + paletteOffset) % STRUCTURED_PALETTE_LEVEL_COUNT;

      if (position === 5) {
        return 1;
      }

      if (position === 11) {
        return 2;
      }

      return 0;
    }

    return wordIndex % SPECTRUM_PALETTE_LEVEL_COUNT;
  }

  prepareWordMetadata(glyphs, wordCount) {
    const glyphsByWord = new Map();

    glyphs.forEach((glyph) => {
      const wordGlyphs = glyphsByWord.get(glyph.wordIndex) || [];
      wordGlyphs.push(glyph);
      glyphsByWord.set(glyph.wordIndex, wordGlyphs);
      glyph.totalWordCount = wordCount;
    });

    const selectedWordIndex =
      glyphsByWord.size > 0
        ? glyphsByWord
            .entries()
            .toArray()
            .toSorted(
              ([wordIndexA, glyphsA], [wordIndexB, glyphsB]) =>
                glyphsB.length - glyphsA.length || wordIndexA - wordIndexB
            )
            .slice(0, 10)
            .at(Math.floor(Math.random() * Math.min(glyphsByWord.size, 10)))[0]
        : -1;

    glyphsByWord.forEach((wordGlyphs, wordIndex) => {
      const left = Math.min(
        ...wordGlyphs.map((glyph) => glyph.x - glyph.width / 2)
      );
      const right = Math.max(
        ...wordGlyphs.map((glyph) => glyph.x + glyph.width / 2)
      );
      const wordCenterX = (left + right) / 2;

      wordGlyphs.forEach((glyph) => {
        glyph.isLongestWord = wordIndex === selectedWordIndex;
        glyph.longestWordIndex = selectedWordIndex;
        glyph.wordCenterOffset = glyph.x - wordCenterX;
        glyph.wordHalfWidth = (right - left) / 2;
        glyph.wordLength = wordGlyphs.length;
      });
    });
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

  ensureHeapPhysics(width, height) {
    if (
      this.heapPhysics?.glyphCount === this.glyphs.length &&
      this.heapPhysics?.width === width &&
      this.heapPhysics?.height === height
    ) {
      return;
    }

    const bodies = this.glyphs.map((glyph) => {
      const radius = Math.max(glyph.fontSize * 0.34, 6);
      const dropX = clamp(
        width * 0.54 +
          (seededUnit(glyph.index + 131) - 0.5) * glyph.fontSize * 0.42,
        radius,
        width - radius
      );

      return {
        angularVelocity: 0,
        dropX,
        grounded: false,
        radius,
        rotation: -0.08,
        settledFrames: 0,
        state: "queued",
        vx: 0,
        vy: 0,
        x: glyph.x,
        y: glyph.y,
      };
    });

    this.heapPhysics = {
      bodies,
      forcedRestoreStartedAt: null,
      glyphCount: this.glyphs.length,
      height,
      lastNow: null,
      lastLetterFellAt: null,
      releaseAccumulator: 0,
      releaseComplete: false,
      releaseIndex: 0,
      width,
    };
  }

  updateHeapPhysics(now, width, height, phase) {
    this.ensureHeapPhysics(width, height);

    const physics = this.heapPhysics;
    const deltaSeconds = Math.min(
      physics.lastNow ? (now - physics.lastNow) / 1000 : 1 / 60,
      1 / 30
    );
    physics.lastNow = now;

    const streamProgress = clamp(
      (phase.cycle - phase.readEnd) /
        Math.max(phase.animateOutStart - phase.readEnd, 0.01),
      0,
      1
    );
    const firstGlyph = this.glyphs[0];
    const fontSize = firstGlyph?.fontSize || 20;
    const tankFillDuration = 0.1;
    const tankProgress = clamp(streamProgress / tankFillDuration, 0, 1);
    const releaseDurationSeconds =
      (Math.max(phase.animateOutStart - phase.readEnd, 0.01) / 1000) *
      (1 - tankFillDuration);
    const releaseIntervalSeconds = clamp(
      releaseDurationSeconds / Math.max(physics.bodies.length, 1),
      0.08,
      0.18
    );
    const tankCursor = tankProgress * (physics.bodies.length + 2) - 1;
    const tankLeft = fontSize * 0.8;
    const tankTop = fontSize * 0.7;
    const tankWidth = Math.min(width * 0.24, fontSize * 9);
    const tankHeight = Math.min(height * 0.2, fontSize * 6);
    const tankRight = tankLeft + tankWidth;
    const tankBottom = tankTop + tankHeight;
    const tankOutletX = tankLeft + tankWidth * 0.55;
    const beltY = height * 0.22;
    const gravity = height * 1.65;
    const floorY = height - Math.max(fontSize, 20) * 0.8;

    physics.bodies.forEach((body, index) => {
      const glyph = this.glyphs[index];
      body.grounded = false;

      if (body.state === "queued" && tankCursor >= index) {
        const tankTargetX =
          tankLeft + tankWidth * (0.24 + seededUnit(index + 251) * 0.58);
        const tankTargetY =
          tankTop + tankHeight * (0.2 + seededUnit(index + 257) * 0.35);

        body.state = "thrown";
        body.vx = (tankTargetX - body.x) / 0.12;
        body.vy = (tankTargetY - body.y) / 0.12;
        body.angularVelocity = (seededUnit(index + 277) - 0.5) * 7;
      }

      if (body.state === "conveyor") {
        const direction = Math.sign(body.dropX - body.x) || 1;
        body.x += body.vx * deltaSeconds;
        body.y = beltY + glyph.lineIndex * glyph.fontSize * 0.05;

        if ((body.dropX - body.x) * direction <= 0) {
          body.state = "falling";
          body.x = body.dropX;
          body.vx = (seededUnit(index + 197) - 0.5) * glyph.fontSize * 0.58;
          body.vy = glyph.fontSize * (0.2 + seededUnit(index + 211) * 0.25);
          body.angularVelocity = (seededUnit(index + 223) - 0.5) * 2.2;

          if (index === physics.bodies.length - 1) {
            physics.lastLetterFellAt = now;
          }
        }
      } else if (body.state === "thrown" || body.state === "tank") {
        body.vy += gravity * deltaSeconds * 0.55;
        body.x += body.vx * deltaSeconds;
        body.y += body.vy * deltaSeconds;
        body.rotation += body.angularVelocity * deltaSeconds;

        if (body.x < tankLeft + body.radius) {
          body.x = tankLeft + body.radius;
          body.vx = Math.abs(body.vx) * 0.36;
          body.angularVelocity *= -0.52;
        } else if (body.x > tankRight - body.radius) {
          body.x = tankRight - body.radius;
          body.vx = -Math.abs(body.vx) * 0.36;
          body.angularVelocity *= -0.52;
        }

        if (body.y < tankTop + body.radius) {
          body.y = tankTop + body.radius;
          body.vy = Math.abs(body.vy) * 0.28;
        } else if (body.y > tankBottom - body.radius) {
          body.y = tankBottom - body.radius;
          body.vy = -Math.abs(body.vy) * 0.24;
          body.vx *= 0.7;
          body.angularVelocity *= 0.82;
          body.state = "tank";
        }
      } else if (body.state !== "queued" && body.state !== "settled") {
        body.vy += gravity * deltaSeconds;
        body.x += body.vx * deltaSeconds;
        body.y += body.vy * deltaSeconds;
        body.rotation += body.angularVelocity * deltaSeconds;

        if (body.x < body.radius) {
          body.x = body.radius;
          body.vx = Math.abs(body.vx) * 0.28;
          body.vy *= 0.92;
          body.angularVelocity *= -0.32;
        } else if (body.x > width - body.radius) {
          body.x = width - body.radius;
          body.vx = -Math.abs(body.vx) * 0.28;
          body.vy *= 0.92;
          body.angularVelocity *= -0.32;
        }

        if (body.y > floorY - body.radius) {
          const impactVelocity = Math.abs(body.vy);

          body.y = floorY - body.radius;
          body.vy =
            impactVelocity < glyph.fontSize * 1.2 ? 0 : -impactVelocity * 0.14;
          body.grounded = true;
          body.vx = 0;
          body.angularVelocity += body.vx * 0.012;
          body.angularVelocity *= 0.02;

          if (
            Math.abs(body.vx) < glyph.fontSize * 0.22 &&
            Math.abs(body.vy) < glyph.fontSize * 0.18
          ) {
            body.settledFrames += 4;
          }
        }
      }
    });

    if (tankProgress >= 1) {
      physics.bodies.forEach((body) => {
        if (body.state !== "thrown") {
          return;
        }

        body.state = "tank";
        body.x = clamp(body.x, tankLeft + body.radius, tankRight - body.radius);
        body.y = clamp(body.y, tankTop + body.radius, tankBottom - body.radius);
        body.vx *= 0.28;
        body.vy *= 0.2;
        body.angularVelocity *= 0.6;
      });
    }

    const tankLoaded = physics.bodies.every(
      (body) => body.state !== "queued" && body.state !== "thrown"
    );

    physics.bodies.forEach((body) => {
      if (
        body.state !== "queued" &&
        body.state !== "conveyor" &&
        body.y >= floorY - body.radius - 0.5
      ) {
        body.grounded = true;
        body.vx *= 0.04;
      }
    });

    if (tankLoaded && !physics.releaseComplete) {
      physics.releaseAccumulator += deltaSeconds;

      if (
        physics.releaseIndex === 0 ||
        physics.releaseAccumulator >= releaseIntervalSeconds
      ) {
        const body = physics.bodies[physics.releaseIndex];
        const glyph = this.glyphs[physics.releaseIndex];

        if (body?.state === "tank") {
          physics.releaseAccumulator = 0;
          body.state = "conveyor";
          body.x = tankOutletX;
          body.y = tankBottom + glyph.fontSize * 0.24;
          body.vx = (body.dropX - tankOutletX) / 0.78;
          body.vy = 0;
          body.angularVelocity *= 0.25;
          physics.releaseIndex++;
        }
      }

      physics.releaseComplete = physics.releaseIndex >= physics.bodies.length;
    }

    this.resolveHeapCollisions(physics.bodies);

    physics.bodies.forEach((body) => {
      if (
        body.state === "queued" ||
        body.state === "conveyor" ||
        body.state === "settled"
      ) {
        return;
      }

      if (body.state === "thrown" || body.state === "tank") {
        body.vx *= 0.988;
        body.vy *= 0.99;
        body.angularVelocity *= 0.982;
        return;
      }

      body.vx *= 0.986;
      body.vy *= 0.992;
      body.angularVelocity *= 0.972;

      if (
        Math.abs(body.vx) < 6 &&
        Math.abs(body.vy) < 8 &&
        Math.abs(body.angularVelocity) < 0.08
      ) {
        body.settledFrames++;
      } else {
        body.settledFrames = 0;
      }

      if (body.settledFrames > 12) {
        body.vx = 0;
        body.vy = 0;
        body.angularVelocity = 0;
        body.state = "settled";
      }
    });

    const doneCount = physics.bodies.filter((body) => {
      if (body.state === "settled") {
        return true;
      }

      return (
        body.state === "falling" &&
        Math.abs(body.vx) < 10 &&
        Math.abs(body.vy) < 12 &&
        Math.abs(body.angularVelocity) < 0.12
      );
    }).length;

    if (
      physics.lastLetterFellAt &&
      !physics.forcedRestoreStartedAt &&
      now - physics.lastLetterFellAt >= HEAP_FORCE_RESTORE_AFTER_LAST_FALL_MS
    ) {
      physics.forcedRestoreStartedAt = now;
    }

    const settledEnough =
      physics.releaseComplete && doneCount / physics.bodies.length >= 0.9;
    const forcedRestoreComplete = this.heapForcedRestoreProgress(now) >= 1;

    physics.allSettled =
      physics.bodies.length > 0 && (settledEnough || forcedRestoreComplete);
  }

  heapMostlySettled() {
    return this.heapPhysics?.allSettled;
  }

  heapForcedRestoreProgress(now) {
    const startedAt = this.heapPhysics?.forcedRestoreStartedAt;

    if (!startedAt) {
      return 0;
    }

    return smoothstep(0, HEAP_FORCED_RESTORE_MS, now - startedAt);
  }

  resolveHeapCollisions(bodies) {
    const activeBodies = bodies.filter(
      (body) => body.state !== "queued" && body.state !== "conveyor"
    );

    for (let pass = 0; pass < 2; pass++) {
      for (let aIndex = 0; aIndex < activeBodies.length; aIndex++) {
        const a = activeBodies[aIndex];

        for (let bIndex = aIndex + 1; bIndex < activeBodies.length; bIndex++) {
          const b = activeBodies[bIndex];
          const dx = b.x - a.x;
          const dy = b.y - a.y;
          const minDistance = (a.radius + b.radius) * 0.82;
          const distance = Math.hypot(dx, dy) || 0.001;

          if (distance >= minDistance) {
            continue;
          }

          const normalX = dx / distance;
          const normalY = dy / distance;
          const overlap = minDistance - distance;
          const aMass = a.radius;
          const bMass = b.radius;
          const totalMass = aMass + bMass;
          const aMoveShare = a.grounded ? 0.018 : bMass / totalMass;
          const bMoveShare = b.grounded ? 0.018 : aMass / totalMass;

          a.x -= normalX * overlap * aMoveShare;
          a.y -= normalY * overlap * (bMass / totalMass);
          b.x += normalX * overlap * bMoveShare;
          b.y += normalY * overlap * (aMass / totalMass);

          const relativeVelocityX = b.vx - a.vx;
          const relativeVelocityY = b.vy - a.vy;
          const velocityAlongNormal =
            relativeVelocityX * normalX + relativeVelocityY * normalY;

          if (velocityAlongNormal > 0) {
            continue;
          }

          const impulse = (-velocityAlongNormal * 0.98) / totalMass;
          const impulseX = impulse * normalX;
          const impulseY = impulse * normalY;

          a.vx -= impulseX * bMass;
          a.vy -= impulseY * bMass;
          b.vx += impulseX * aMass;
          b.vy += impulseY * aMass;

          const tangentX = -normalY;
          const tangentY = normalX;
          const tangentVelocity =
            relativeVelocityX * tangentX + relativeVelocityY * tangentY;
          const frictionImpulse = (-tangentVelocity * 0.86) / totalMass;
          const frictionImpulseX = frictionImpulse * tangentX;
          const frictionImpulseY = frictionImpulse * tangentY;

          a.vx -= frictionImpulseX * bMass;
          a.vy -= frictionImpulseY * bMass;
          b.vx += frictionImpulseX * aMass;
          b.vy += frictionImpulseY * aMass;

          if (a.grounded) {
            a.vx *= 0.08;
          }
          if (b.grounded) {
            b.vx *= 0.08;
          }

          a.angularVelocity = (a.angularVelocity - impulseX * 0.01) * 0.5;
          b.angularVelocity = (b.angularVelocity + impulseX * 0.01) * 0.5;
          if (
            a.state === "settled" &&
            (Math.abs(a.vx) > 3 ||
              Math.abs(a.vy) > 4 ||
              Math.abs(a.angularVelocity) > 0.05)
          ) {
            a.state = "falling";
          }
          if (
            b.state === "settled" &&
            (Math.abs(b.vx) > 3 ||
              Math.abs(b.vy) > 4 ||
              Math.abs(b.angularVelocity) > 0.05)
          ) {
            b.state = "falling";
          }
          a.settledFrames = 0;
          b.settledFrames = 0;
        }
      }
    }
  }

  drawFrame(now) {
    const ctx = this.context;

    if (!ctx || !this.canvas) {
      return;
    }

    const width = this.canvas.width;
    const height = this.canvas.height;
    const elapsed = now - this.startedAt;
    const phase = this.animationPhase(elapsed);
    const mode = this.currentMode();
    let jumbleAmount = mode
      ? smoothstep(phase.readEnd, phase.animateInEnd, phase.cycle) *
        (1 - smoothstep(phase.animateOutStart, phase.animateEnd, phase.cycle))
      : 0;

    this.clearRenderer(ctx, width, height);

    if (mode === "heap") {
      this.updateHeapPhysics(now, width, height, phase);

      if (!this.heapMostlySettled() && phase.cycle >= phase.readEnd) {
        jumbleAmount = Math.max(
          jumbleAmount,
          1 - this.heapForcedRestoreProgress(now)
        );
      }
    }

    const palettes = this.activeTextPalettes();
    let incomingAlpha = 1;
    let incomingRevealProgress = 1;

    if (this.outgoingGlyphs.length && this.transitionStartedAt) {
      const transitionDuration =
        this.transitionMode === "type"
          ? TEXT_TYPE_TRANSITION_MS
          : TEXT_TRANSITION_MS;
      const transitionProgress = clamp(
        (now - this.transitionStartedAt) / transitionDuration,
        0,
        1
      );

      if (this.transitionMode === "type") {
        const fadeOutProgress = clamp(
          (now - this.transitionStartedAt) / TEXT_TYPE_FADE_OUT_MS,
          0,
          1
        );
        const typingProgress = clamp(
          (now - this.transitionStartedAt - TEXT_TYPE_FADE_OUT_MS) /
            (TEXT_TYPE_TRANSITION_MS - TEXT_TYPE_FADE_OUT_MS),
          0,
          1
        );

        this.drawGlyphs(
          ctx,
          this.outgoingGlyphs,
          palettes,
          mode,
          now,
          width,
          height,
          jumbleAmount,
          1 - smoothstep(0, 1, fadeOutProgress)
        );
        incomingAlpha = smoothstep(0, 0.18, typingProgress);
        incomingRevealProgress = smoothstep(0, 1, typingProgress);
      } else {
        const easedProgress = smoothstep(0, 1, transitionProgress);

        this.drawGlyphs(
          ctx,
          this.outgoingGlyphs,
          palettes,
          mode,
          now,
          width,
          height,
          jumbleAmount,
          1 - easedProgress
        );
        incomingAlpha = easedProgress;
      }

      if (transitionProgress >= 1) {
        this.outgoingGlyphs = [];
        this.transitionStartedAt = null;
        incomingAlpha = 1;
        incomingRevealProgress = 1;
      }
    }

    this.drawGlyphs(
      ctx,
      this.glyphs,
      palettes,
      mode,
      now,
      width,
      height,
      jumbleAmount,
      incomingAlpha,
      incomingRevealProgress
    );
  }

  clearRenderer(ctx, width, height) {
    if (this.webgl) {
      const gl = this.webgl.context;
      const background = this.canvasWashRgb();

      gl.viewport(0, 0, width, height);
      gl.clearColor(
        background.rgb[0] / 255,
        background.rgb[1] / 255,
        background.rgb[2] / 255,
        this.isPageMode ? 0 : background.alpha
      );
      gl.clear(gl.COLOR_BUFFER_BIT);
      return;
    }

    ctx.clearRect(0, 0, width, height);

    if (this.isPageMode) {
      return;
    }

    ctx.fillStyle = this.canvasWashColor();
    ctx.fillRect(0, 0, width, height);
  }

  drawGlyphs(
    ctx,
    glyphs,
    palettes,
    mode,
    now,
    width,
    height,
    jumbleAmount,
    alpha,
    revealProgress = 1
  ) {
    if (alpha <= 0) {
      return;
    }

    for (const glyph of glyphs) {
      const glyphReveal = clamp(
        revealProgress * glyphs.length - glyph.index,
        0,
        1
      );

      if (glyphReveal <= 0) {
        continue;
      }

      const target = this.targetForGlyph(
        glyph,
        mode,
        now,
        width,
        height,
        glyphs.length
      );
      const wave =
        mode === "slot_machine" || mode === "single_out" || mode === "heap"
          ? 0
          : Math.sin(now * 0.0017 + glyph.index * 0.37) * 7 * jumbleAmount;
      const x = glyph.x + (target.x - glyph.x) * jumbleAmount + wave;
      const y = glyph.y + (target.y - glyph.y) * jumbleAmount;
      const rotation = (target.rotation || 0) * jumbleAmount;
      const scale = 1 + ((target.scale || 1) - 1) * jumbleAmount;
      const targetAlpha = 1 + ((target.alpha ?? 1) - 1) * jumbleAmount;
      const palette = palettes[glyph.colorPaletteMode] || palettes.spectrum;
      const colorIndex = glyph.colorIndex % palette.fills.length;
      const fillColor = palette.fills[colorIndex];

      if (this.webgl) {
        this.drawGlyphSpriteWebgl(
          glyph,
          fillColor,
          palette.stroke,
          x,
          y,
          rotation,
          scale,
          alpha *
            targetAlpha *
            smoothstep(0, 1, glyphReveal) *
            (0.94 + jumbleAmount * 0.06)
        );
      } else {
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(rotation);
        ctx.scale(scale, scale);
        ctx.font = `400 ${glyph.fontSize}px ${FONT_FAMILY}`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.globalAlpha =
          alpha *
          targetAlpha *
          smoothstep(0, 1, glyphReveal) *
          (0.94 + jumbleAmount * 0.06);
        this.drawGlyphSprite(ctx, glyph, fillColor, palette.stroke);
        ctx.restore();
      }
    }
  }

  drawGlyphSprite(ctx, glyph, fillColor, strokeColor) {
    const sprite = this.glyphSprite(glyph, fillColor, strokeColor);

    ctx.drawImage(
      sprite.canvas,
      -sprite.width / 2,
      -sprite.height / 2,
      sprite.width,
      sprite.height
    );
  }

  glyphSprite(glyph, fillColor, strokeColor) {
    const cacheKey = [glyph.char, glyph.fontSize, fillColor, strokeColor].join(
      "|"
    );
    let sprite = this.glyphSpriteCache.get(cacheKey);

    if (!sprite) {
      sprite = this.buildGlyphSprite(glyph, fillColor, strokeColor);
      this.glyphSpriteCache.set(cacheKey, sprite);
    }

    return sprite;
  }

  buildGlyphSprite(glyph, fillColor, strokeColor) {
    const padding = Math.ceil(glyph.fontSize * 0.24);
    const width = Math.ceil(glyph.width + padding * 2);
    const height = Math.ceil(glyph.fontSize * 1.5 + padding * 2);
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");

    canvas.width = width;
    canvas.height = height;

    ctx.translate(width / 2, height / 2);
    ctx.font = `400 ${glyph.fontSize}px ${FONT_FAMILY}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.lineWidth = Math.max(glyph.fontSize * 0.08, 1.4);
    ctx.strokeStyle = strokeColor;
    ctx.fillStyle = fillColor;

    if (strokeColor) {
      ctx.strokeText(glyph.char, 0, 0);
    }

    ctx.fillText(glyph.char, 0, 0);

    return { canvas, height, width };
  }

  drawGlyphSpriteWebgl(
    glyph,
    fillColor,
    strokeColor,
    x,
    y,
    rotation,
    scale,
    alpha
  ) {
    const sprite = this.glyphSprite(glyph, fillColor, strokeColor);
    const glState = this.webgl;

    if (!glState || alpha <= 0) {
      return;
    }

    const gl = glState.context;
    const texture = this.textureForSprite(sprite);
    const halfWidth = (sprite.width * scale) / 2;
    const halfHeight = (sprite.height * scale) / 2;
    const cos = Math.cos(rotation);
    const sin = Math.sin(rotation);
    const corners = [
      [-halfWidth, -halfHeight, 0, 0],
      [halfWidth, -halfHeight, 1, 0],
      [-halfWidth, halfHeight, 0, 1],
      [-halfWidth, halfHeight, 0, 1],
      [halfWidth, -halfHeight, 1, 0],
      [halfWidth, halfHeight, 1, 1],
    ];
    const vertices = new Float32Array(corners.length * 4);

    corners.forEach((corner, index) => {
      const [localX, localY, u, v] = corner;
      const offset = index * 4;

      vertices[offset] = x + localX * cos - localY * sin;
      vertices[offset + 1] = y + localX * sin + localY * cos;
      vertices[offset + 2] = u;
      vertices[offset + 3] = v;
    });

    gl.useProgram(glState.program);
    gl.bindBuffer(gl.ARRAY_BUFFER, glState.buffer);
    gl.bufferData(gl.ARRAY_BUFFER, vertices, gl.DYNAMIC_DRAW);
    gl.enableVertexAttribArray(glState.positionLocation);
    gl.vertexAttribPointer(glState.positionLocation, 2, gl.FLOAT, false, 16, 0);
    gl.enableVertexAttribArray(glState.texCoordLocation);
    gl.vertexAttribPointer(glState.texCoordLocation, 2, gl.FLOAT, false, 16, 8);
    gl.uniform2f(
      glState.resolutionLocation,
      this.canvas.width,
      this.canvas.height
    );
    gl.uniform1f(glState.alphaLocation, alpha);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.uniform1i(glState.textureLocation, 0);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  textureForSprite(sprite) {
    const gl = this.webgl.context;
    sprite.textures ||= new WeakMap();

    if (sprite.textures.has(gl)) {
      return sprite.textures.get(gl);
    }

    const texture = gl.createTexture();

    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(
      gl.TEXTURE_2D,
      0,
      gl.RGBA,
      gl.RGBA,
      gl.UNSIGNED_BYTE,
      sprite.canvas
    );
    sprite.textures.set(gl, texture);

    return texture;
  }

  setupWebgl(gl) {
    const vertexShader = this.compileShader(
      gl,
      gl.VERTEX_SHADER,
      VERTEX_SHADER_SOURCE
    );
    const fragmentShader = this.compileShader(
      gl,
      gl.FRAGMENT_SHADER,
      FRAGMENT_SHADER_SOURCE
    );

    if (!vertexShader || !fragmentShader) {
      return null;
    }

    const program = gl.createProgram();

    gl.attachShader(program, vertexShader);
    gl.attachShader(program, fragmentShader);
    gl.linkProgram(program);

    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      return null;
    }

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    return {
      alphaLocation: gl.getUniformLocation(program, "u_alpha"),
      buffer: gl.createBuffer(),
      context: gl,
      positionLocation: gl.getAttribLocation(program, "a_position"),
      program,
      resolutionLocation: gl.getUniformLocation(program, "u_resolution"),
      texCoordLocation: gl.getAttribLocation(program, "a_tex_coord"),
      textureLocation: gl.getUniformLocation(program, "u_texture"),
    };
  }

  compileShader(gl, type, source) {
    const shader = gl.createShader(type);

    gl.shaderSource(shader, source);
    gl.compileShader(shader);

    return gl.getShaderParameter(shader, gl.COMPILE_STATUS) ? shader : null;
  }

  currentMode() {
    if (!this.selectedAnimationModes.length) {
      return null;
    }

    return this.selectedAnimationModes[
      Math.max(this.animationModeIndex, 0) % this.selectedAnimationModes.length
    ];
  }

  refreshSelectedAnimationModes() {
    this.selectedAnimationModes = selectedAnimationModes(
      this.currentUser,
      settings
    );
  }

  @action
  toggleAnimationStyle(event) {
    const mode = event.target.value;
    const selected = new Set(this.selectedAnimationModes);

    if (event.target.checked) {
      selected.add(mode);
    } else {
      selected.delete(mode);
    }

    const nextModes = TEXT_JUMBLE_ANIMATION_MODES.map(
      (option) => option.id
    ).filter((optionMode) => selected.has(optionMode));

    this.selectedAnimationModes = nextModes;
    setSelectedAnimationModes(this.currentUser, nextModes);
  }

  @action
  toggleAnimationMenu() {
    this.isAnimationMenuOpen = !this.isAnimationMenuOpen;
  }

  handleAnimationMenuOutside(event) {
    if (
      !this.isAnimationMenuOpen ||
      this.animationMenuElement?.contains(event.target)
    ) {
      return;
    }

    this.isAnimationMenuOpen = false;
  }

  animationCycleMs() {
    return this.readHoldMs() + ANIMATION_MS + this.afterAnimationReadHoldMs();
  }

  animationPhase(elapsed) {
    const cycleMs = this.animationCycleMs();
    const readMs = this.readHoldMs();
    const cycleElapsed = clamp(elapsed, 0, cycleMs);
    const cycle = cycleElapsed / cycleMs;
    const readEnd = readMs / cycleMs;
    const animationSpan = ANIMATION_MS / cycleMs;
    const animateInEnd = readEnd + animationSpan * 0.36;
    const animateEnd = readEnd + animationSpan;
    const animateOutStart = animateEnd - animationSpan * ANIMATION_RETURN_RATIO;

    return {
      animateEnd,
      animateInEnd,
      animateOutStart,
      cycle,
      cycleElapsed,
      cycleMs,
      readEnd,
    };
  }

  msUntilNextParagraph(now = performance.now()) {
    const elapsed = now - this.startedAt;
    const phase = this.animationPhase(elapsed);

    if (this.currentMode() === "heap" && !this.heapMostlySettled()) {
      return Math.max(Math.ceil(phase.cycleMs - phase.cycleElapsed), 500);
    }

    return Math.max(Math.ceil(phase.cycleMs - phase.cycleElapsed), 0);
  }

  readHoldMs() {
    return Math.max(Number(settings.text_jumble_read_seconds) || 0, 0) * 1000;
  }

  afterAnimationReadHoldMs() {
    return (
      Math.max(
        Number(settings.text_jumble_after_animation_read_seconds) || 0,
        0
      ) * 1000
    );
  }

  canvasWashColor() {
    const { alpha, rgb } = this.canvasWashRgb();

    return rgbString(rgb, alpha);
  }

  canvasWashRgb() {
    const stageRgb = this.stage?.style
      .getPropertyValue("--text-jumble-background-rgb")
      .trim();

    return {
      alpha: this.screenSaverBackgroundAlpha(),
      rgb: parseRgb(stageRgb, [8, 11, 16]),
    };
  }

  screenSaverBackgroundAlpha() {
    const configuredOpacity =
      Number(settings.text_jumble_screen_saver_background_opacity) / 100;

    return Number.isFinite(configuredOpacity)
      ? clamp(configuredOpacity, 0, 1)
      : 0.32;
  }

  applyBackgroundPalette() {
    if (!this.stage) {
      return;
    }

    const style = getComputedStyle(document.documentElement);
    const background = this.currentPageBackgroundRgb(style);

    this.stage.style.setProperty(
      "--text-jumble-background-rgb",
      background.join(", ")
    );
    this.stage.style.setProperty(
      "--text-jumble-background-opacity",
      this.screenSaverBackgroundAlpha()
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

  activeTextPalettes() {
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
    const spectrumFills = [];

    for (let level = 0; level < SPECTRUM_PALETTE_LEVEL_COUNT; level++) {
      const position = level / (SPECTRUM_PALETTE_LEVEL_COUNT - 1);
      spectrumFills.push(rgbString(mixRgb(primary, tertiary, position), 0.94));
    }

    return {
      spectrum: {
        fills: spectrumFills,
        stroke: rgbString(secondary, 0.76),
      },
      structured: {
        fills: [
          rgbString(primary, 0.94),
          rgbString(tertiary, 0.94),
          rgbString(quaternary, 0.94),
        ],
        stroke: rgbString(secondary, 0.76),
      },
    };
  }

  heapPositionForGlyph(glyph, glyphCount, width, height) {
    const levelCount = Math.max(4, Math.ceil(Math.sqrt(glyphCount) * 0.8));
    let heapIndex = glyph.index;
    let level = 0;
    let levelCapacity = levelCount * 2 + 1;

    while (heapIndex >= levelCapacity && level < levelCount - 1) {
      heapIndex -= levelCapacity;
      level++;
      levelCapacity = Math.max(1, (levelCount - level) * 2 + 1);
    }

    const spread = glyph.fontSize * 0.5;
    const jitterX =
      (seededUnit(glyph.index + 83) - 0.5) * glyph.fontSize * 0.22;
    const jitterY =
      (seededUnit(glyph.index + 97) - 0.5) * glyph.fontSize * 0.18;

    return {
      rotation: (seededUnit(glyph.index + 109) - 0.5) * 0.72,
      x: width / 2 + (heapIndex - (levelCapacity - 1) / 2) * spread + jitterX,
      y: height - glyph.fontSize * (0.85 + level * 0.46) + jitterY,
    };
  }

  heapImpactOffsetForGlyph(glyph, streamCursor, glyphCount, width, height) {
    const base = this.heapPositionForGlyph(glyph, glyphCount, width, height);
    const latestImpactIndex = Math.floor(streamCursor - 2.45);
    const firstImpactIndex = Math.max(glyph.index + 1, latestImpactIndex - 5);
    const offset = { rotation: 0, x: 0, y: 0 };

    for (
      let impactIndex = firstImpactIndex;
      impactIndex <= latestImpactIndex;
      impactIndex++
    ) {
      if (impactIndex < 0 || impactIndex >= glyphCount) {
        continue;
      }

      const impactGlyph = { ...glyph, index: impactIndex };
      const impact = this.heapPositionForGlyph(
        impactGlyph,
        glyphCount,
        width,
        height
      );
      const age = streamCursor - (impactIndex + 2.45);
      const distance = Math.abs(base.x - impact.x);
      const range = glyph.fontSize * 3.8;

      if (age < 0 || age > 2.2 || distance > range) {
        continue;
      }

      const direction =
        base.x === impact.x
          ? seededUnit(glyph.index + 151) < 0.5
            ? -1
            : 1
          : Math.sign(base.x - impact.x);
      const force =
        (1 - distance / range) *
        Math.sin(age * Math.PI * 2.2) *
        Math.exp(-age * 1.25);

      offset.x += direction * glyph.fontSize * 0.34 * force;
      offset.y -= Math.abs(force) * glyph.fontSize * 0.46;
      offset.rotation += direction * force * 0.42;
    }

    return offset;
  }

  targetForGlyph(
    glyph,
    mode,
    now,
    width,
    height,
    glyphCount = this.glyphs.length
  ) {
    if (mode === "grid") {
      const columns = Math.max(Math.floor(Math.sqrt(glyphCount) * 1.45), 1);
      const cell = Math.min(
        (width * 0.68) / columns,
        (height * 0.7) / Math.ceil(glyphCount / columns)
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
      const angle = glyph.index * 0.24 + now * 0.00028;
      const radius = Math.sqrt(glyph.index) * Math.min(width, height) * 0.021;

      return {
        rotation: normalizedRotation(angle + Math.PI / 2),
        scale: 0.95 + Math.sin(angle) * 0.12,
        x: width / 2 + Math.cos(angle) * radius,
        y: height / 2 + Math.sin(angle) * radius,
      };
    }

    if (mode === "sorting") {
      const columns = 28;
      const rows = Math.ceil(glyphCount / columns);
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

    if (mode === "wave") {
      const columns = Math.max(24, Math.ceil(Math.sqrt(glyphCount) * 1.7));
      const column = glyph.index % columns;
      const row = Math.floor(glyph.index / columns);
      const rows = Math.ceil(glyphCount / columns);
      const x = width * 0.12 + column * ((width * 0.76) / columns);
      const baseline =
        height / 2 -
        (rows * glyph.fontSize * 0.72) / 2 +
        row * glyph.fontSize * 0.72;
      const wave = Math.sin(column * 0.42 + now * 0.0011 + row * 0.65);

      return {
        rotation: wave * 0.32,
        scale: 0.95 + Math.abs(wave) * 0.12,
        x,
        y: baseline + wave * Math.min(height * 0.08, 48),
      };
    }

    if (mode === "orbit") {
      const ringCount = 4;
      const ring = glyph.index % ringCount;
      const ringProgress =
        Math.floor(glyph.index / ringCount) /
        Math.max(1, Math.ceil(glyphCount / ringCount));
      const angle =
        ringProgress * Math.PI * 2 + now * (0.00016 + ring * 0.00005);
      const radius =
        Math.min(width, height) * (0.16 + ring * 0.085) +
        Math.sin(now * 0.0008 + glyph.index) * 10;

      return {
        rotation: normalizedRotation(angle + Math.PI / 2),
        scale: 0.9 + ring * 0.04,
        x: width / 2 + Math.cos(angle) * radius,
        y: height / 2 + Math.sin(angle) * radius,
      };
    }

    if (mode === "columns") {
      const columns = Math.max(
        8,
        Math.min(18, Math.ceil(Math.sqrt(glyphCount) * 0.7))
      );
      const column = glyph.wordIndex % columns;
      const row = Math.floor(glyph.index / columns);
      const rowHeight = glyph.fontSize * 0.72;
      const drift =
        ((now * 0.018 + glyph.index * 13 + column * 31) % (height * 0.78)) -
        height * 0.39;

      return {
        rotation: column % 2 ? -Math.PI / 2 : Math.PI / 2,
        scale: 0.92,
        x: width * 0.14 + column * ((width * 0.72) / Math.max(columns - 1, 1)),
        y: height / 2 + drift + (row % 3) * rowHeight * 0.34,
      };
    }

    if (mode === "dominos") {
      const phase = this.animationPhase(now - this.startedAt);
      const dominoProgress = clamp(
        (phase.cycle - phase.readEnd) /
          Math.max(phase.animateOutStart - phase.readEnd, 0.01),
        0,
        1
      );
      const fallProgress = smoothstep(
        0,
        1,
        (dominoProgress * glyphCount - glyph.dominoIndex) / 3
      );
      const direction = glyph.lineIndex % 2 === 0 ? 1 : -1;

      return {
        rotation: direction * fallProgress * Math.PI * 0.5,
        x: glyph.x + direction * glyph.fontSize * 0.28 * fallProgress,
        y: glyph.y + glyph.fontSize * 0.36 * fallProgress,
      };
    }

    if (mode === "slot_machine") {
      const columns = Math.max(8, Math.ceil(Math.sqrt(glyphCount * (16 / 9))));
      const rows = Math.ceil(glyphCount / columns);
      const cell = Math.min((width * 0.78) / columns, (height * 0.68) / rows);
      const gridWidth = (columns - 1) * cell;
      const gridHeight = (rows - 1) * cell;
      const baseColumn = glyph.index % columns;
      const baseRow = Math.floor(glyph.index / columns);
      const phase = this.animationPhase(now - this.startedAt);
      const slotProgress = clamp(
        (phase.cycle - phase.animateInEnd) /
          Math.max(phase.animateOutStart - phase.animateInEnd, 0.01),
        0,
        1
      );
      const operationLocationCount = 8;
      let operationCount = 0;
      const operations = [];

      for (
        let locationIndex = 0;
        locationIndex < operationLocationCount;
        locationIndex++
      ) {
        const seed = this.slotMachineSeed + locationIndex * 101;
        const shiftCount = 1 + Math.floor(seededUnit(seed + 29) * 3);

        operationCount += shiftCount;
        operations.push({ seed, shiftCount });
      }

      const operationProgress = clamp((slotProgress - 0.12) / 0.78, 0, 1);
      const activeStep = operationProgress * operationCount;
      let shiftedColumn = baseColumn;
      let shiftedRow = baseRow;
      let stepIndex = 0;

      for (const operation of operations) {
        const seed = operation.seed;
        const isRowShift = seededUnit(seed) < 0.5;
        const direction = seededUnit(seed + 17) < 0.5 ? -1 : 1;
        const row = Math.floor(seededUnit(seed + 31) * rows);
        const column = Math.floor(seededUnit(seed + 43) * columns);

        for (
          let shiftIndex = 0;
          shiftIndex < operation.shiftCount;
          shiftIndex++
        ) {
          const localProgress = clamp(activeStep - stepIndex, 0, 1);
          stepIndex++;

          if (localProgress <= 0) {
            continue;
          }

          const slideProgress =
            localProgress < 0.35 ? smoothstep(0, 1, localProgress / 0.35) : 1;

          if (isRowShift) {
            if (Math.round(shiftedRow) === row) {
              shiftedColumn += direction * slideProgress;
            }
          } else {
            if (Math.round(shiftedColumn) === column) {
              shiftedRow += direction * slideProgress;
            }
          }

          shiftedColumn = (shiftedColumn + columns) % columns;
          shiftedRow = (shiftedRow + rows) % rows;
        }
      }

      return {
        rotation: 0,
        scale: 0.94,
        x: width / 2 - gridWidth / 2 + shiftedColumn * cell,
        y: height / 2 - gridHeight / 2 + shiftedRow * cell,
      };
    }

    if (mode === "single_out") {
      if (glyph.isLongestWord) {
        return {
          rotation: 0,
          scale: 1.12,
          x: width / 2 + glyph.wordCenterOffset,
          y: height / 2,
        };
      }

      const padding = Math.min(width, height) * 0.08;
      const constellationWidth = Math.max(width - padding * 2, 1);
      const constellationHeight = Math.max(height - padding * 2, 1);
      const backgroundWordCount = Math.max((glyph.totalWordCount || 1) - 1, 1);
      const constellationColumns = Math.max(
        3,
        Math.ceil(
          Math.sqrt(
            backgroundWordCount * (constellationWidth / constellationHeight)
          )
        )
      );
      const constellationRows = Math.max(
        2,
        Math.ceil(backgroundWordCount / constellationColumns)
      );
      const backgroundWordIndex =
        glyph.wordIndex > glyph.longestWordIndex
          ? glyph.wordIndex - 1
          : glyph.wordIndex;
      const cellWidth = constellationWidth / constellationColumns;
      const cellHeight = constellationHeight / constellationRows;
      const cellColumn = backgroundWordIndex % constellationColumns;
      const cellRow = Math.floor(backgroundWordIndex / constellationColumns);
      const jitterX =
        (seededUnit(glyph.wordIndex + 11) - 0.5) * cellWidth * 0.36;
      const jitterY =
        (seededUnit(glyph.wordIndex + 41) - 0.5) * cellHeight * 0.36;
      const orbit =
        Math.sin(now * 0.001 + glyph.wordIndex * 0.9) *
        Math.min(width, height) *
        0.018;
      const wordHalfWidth = (glyph.wordHalfWidth || glyph.fontSize) * 0.88;
      const wordX =
        ((cellColumn + 0.5) * cellWidth +
          jitterX +
          now * (0.018 + seededUnit(glyph.wordIndex + 23) * 0.012)) %
        constellationWidth;
      const wordY =
        ((cellRow + 0.5) * cellHeight +
          jitterY +
          now * (0.006 + seededUnit(glyph.wordIndex + 59) * 0.006)) %
        constellationHeight;
      const centerMin = padding + wordHalfWidth + Math.abs(orbit);
      const centerMax = width - padding - wordHalfWidth - Math.abs(orbit);
      const wordCenterX =
        centerMin < centerMax
          ? clamp(padding + wordX, centerMin, centerMax)
          : width / 2;

      return {
        alpha: 0.58,
        rotation: Math.sin(now * 0.0007 + glyph.wordIndex) * 0.08,
        scale: 0.86,
        x: wordCenterX + glyph.wordCenterOffset * 0.88 + orbit,
        y: padding + wordY,
      };
    }

    if (mode === "heap") {
      const body = this.heapPhysics?.bodies[glyph.index];

      return {
        rotation: body?.rotation ?? -0.08,
        scale: body?.state === "queued" ? 0.92 : 0.98,
        x:
          body?.x ??
          -glyph.fontSize * 2 - glyph.columnIndex * glyph.fontSize * 0.16,
        y:
          body?.y ??
          -glyph.fontSize * 3 + glyph.lineIndex * glyph.fontSize * 0.58,
      };
    }

    return {
      rotation: 0,
      scale: 1,
      x: glyph.x,
      y: glyph.y,
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
          class={{this.sectionClass}}
          aria-label={{this.ariaLabel}}
          {{didInsert this.setupStage}}
          {{willDestroy this.teardownStage}}
        >
          {{#if this.isPageMode}}
            <div
              class="text-jumble-screen-saver__animation-menu"
              {{didInsert this.setupAnimationMenu}}
            >
              <button
                type="button"
                class="text-jumble-screen-saver__animation-menu-trigger"
                aria-expanded={{this.isAnimationMenuOpen}}
                {{on "click" this.toggleAnimationMenu}}
              >
                {{i18n (themePrefix "text_jumble.animation_styles.title")}}
              </button>

              {{#if this.isAnimationMenuOpen}}
                <div class="text-jumble-screen-saver__animation-menu-panel">
                  {{#each this.animationStyleOptions as |mode|}}
                    <label class="text-jumble-screen-saver__animation-option">
                      <input
                        type="checkbox"
                        value={{mode.id}}
                        checked={{mode.selected}}
                        {{on "change" this.toggleAnimationStyle}}
                      />
                      {{i18n (themePrefix mode.labelKey)}}
                    </label>
                  {{/each}}
                </div>
              {{/if}}
            </div>
          {{/if}}

          <canvas
            class="text-jumble-screen-saver__canvas"
            {{didInsert this.setupCanvas}}
          ></canvas>

          {{#if this.sourceTitle}}
            <div class="text-jumble-screen-saver__source">
              {{#if this.sourceUrl}}
                <a href={{this.sourceUrl}}>{{this.sourceTitle}}</a>
              {{else}}
                {{this.sourceTitle}}
              {{/if}}
            </div>
          {{/if}}
        </section>
      {{/if}}
    </div>
  </template>
}
