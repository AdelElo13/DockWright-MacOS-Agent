---
name: Multi-Engine Search
description: Search the web using multiple search engines for broader, more diverse results
requires: web_search, shell
stars: 134
author: ide-rea
---

# Multi-Engine Search

You perform comprehensive web searches across multiple search engines to get broader, more diverse results than any single engine provides.

## Strategy

Different search engines have different biases, indexes, and ranking algorithms. By searching multiple engines and combining results, you get:
- Better coverage of niche or regional content.
- Multiple perspectives and source diversity.
- Results that one engine might miss or rank low.

## Search Execution

### Primary Search
Use `web_search` tool with the user's query. This is the fastest and most integrated option.

### Supplementary Engines via curl

**DuckDuckGo Instant Answer:**
```
curl -s "https://api.duckduckgo.com/?q=QUERY&format=json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('AbstractText'):
    print(f'Summary: {data[\"AbstractText\"]}')
    print(f'Source: {data[\"AbstractSource\"]}')
for r in data.get('RelatedTopics', [])[:5]:
    if isinstance(r, dict) and 'Text' in r:
        print(f'- {r[\"Text\"][:120]}')
"
```

**Wikipedia Direct (for factual queries):**
```
curl -s "https://en.wikipedia.org/api/rest_v1/page/summary/QUERY" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Title: {data.get(\"title\", \"N/A\")}')
print(f'Extract: {data.get(\"extract\", \"No result\")}')
"
```

**StackOverflow (for technical queries):**
```
curl -s "https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=QUERY&site=stackoverflow" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', [])[:5]:
    print(f'- [{item[\"score\"]}] {item[\"title\"]}')
    print(f'  {item[\"link\"]}')
"
```

**Reddit (for community discussions):**
Use `web_search` tool with query: `"QUERY site:reddit.com"`

**GitHub (for code/projects):**
```
curl -s "https://api.github.com/search/repositories?q=QUERY&sort=stars&per_page=5" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for repo in data.get('items', []):
    print(f'- {repo[\"full_name\"]} ({repo[\"stargazers_count\"]} stars)')
    print(f'  {repo[\"description\"]}')
"
```

## Result Combination

### Deduplication
Compare URLs across all results. Merge duplicates, noting which engines found each result (indicates higher relevance).

### Ranking
Score results by:
1. Appeared in multiple engines (+3 per engine).
2. Source credibility (official docs +2, major publications +1).
3. Recency (last 6 months +1).
4. Relevance to original query.

### Presentation
Present combined results grouped by:
- **Top Results**: Found by multiple engines, high relevance.
- **Web Results**: Standard search results, deduplicated.
- **Community Insights**: Reddit, StackOverflow discussions.
- **Code/Projects**: GitHub repositories (if relevant).
- **Quick Facts**: Wikipedia/DuckDuckGo instant answers.

## Language Support
When the user's query is in a non-English language:
- Search in both the original language and English.
- Note which results are in which language.
- Translate key findings if needed.
