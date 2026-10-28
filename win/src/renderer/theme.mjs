/** Shared palette contract mirrored by ReaderTheme in mac/current/Sources/Models.swift. */
export const themePresets = Object.freeze([
  { hex: 'F5F7F3', label: '苔绿', accent: '518C76' },
  { hex: 'E5ECF3', label: '雾蓝', accent: '587E9F' },
  { hex: 'EBE9ED', label: '灰紫', accent: '81718C' },
  { hex: 'EEEAEC', label: '灰粉', accent: '977B87' },
  { hex: 'E9EAEC', label: '灰色', accent: '707782' },
  { hex: '253247', label: '深蓝', accent: 'A8BCD6' },
  { hex: '202124', label: '黑色', accent: 'B5B8BE' }
]);
const normalized = value => /^[0-9A-F]{6}$/.test(String(value).replace(/^#/, '').toUpperCase()) ? String(value).replace(/^#/, '').toUpperCase() : 'F5F7F3';
export const rgb = hex => [0, 2, 4].map(offset => parseInt(normalized(hex).slice(offset, offset + 2), 16));
export function mix(a, b, amount) {
  const x = rgb(a), y = rgb(b);
  return x.map((v, index) => Math.round(v + (y[index] - v) * amount).toString(16).padStart(2, '0')).join('').toUpperCase();
}
export function luminance(hex) {
  const linear = rgb(hex).map(n => n / 255).map(n => n <= .04045 ? n / 12.92 : ((n + .055) / 1.055) ** 2.4);
  return linear[0] * .2126 + linear[1] * .7152 + linear[2] * .0722;
}
export function themeFor(value) {
  const base = normalized(value), dark = luminance(base) < .23;
  const accent = themePresets.find(p => p.hex === base)?.accent || mix(base, dark ? 'DFE5EF' : '25342E', dark ? .72 : .60);
  const ink = dark ? 'E6EBF0' : base === 'F5F7F3' ? '283C36' : mix(accent, '182027', .78);
  const palette = {
    base, dark, accent, ink,
    muted: dark ? mix(ink, base, .32) : mix(ink, base, .48),
    sidebar: mix(base, 'FFFFFF', dark ? .02 : .12),
    center: mix(base, 'FFFFFF', dark ? .04 : .72),
    canvas: dark ? mix(base, '000000', .10) : mix(base, ink, .045),
    card: mix(base, 'FFFFFF', dark ? .075 : .82),
    raised: mix(base, 'FFFFFF', dark ? .11 : .92),
    border: mix(base, dark ? 'FFFFFF' : ink, dark ? .20 : .15),
    hover: mix(base, accent, dark ? .14 : .10),
    selected: mix(base, accent, dark ? .23 : .18),
    userBubble: mix(base, accent, dark ? .13 : .085),
    aiBubble: mix(base, accent, dark ? .20 : .145),
    error: dark ? 'E4B49B' : '9D624B'
  };
  palette.css = Object.fromEntries(Object.entries(palette).filter(([key, val]) => key !== 'dark' && typeof val === 'string').map(([key, val]) => [`--${key.replace(/[A-Z]/g, x => `-${x.toLowerCase()}`)}`, `#${val}`]));
  palette.css['--sidebar-rgb'] = rgb(palette.sidebar).join(' ');
  palette.css['--center-rgb'] = rgb(palette.center).join(' ');
  palette.css['--raised-rgb'] = rgb(palette.raised).join(' ');
  return palette;
}
