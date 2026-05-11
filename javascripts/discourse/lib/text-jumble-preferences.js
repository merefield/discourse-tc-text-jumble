export const TEXT_JUMBLE_SCREEN_SAVER_PREFERENCE_CHANGED =
  "text-jumble:screen-saver-preference-changed";
export const TEXT_JUMBLE_ANIMATION_STYLES_CHANGED =
  "text-jumble:animation-styles-changed";

export const TEXT_JUMBLE_ANIMATION_MODES = [
  { id: "grid", labelKey: "text_jumble.animation_styles.grid" },
  { id: "spiral", labelKey: "text_jumble.animation_styles.spiral" },
  { id: "sorting", labelKey: "text_jumble.animation_styles.sorting" },
  { id: "wave", labelKey: "text_jumble.animation_styles.wave" },
  { id: "orbit", labelKey: "text_jumble.animation_styles.orbit" },
  { id: "columns", labelKey: "text_jumble.animation_styles.columns" },
  { id: "dominos", labelKey: "text_jumble.animation_styles.dominos" },
  {
    id: "slot_machine",
    labelKey: "text_jumble.animation_styles.slot_machine",
  },
  { id: "single_out", labelKey: "text_jumble.animation_styles.single_out" },
  { id: "heap", labelKey: "text_jumble.animation_styles.heap" },
];
export const TEXT_JUMBLE_ANIMATION_MODE_IDS = TEXT_JUMBLE_ANIMATION_MODES.map(
  (mode) => mode.id
);

const SCREEN_SAVER_DISABLED_KEY =
  "discourse-tc-text-jumble:screen-saver-disabled";
const ANIMATION_STYLES_KEY = "discourse-tc-text-jumble:animation-styles";

function preferenceKey(user) {
  return user?.id
    ? `${SCREEN_SAVER_DISABLED_KEY}:${user.id}`
    : SCREEN_SAVER_DISABLED_KEY;
}

function animationStylesKey(user) {
  return user?.id ? `${ANIMATION_STYLES_KEY}:${user.id}` : ANIMATION_STYLES_KEY;
}

function normalizeAnimationModes(value) {
  const modes = Array.isArray(value)
    ? value
    : `${value || ""}`.split(/[|,\n]/).map((mode) => mode.trim());

  const selected = new Set(modes);

  return TEXT_JUMBLE_ANIMATION_MODE_IDS.filter((mode) => selected.has(mode));
}

function defaultAnimationModes(settings) {
  return normalizeAnimationModes(settings.text_jumble_default_animation_styles);
}

export function isScreenSaverDisabled(user) {
  try {
    return window.localStorage?.getItem(preferenceKey(user)) === "true";
  } catch {
    return false;
  }
}

export function setScreenSaverDisabled(user, disabled) {
  try {
    const key = preferenceKey(user);

    if (disabled) {
      window.localStorage?.setItem(key, "true");
    } else {
      window.localStorage?.removeItem(key);
    }
  } catch {
    // localStorage can be unavailable in restricted browser contexts.
  }

  window.dispatchEvent(
    new CustomEvent(TEXT_JUMBLE_SCREEN_SAVER_PREFERENCE_CHANGED, {
      detail: { disabled },
    })
  );
}

export function selectedAnimationModes(user, settings) {
  try {
    const stored = window.localStorage?.getItem(animationStylesKey(user));

    if (stored !== null) {
      return normalizeAnimationModes(JSON.parse(stored));
    }
  } catch {
    // Fall back to the theme default when localStorage is unavailable or stale.
  }

  return defaultAnimationModes(settings);
}

export function setSelectedAnimationModes(user, modes) {
  const selectedModes = normalizeAnimationModes(modes);

  try {
    window.localStorage?.setItem(
      animationStylesKey(user),
      JSON.stringify(selectedModes)
    );
  } catch {
    // localStorage can be unavailable in restricted browser contexts.
  }

  window.dispatchEvent(
    new CustomEvent(TEXT_JUMBLE_ANIMATION_STYLES_CHANGED, {
      detail: { selectedModes },
    })
  );
}
