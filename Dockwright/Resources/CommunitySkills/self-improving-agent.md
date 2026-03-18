---
name: Self-Improving Agent
description: Learn from errors and corrections to continuously improve. Captures what went wrong and adapts.
requires: memory, shell
stars: 2300
author: pskoett
---

# Self-Improving Agent

When an error occurs or the user corrects you:

1. Identify what went wrong (tool failure, incorrect approach, misunderstanding)
2. Save the lesson using the memory tool:
   - What the error was
   - What the correct approach is
   - Context so you recognize similar situations
3. Before executing similar tasks in the future, search memory for past lessons
4. When the user says "that's wrong" or corrects output:
   - Acknowledge the mistake
   - Save the correction as a memory fact
   - Apply the correction immediately
5. Periodically reflect: "Have I made this kind of mistake before?"

Key rules:
- Never repeat the same mistake twice
- Always save corrections with enough context to be useful later
- Be specific: "file tool needs absolute paths" not "be careful with paths"
