---
name: Excel Spreadsheet Creator
description: Create and edit Excel (.xlsx) spreadsheets with formulas, charts, and formatting
requires: shell, file
stars: 61
author: ivangdavila
---

# Excel Spreadsheet Creator

You create and edit Excel (.xlsx) spreadsheets using Python's openpyxl library.

## Setup
Check/install openpyxl:
- `shell` tool: `python3 -c "import openpyxl" 2>/dev/null || pip3 install openpyxl`

## Creating Spreadsheets

Write a Python script with `file` tool, then execute with `shell` tool.

### Basic Spreadsheet
```python
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
from openpyxl.utils import get_column_letter

wb = Workbook()
ws = wb.active
ws.title = "Sheet1"

# Headers with styling
headers = ["Name", "Value", "Date"]
header_font = Font(bold=True, size=12)
header_fill = PatternFill(start_color="4472C4", end_color="4472C4", fill_type="solid")
header_font_white = Font(bold=True, size=12, color="FFFFFF")

for col, header in enumerate(headers, 1):
    cell = ws.cell(row=1, column=col, value=header)
    cell.font = header_font_white
    cell.fill = header_fill
    cell.alignment = Alignment(horizontal="center")

# Data rows
data = [
    ["Item A", 100, "2024-01-15"],
    ["Item B", 200, "2024-01-16"],
]
for row_idx, row_data in enumerate(data, 2):
    for col_idx, value in enumerate(row_data, 1):
        ws.cell(row=row_idx, column=col_idx, value=value)

# Auto-fit column widths
for col in range(1, len(headers) + 1):
    ws.column_dimensions[get_column_letter(col)].width = 15

wb.save("output.xlsx")
```

### Formulas
```python
# SUM
ws.cell(row=10, column=2, value="=SUM(B2:B9)")
# AVERAGE
ws.cell(row=11, column=2, value="=AVERAGE(B2:B9)")
# IF
ws.cell(row=2, column=4, value='=IF(B2>100,"High","Low")')
# VLOOKUP
ws.cell(row=2, column=5, value='=VLOOKUP(A2,Sheet2!A:B,2,FALSE)')
```

### Charts
```python
from openpyxl.chart import BarChart, Reference

chart = BarChart()
chart.title = "Sales Data"
chart.x_axis.title = "Category"
chart.y_axis.title = "Value"

data = Reference(ws, min_col=2, min_row=1, max_row=10)
cats = Reference(ws, min_col=1, min_row=2, max_row=10)
chart.add_data(data, titles_from_data=True)
chart.set_categories(cats)
ws.add_chart(chart, "E2")
```

### Multiple Sheets
```python
ws2 = wb.create_sheet("Summary")
ws3 = wb.create_sheet("Raw Data")
```

### Conditional Formatting
```python
from openpyxl.formatting.rule import CellIsRule

red_fill = PatternFill(start_color="FFC7CE", end_color="FFC7CE", fill_type="solid")
ws.conditional_formatting.add("B2:B100",
    CellIsRule(operator="lessThan", formula=["0"], fill=red_fill))
```

## Reading Existing Spreadsheets
```python
from openpyxl import load_workbook
wb = load_workbook("input.xlsx")
ws = wb.active
for row in ws.iter_rows(values_only=True):
    print(row)
```

## CSV to Excel Conversion
```python
import csv
from openpyxl import Workbook

wb = Workbook()
ws = wb.active
with open("input.csv") as f:
    for row in csv.reader(f):
        ws.append(row)
wb.save("output.xlsx")
```

## Output
- Save to user's specified path or `~/Desktop/` by default.
- Open after creation: `shell` tool with `open output.xlsx`.
- Confirm file exists and report file size.
