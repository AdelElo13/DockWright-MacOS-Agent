---
name: Financial Data Query
description: Query financial data covering stocks, bonds, funds, currencies, and commodities
requires: web_search, shell, file
stars: 44
author: Financial-AI-Analyst
---

# Financial Data Query

You help users retrieve and analyze financial market data across asset classes.

## Data Retrieval

### Stock Data
Use `shell` tool with curl:

**Current Quote (Yahoo Finance):**
```
curl -s "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?interval=1d&range=5d" | python3 -c "
import json, sys
data = json.load(sys.stdin)
result = data['chart']['result'][0]
meta = result['meta']
print(f\"Symbol: {meta['symbol']}\")
print(f\"Price: \${meta['regularMarketPrice']}\")
print(f\"Previous Close: \${meta['previousClose']}\")
print(f\"Currency: {meta['currency']}\")
"
```

**Historical Data:**
```
curl -s "https://query1.finance.yahoo.com/v8/finance/chart/AAPL?interval=1d&range=1y" | python3 -c "
import json, sys
data = json.load(sys.stdin)
quotes = data['chart']['result'][0]
timestamps = quotes['timestamp']
closes = quotes['indicators']['quote'][0]['close']
import datetime
for t, c in zip(timestamps[-10:], closes[-10:]):
    d = datetime.datetime.fromtimestamp(t).strftime('%Y-%m-%d')
    print(f'{d}: \${c:.2f}')
"
```

### Currency Exchange Rates
```
curl -s "https://api.exchangerate-api.com/v4/latest/USD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for curr in ['EUR', 'GBP', 'JPY', 'CHF', 'CAD', 'AUD']:
    print(f'USD/{curr}: {data[\"rates\"][curr]}')
"
```

### Cryptocurrency
Use `web_search` tool:
- "[crypto] price USD today"
- "bitcoin market cap"
- "ethereum price chart"

Or CoinGecko API:
```
curl -s "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd,eur" | python3 -m json.tool
```

### Bond Yields
Use `web_search` tool:
- "US 10 year treasury yield"
- "US yield curve"
- "corporate bond yields investment grade"

### Commodity Prices
Use `web_search` tool:
- "gold price per ounce today"
- "crude oil WTI price"
- "silver copper commodity prices"

### Fund/ETF Data
Yahoo Finance works for ETFs too:
```
curl -s "https://query1.finance.yahoo.com/v8/finance/chart/SPY?interval=1d&range=1mo"
```

## Analysis Features

### Portfolio Summary
If the user provides their holdings:
1. Fetch current prices for each position.
2. Calculate current value and daily change.
3. Calculate total portfolio value and allocation percentages.
4. Present as a portfolio table.

### Price Comparison
Compare multiple assets over a time period:
1. Fetch historical data for each asset.
2. Normalize to percentage change from start date.
3. Present comparison table showing relative performance.

### Technical Indicators
Calculate basic indicators using Python:
- Moving averages (50-day, 200-day).
- RSI (Relative Strength Index).
- MACD.
- Bollinger Bands.

Use `shell` tool with a Python script that processes the historical data.

### Export Data
Save to CSV for further analysis:
```python
import csv
with open('output.csv', 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['Date', 'Open', 'High', 'Low', 'Close', 'Volume'])
    for row in data:
        writer.writerow(row)
```

Save to `~/Desktop/` by default, or user-specified path.

## Disclaimer
Always include: "Financial data is provided for informational purposes only. Prices may be delayed. This is not investment advice."
