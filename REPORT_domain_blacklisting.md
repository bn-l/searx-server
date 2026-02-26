# SearXNG Domain Blacklisting

## 1. Hostnames Plugin (built-in, server-side)

The official built-in method. Configured via top-level keys in `settings.yml`.

### Enabling the plugin

```yaml
plugins:
  searx.plugins.hostnames.SXNGPlugin:
    active: true
```

### Configuration options

All four options live under the `hostnames:` key:

```yaml
hostnames:
  # Completely remove results from these domains
  remove:
    - '(.*\.)?facebook\.com$'
    - '(.*\.)?pinterest\.com$'

  # Rewrite URLs (e.g. redirect to privacy frontends)
  replace:
    '(.*\.)?youtube\.com$': 'invidious.example.com'
    '(.*\.)?reddit\.com$': 'old.reddit.com'

  # Boost these domains to the top of results
  high_priority:
    - '(.*\.)?wikipedia\.org$'

  # Demote these domains to the bottom of results
  low_priority:
    - '(.*\.)?google(\..*)?$'
```

If a URL matches both `high_priority` and `low_priority`, high priority wins.

### External file support

For large lists, point to an external YAML file in the same directory as `settings.yml`:

```yaml
hostnames:
  replace: 'rewrite-hosts.yml'
  remove:
    - '(.*\.)?facebook\.com$'
```

### Performance considerations

Regex patterns are compiled once at startup (negligible cost). At query time, the plugin's `on_result()` runs on **every result** returned by every engine, doing a linear scan of all patterns:

1. Iterates all `remove` patterns (`pattern.search(netloc)`)
2. Iterates `remove` again + `replace` inside `filter_url_field()`
3. Iterates all `low_priority` patterns
4. Iterates all `high_priority` patterns

There is no indexing, trie, or hash-based lookup — it is `O(results * patterns)`.

| List size | Expected impact |
|---|---|
| ~10-50 patterns | Effectively zero. |
| ~100-500 patterns | Fine for a personal instance. Low single-digit ms added per search. |
| 1000+ patterns | Could start to matter. 50 results * 1000 patterns = 50k regex matches per search. |
| 10,000+ patterns | Needs benchmarking. Maintainers explored FST (Finite State Transducers) as an alternative but never integrated it. |

In practice, the bottleneck in SearXNG is almost always waiting for upstream engines to respond (network I/O), not post-processing. A moderately large hostname list is unlikely to be the thing that makes searches feel slow.

For reference, maintainer dalf prototyped FST-based lookups in [issue #304](https://github.com/searxng/searxng/issues/304) and achieved sub-millisecond lookups for 20 hosts against 34 million entries — but the current plugin still uses the naive linear regex approach.

---

## 2. Search query syntax (`-site:`)

Most upstream engines (Google, DuckDuckGo, Bing) support per-query filtering:

```
my search query -site:pinterest.com -site:facebook.com
```

Not persistent — works on a per-query basis without any config changes.

---

## 3. Browser extensions (client-side)

- **uBlacklist** — Chrome, Firefox, Safari. Adds a "Block this site" link to results. Supports subscription lists. Has partial SearXNG support.
- **uBlock Origin + Let's Block It!** — Generate content filters that hide results from specific domains across multiple search engines.

---

## 4. Community blocklists

Curated lists of SEO spam / low-quality domains that can be fed into the hostnames plugin:

- [uBlock-Origin-dev-filter](https://github.com/nickkozlov/uBlock-Origin-dev-filter)
- [The Big Blocklist Collection](https://github.com/nickkozlov/Big-Blocklist-Collection)
- [GitHub discussion #970](https://github.com/searxng/searxng/discussions/970) — community-shared list of commonly blocked domains

---

## Sources

- [SearXNG Hostnames Plugin docs](https://docs.searxng.org/dev/plugins/hostnames.html)
- [SearXNG default settings.yml](https://github.com/searxng/searxng/blob/master/searx/settings.yml)
- [Plugin source code — hostnames.py](https://github.com/searxng/searxng/blob/master/searx/plugins/hostnames.py)
- [GitHub issue #304 — URL rewriting and filtering (performance discussion)](https://github.com/searxng/searxng/issues/304)
- [GitHub issue #2619 — external list file feature request](https://github.com/searxng/searxng/issues/2619)
- [GitHub issue #4263 — syntax change](https://github.com/searxng/searxng/issues/4263)
- [Reddit: Hostname replace plugin](https://www.reddit.com/r/Searx/comments/rs4mi4/is_there_any_way_to_exclude_particular_domains/)
- [Reddit: Plugin syntax change](https://www.reddit.com/r/Searx/comments/1j9cxnr/hostname_replace_plugin_no_longer_blocking/)
- [How to block domains from search results — Luke Harris](https://www.lkhrs.com/blog/block-domains-from-search/)
