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

const MODES = [
  "grid",
  "spiral",
  "sorting",
  "slots",
  "wave",
  "orbit",
  "columns",
  "dominos",
  "slot_machine",
];
const ANIMATION_MS = 18000;
const ANIMATION_RETURN_RATIO = 0.28;
const SPECTRUM_PALETTE_LEVEL_COUNT = 8;
const STRUCTURED_PALETTE_LEVEL_COUNT = 12;
const MAX_GLYPHS = 1100;
const TEXT_TRANSITION_MS = 1600;
const TEXT_TYPE_TRANSITION_MS = 3200;
const TEXT_TYPE_FADE_OUT_MS = 1000;
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
  @service router;

  @tracked isVisible = false;
  @tracked sourceTitle = "";

  animationFrame = null;
  animationModeIndex = -1;
  canvas = null;
  colorPaletteMode = "spectrum";
  context = null;
  glyphs = [];
  glyphSpriteCache = new Map();
  idleTimer = null;
  lastQuoteText = null;
  lastTopicId = null;
  outgoingGlyphs = [];
  paragraph = "";
  paragraphTimer = null;
  renderer = "canvas";
  resizeObserver = null;
  root = null;
  slotMachineSeed = 0;
  stage = null;
  startedAt = 0;
  transitionMode = "crossfade";
  transitionStartedAt = null;
  webgl = null;

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

    this.paragraphTimer = setTimeout(async () => {
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
    } catch {
      this.paragraph = fallbackText;
      this.sourceTitle = "";
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

  prepareGlyphs({ transition = false } = {}) {
    if (!this.context || !this.canvas || !this.paragraph) {
      return;
    }

    if (transition || this.animationModeIndex < 0) {
      this.animationModeIndex = (this.animationModeIndex + 1) % MODES.length;
    }
    this.slotMachineSeed = Math.random() * 10000;

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
    const phase = this.animationPhase(elapsed);
    const mode = this.currentMode();
    const jumbleAmount =
      smoothstep(phase.readEnd, phase.animateInEnd, phase.cycle) *
      (1 - smoothstep(phase.animateOutStart, phase.animateEnd, phase.cycle));

    this.clearRenderer(ctx, width, height);

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
        background.alpha
      );
      gl.clear(gl.COLOR_BUFFER_BIT);
      return;
    }

    ctx.clearRect(0, 0, width, height);
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
        mode === "slot_machine"
          ? 0
          : Math.sin(now * 0.0017 + glyph.index * 0.37) * 7 * jumbleAmount;
      const x = glyph.x + (target.x - glyph.x) * jumbleAmount + wave;
      const y = glyph.y + (target.y - glyph.y) * jumbleAmount;
      const rotation = (target.rotation || 0) * jumbleAmount;
      const scale = 1 + ((target.scale || 1) - 1) * jumbleAmount;
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
          alpha * smoothstep(0, 1, glyphReveal) * (0.94 + jumbleAmount * 0.06)
        );
      } else {
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(rotation);
        ctx.scale(scale, scale);
        ctx.font = `${glyph.fontSize}px Georgia, serif`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.globalAlpha =
          alpha * smoothstep(0, 1, glyphReveal) * (0.94 + jumbleAmount * 0.06);
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
    ctx.font = `${glyph.fontSize}px Georgia, serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.lineWidth = Math.max(glyph.fontSize * 0.08, 1.4);
    ctx.strokeStyle = strokeColor;
    ctx.fillStyle = fillColor;
    ctx.strokeText(glyph.char, 0, 0);
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
    const configured = settings.text_jumble_animation_mode;

    if (configured && configured !== "mixed") {
      return configured;
    }

    return MODES[Math.max(this.animationModeIndex, 0) % MODES.length];
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
      alpha: 0.24,
      rgb: parseRgb(stageRgb, [8, 11, 16]),
    };
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
      isLightBackground ? "0.12" : "0.1"
    );
    this.stage.style.setProperty(
      "--text-jumble-filter-opacity-end",
      isLightBackground ? "0.2" : "0.16"
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
      const operationCount = 7;
      const operationProgress = clamp((slotProgress - 0.12) / 0.78, 0, 1);
      const activeStep = operationProgress * operationCount;
      let shiftedColumn = baseColumn;
      let shiftedRow = baseRow;

      for (let step = 0; step < operationCount; step++) {
        const localProgress = clamp(activeStep - step, 0, 1);

        if (localProgress <= 0) {
          continue;
        }

        const slideProgress =
          localProgress < 0.35 ? smoothstep(0, 1, localProgress / 0.35) : 1;
        const seed = this.slotMachineSeed + step * 101;
        const isRowShift = seededUnit(seed) < 0.5;
        const direction = seededUnit(seed + 17) < 0.5 ? -1 : 1;

        if (isRowShift) {
          const row = Math.floor(seededUnit(seed + 31) * rows);

          if (Math.round(shiftedRow) === row) {
            shiftedColumn += direction * slideProgress;
          }
        } else {
          const column = Math.floor(seededUnit(seed + 43) * columns);

          if (Math.round(shiftedColumn) === column) {
            shiftedRow += direction * slideProgress;
          }
        }

        shiftedColumn = (shiftedColumn + columns) % columns;
        shiftedRow = (shiftedRow + rows) % rows;
      }

      return {
        rotation: 0,
        scale: 0.94,
        x: width / 2 - gridWidth / 2 + shiftedColumn * cell,
        y: height / 2 - gridHeight / 2 + shiftedRow * cell,
      };
    }

    const railCount = Math.max(5, Math.min(11, Math.ceil(glyphCount / 85)));
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
