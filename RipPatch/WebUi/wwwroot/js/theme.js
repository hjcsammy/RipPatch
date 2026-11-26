// 主题：深色 / 浅色 / 跟随系统。
//
// 为什么单独一个模块：主题要在第一帧就生效（否则会「先白后黑」闪一下），
// 所以 index.html 里用内联脚本先写 data-theme，这里再接管后续切换。
// 颜色的真实来源是 css/app.css 里 `:root[data-theme=...]` 定义的 Fluent token。
//
// 用户选择存 localStorage；"system" 模式下监听系统配色变化并实时跟随。

const STORAGE_KEY = 'arp.theme';
const MEDIA = '(prefers-color-scheme: dark)';

/** 当前可选项，界面上的按钮顺序也按这个来。 */
export const THEMES = ['system', 'dark', 'light'];

const listeners = new Set();

function systemPrefersDark() {
    try {
        return window.matchMedia(MEDIA).matches;
    } catch {
        return true; // 取不到就当深色，和默认一致
    }
}

/** 把 "system" 解析成真正的 "dark" / "light"。 */
function resolve(mode) {
    return mode === 'system' ? (systemPrefersDark() ? 'dark' : 'light') : mode;
}

function readStored() {
    try {
        const value = localStorage.getItem(STORAGE_KEY);
        return THEMES.includes(value) ? value : 'system';
    } catch {
        return 'system';
    }
}

function apply(mode) {
    const effective = resolve(mode);
    document.documentElement.dataset.theme = effective;
    // 让浏览器知道当前配色，影响原生滚动条、输入框、右键菜单等
    document.documentElement.style.colorScheme = effective;
    for (const listener of listeners) {
        try {
            listener(mode, effective);
        } catch {
            // 某个监听者出错不该影响主题本身
        }
    }
}

let currentMode = readStored();

/**
 * 用户选择的模式（'system' / 'dark' / 'light'）。
 */
export function getThemeMode() {
    return currentMode;
}

/** 实际生效的配色（'dark' / 'light'）。 */
export function getEffectiveTheme() {
    return resolve(currentMode);
}

/**
 * 设置主题。传 'system' 就跟随系统。
 */
export function setThemeMode(mode) {
    if (!THEMES.includes(mode)) {
        return;
    }
    currentMode = mode;
    try {
        localStorage.setItem(STORAGE_KEY, mode);
    } catch {
        // 隐私模式写不进去，只是记不住选择，不影响本次生效
    }
    apply(mode);
}

/** 按 system / dark / light 循环切换（标题栏那个按钮用）。 */
export function cycleThemeMode() {
    const index = THEMES.indexOf(currentMode);
    setThemeMode(THEMES[(index + 1) % THEMES.length]);
}

/** 订阅主题变化，返回取消订阅函数。 */
export function onThemeChange(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
}

/** 初始化：接管首屏 data-theme，并监听系统配色变化。 */
export function initTheme() {
    // index.html 的内联脚本已经按 localStorage 设过 data-theme，
    // 这里重新算一次，确保「系统」模式下拿到的是最新的系统值。
    apply(currentMode);

    try {
        const media = window.matchMedia(MEDIA);
        const onChange = () => {
            // 只有「跟随系统」时才需要响应；手动指定深/浅色时系统变化与我无关。
            if (currentMode === 'system') {
                apply('system');
            }
        };
        if (typeof media.addEventListener === 'function') {
            media.addEventListener('change', onChange);
        } else if (typeof media.addListener === 'function') {
            // 旧版 WebView2 只支持 addListener
            media.addListener(onChange);
        }
    } catch {
        // 没有 matchMedia 就固定用已选的值
    }
}
