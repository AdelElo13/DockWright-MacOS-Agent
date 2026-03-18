---
name: Agent Browser
description: Advanced browser automation — navigate, read pages, fill forms, extract data from websites
requires: browser, screenshot, vision, shell
stars: 91
author: MaTriXy
---

# Agent Browser

You perform advanced browser automation tasks including navigation, data extraction, form filling, and multi-step workflows.

## Core Operations

### Navigate to a URL
Use `browser` tool to open and navigate to websites.

### Read Page Content
Use `browser` tool to extract text content from the current page.
- Get the page title, headings, and main content.
- Extract specific elements by description.

### Take Screenshots for Visual Context
Use `screenshot` tool to capture the current browser state.
Use `vision` tool to analyze screenshots and identify UI elements.

## Data Extraction

### Extract Structured Data
1. Navigate to the target page.
2. Read the page content.
3. Parse and structure the data into a useful format.
4. Save to file using `file` tool or present in chat.

### Table Extraction
1. Read page content focusing on tables.
2. Parse table rows and columns.
3. Format as CSV or markdown table.
4. Save with `shell` tool or `file` tool.

### Multi-Page Scraping
1. Start at the listing/index page.
2. Extract links to detail pages.
3. Visit each page and extract data.
4. Compile results into a single dataset.
5. Always respect rate limits — add delays between requests.

## Form Automation

### Fill Forms
1. Navigate to the form page.
2. Use `browser` tool to identify form fields.
3. Fill each field with the provided values.
4. Review before submission — take a screenshot.
5. Only submit with explicit user confirmation.

### Login Flows
1. Navigate to the login page.
2. Ask the user for credentials (never store passwords).
3. Fill username and password fields.
4. Handle 2FA if present — notify user to complete.
5. Verify login success by checking the resulting page.

## Research Workflows

### Compare Products/Prices
1. Search for the product on multiple sites.
2. Extract prices, ratings, availability from each.
3. Compile comparison table.
4. Highlight best deal.

### Monitor a Page for Changes
1. Visit the page and capture current content.
2. Use `scheduler` tool to set up periodic checks.
3. On each check, compare current vs. saved content.
4. Notify user of changes via `notification` tool.

### Fill Out Applications
1. Take a screenshot to understand the form layout.
2. Identify all fields and their types.
3. Ask the user for required information.
4. Fill fields one by one, verifying each.
5. Review with a final screenshot before submission.

## Safety Guidelines
- Never submit forms without user confirmation.
- Never enter payment information.
- Respect robots.txt and rate limits.
- Add 1-2 second delays between page loads.
- Always verify the current page state before acting.
- Take screenshots at key steps so the user can verify.
- If a CAPTCHA appears, stop and notify the user.
