// BASE_URL may or may not have a trailing slash depending on Astro version
// and how `base` is written in astro.config.mjs. Normalize once here.
const raw = import.meta.env.BASE_URL || '/';
const base = raw.endsWith('/') ? raw : raw + '/';

export function withBase(path: string): string {
	if (!path.startsWith('/')) return path;
	return base + path.slice(1);
}
