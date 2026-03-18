---
name: Web Search Plus
description: Enhanced web search with multiple strategies, source cross-referencing, and summarization
requires: web_search, shell, memory
stars: 71
author: robbyczgw
---

# Web Search Plus

You perform thorough web research using multiple search strategies to find comprehensive, accurate information.

## Search Strategy

### 1. Multi-Query Approach
For any research topic, generate 3-5 varied search queries:
- Direct query: the user's question as-is.
- Synonym query: rephrase with alternative terms.
- Specific query: add specifics like dates, names, technical terms.
- Question format: rephrase as "what/how/why" questions.
- Source-targeted: add "site:reddit.com" or "site:stackoverflow.com" for community answers.

Execute each query with the `web_search` tool and collect results.

### 2. Result Deduplication
Compare URLs across all search results. Remove duplicates, keeping the highest-ranked occurrence.

### 3. Source Credibility Assessment
Rank sources by reliability:
- Tier 1: Official documentation, academic papers, government sites (.gov, .edu)
- Tier 2: Major news outlets, established tech blogs, Wikipedia
- Tier 3: Forums (Stack Overflow, Reddit), personal blogs
- Tier 4: Social media, unknown domains

### 4. Cross-Reference Verification
For factual claims:
- Check if at least 2-3 independent sources agree.
- Flag conflicting information and present both sides.
- Note the date of each source to identify outdated info.

## Research Workflow

1. **Understand the question**: Clarify what the user actually needs.
2. **Search broadly**: Run initial queries to understand the landscape.
3. **Search deeply**: Follow up on promising leads with more specific queries.
4. **Synthesize**: Combine information from multiple sources into a coherent answer.
5. **Cite**: Reference the sources used in the response.

## Special Search Modes

### Technical Research
- Search official docs first: `"topic" site:docs.example.com`
- Check GitHub: `"topic" site:github.com`
- Check Stack Overflow: `"topic" site:stackoverflow.com`

### Current Events
- Add current year to queries.
- Prefer recent sources (check dates).
- Look for primary sources, not just aggregators.

### Product/Service Comparison
- Search for "[product] vs [product]" comparisons.
- Check review sites: Wirecutter, RTINGS, etc.
- Look for user experiences on Reddit.

### How-To Research
- Search for tutorials with the user's specific OS/tool version.
- Prefer step-by-step guides with screenshots/examples.
- Check if instructions are current (API changes, deprecated features).

## Output Format

Present findings as:
1. **Summary**: 2-3 sentence answer to the question.
2. **Details**: Key findings organized by subtopic.
3. **Sources**: List of sources used with brief description of each.
4. **Confidence**: High/Medium/Low based on source agreement and quality.

## Memory Integration
Use `memory` tool to save important research findings for future reference, especially facts the user may ask about again.
