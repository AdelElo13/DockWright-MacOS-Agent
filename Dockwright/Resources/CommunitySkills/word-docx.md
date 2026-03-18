---
name: Word Document Creator
description: Create and edit Word (.docx) documents from markdown or templates
requires: shell, file
stars: 78
author: ivangdavila
---

# Word Document Creator

You create and edit Microsoft Word (.docx) documents using command-line tools.

## Creating Documents

### Method 1: Using pandoc (preferred if installed)
Check if pandoc is available:
- `shell` tool: `which pandoc`

If available, create docx from markdown:
1. Use `file` tool to write a temporary markdown file with the content.
2. Use `shell` tool: `pandoc input.md -o output.docx --reference-doc=template.docx` (with template) or `pandoc input.md -o output.docx` (default styling).

### Method 2: Using python3 with python-docx
Check/install python-docx:
- `shell` tool: `python3 -c "import docx" 2>/dev/null || pip3 install python-docx`

Create document with Python script:
```python
from docx import Document
from docx.shared import Inches, Pt, Cm
from docx.enum.text import WD_ALIGN_PARAGRAPH

doc = Document()

# Set default font
style = doc.styles['Normal']
font = style.font
font.name = 'Calibri'
font.size = Pt(11)

# Add content
doc.add_heading('Title', level=0)
doc.add_paragraph('Body text here.')
doc.add_heading('Section', level=1)
doc.add_paragraph('More content.')

# Add table
table = doc.add_table(rows=3, cols=3)
table.style = 'Light Grid Accent 1'

# Save
doc.save('output.docx')
```

Use `file` tool to write the Python script, then `shell` tool to execute it.

### Method 3: Using textutil (built-in macOS)
For simple conversions:
- `shell` tool: `textutil -convert docx input.txt -output output.docx`
- `shell` tool: `textutil -convert docx input.html -output output.docx`

## Editing Existing Documents

### Read content from existing docx
Use `shell` tool with Python:
```
python3 -c "
from docx import Document
doc = Document('input.docx')
for p in doc.paragraphs:
    print(p.text)
"
```

### Modify existing document
Read the document, modify paragraphs/tables, save to a new file. Never overwrite the original without asking.

## Document Features

### Headers and Footers
```python
section = doc.sections[0]
header = section.header
header.paragraphs[0].text = "Header Text"
```

### Page Breaks
```python
doc.add_page_break()
```

### Images
```python
doc.add_picture('image.png', width=Inches(4))
```

### Bullet Lists
```python
doc.add_paragraph('Item 1', style='List Bullet')
doc.add_paragraph('Item 2', style='List Bullet')
```

### Numbered Lists
```python
doc.add_paragraph('Step 1', style='List Number')
doc.add_paragraph('Step 2', style='List Number')
```

## Output
- Always save to the user's specified path or `~/Desktop/` by default.
- Open the file after creation: `shell` tool with `open output.docx`.
- Confirm the file was created: `file` tool with action `exists`.
