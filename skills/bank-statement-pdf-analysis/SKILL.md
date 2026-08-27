---
name: bank-statement-pdf-analysis
description: Parse Turkish bank credit card statement PDFs (Garanti, İş Bankası, Yapı Kredi, etc.) into structured JSON with transaction details (card, date, description, amount, category) and analytical breakdowns by card, currency, and category. Use when the user provides a Turkish bank statement PDF and wants transaction extraction, JSON data, or spending analysis.
---

# Bank Statement PDF Analysis (Turkish Banks)

## Trigger
Use when the user provides a Turkish bank credit card statement PDF (Garanti, İş Bankası, Yapı Kredi, vb.) and wants transaction extraction, JSON data, and analytical report with breakdowns by card, currency, and transaction type.

## Prerequisites
- `poppler` for `pdftotext`: `brew install poppler`
- Python 3 with standard library (json, re, collections)

## Steps

### 1. Extract Text from PDF

```bash
INPUT="/path/to/statement.pdf"
OUTPUT="/tmp/bank_extracted.txt"
pdftotext -layout "$INPUT" "$OUTPUT"
wc -l "$OUTPUT"
```

### 2. Inspect Raw Structure

Before writing the parser, inspect the text to understand the layout:

```python
import re
lines = open('/tmp/bank_extracted.txt', 'r', encoding='utf-8').read().split('\n')

# Find card headers
for i, line in enumerate(lines):
    if 'Numaralı Kart' in line and ('TL' in line or 'USD' in line or 'EUR' in line):
        print(f"Card header at line {i}: [{line[:100]}]")

# Find transaction lines (start with 1-2 digits + spaces + description)
for i, line in enumerate(lines):
    m = re.match(r'^\s{2,}(\d{1,2})\s{2,}(.+)$', line)
    if m and len(m.group(2).strip()) > 2:
        desc = m.group(2).strip()
        print(f"Line {i}: day={m.group(1)}, desc='{desc[:30]}'")
        # Also show the next few lines for context
        for j in range(i+1, min(i+5, len(lines))):
            print(f"  Line {j}: [{lines[j][:100]}]")
        break  # Show one example, then stop
```

### 3. Write Parser

The typical Garanti statement structure per transaction is 4 lines:

```
Line 0: "          DD               DESCRIPTION"
Line 1: "                                                                         CATEGORY                     MIL_AMOUNT                                                -TOTAL_AMOUNT"
Line 2: "         MONTH           LOCATION"  or  "         MONTH"
Line 3: "          YYYY"
```

Use `re.search` (not `re.match`) for card headers — they have leading whitespace and the Turkish character `ı` in `Numaralı`.

```python
import json, re
from collections import defaultdict

raw = open('/tmp/bank_extracted.txt', 'r', encoding='utf-8').read()
lines = raw.split('\n')

transactions = []
current_card = None
current_currency = None

i = 0
while i < len(lines):
    line = lines[i]
    
    # Card header - use re.search (not re.match) due to leading whitespace
    m = re.search(r'(\d{4})\s+\*\*\*\*\s+\*\*\*\*\s+(\d{4}).*?(TL|USD|EUR)\s+Ekstre', line)
    if m:
        current_card = f"{m.group(1)}****{m.group(2)}"
        current_currency = m.group(3)
        i += 1
        continue
    
    # Transaction start: 2+ spaces, 1-2 digits, 2+ spaces, description
    m = re.match(r'^\s{2,}(\d{1,2})\s{2,}(.+)$', line)
    if m and current_card:
        day = int(m.group(1))
        desc_raw = m.group(2).strip()
        
        if len(desc_raw) < 2:
            i += 1
            continue
        
        # Next non-empty line = category + mil + amount
        j = i + 1
        while j < len(lines) and not lines[j].strip():
            j += 1
        
        amount_line = lines[j].strip() if j < len(lines) else ''
        
        # Extract signed amount (last number, e.g. -52.430,00 or +182.535,43)
        signed_match = re.search(r'([+-]\d{1,3}(?:\.\d{3})*,\d{2})', amount_line)
        total_amount = 0.0
        mil_amount = 0.0
        
        if signed_match:
            total_amount = abs(float(signed_match.group(1).replace('.', '').replace(',', '.')))
            all_nums = re.findall(r'(\d{1,3}(?:\.\d{3})*,\d{2})', amount_line)
            if all_nums:
                mil_amount = float(all_nums[0].replace('.', '').replace(',', '.'))
        
        # Extract category
        cats = ['Diğer', 'Emeklilik/Sigorta', 'Ulaşım', 'Yeme / İçme', 'Akaryakıt',
                'Market', 'Kişisel Hizmet', 'Kurum Ödemesi', 'Kart Ödemesi',
                'Eğlence / Hobi', 'Sağlık / Bakım', 'Giyim / Aksesuar',
                'Para Transferi', 'Vergi', 'Eğitim', 'Turizm / Konaklama',
                'Ev / Dekorasyon']
        category = 'Diğer'
        for cat in cats:
            if cat in amount_line:
                category = cat
                break
        
        # Month and location
        month = 'AĞUSTOS'  # Default for first section
        location = ''
        k = j + 1
        while k < len(lines) and not lines[k].strip():
            k += 1
        if k < len(lines):
            month_line = lines[k].strip()
            m_loc = re.match(r'^([A-ZÇĞİÖŞÜa-zçğıöşü]{3,10})(?:\s+(.+))?$', month_line)
            if m_loc:
                month_part = m_loc.group(1)
                if month_part in ['AĞUSTOS', 'AGUSTOS', 'TEMMUZ', 'HAZİRAN', 'MAYIS', 'NİSAN', 'MAR']:
                    month = month_part
                    loc_part = m_loc.group(2)
                    if loc_part:
                        loc_words = [w for w in loc_part.split() if len(w) > 1 and any(c.isalpha() for c in w)]
                        if loc_words:
                            location = ' '.join(loc_words[:3])
        
        # Skip past year line
        year_j = k + 1
        while year_j < len(lines) and not lines[year_j].strip():
            year_j += 1
        
        transactions.append({
            'card': current_card,
            'currency': current_currency,
            'date': f"{day:02d} {month} 2026",
            'description': desc_raw,
            'category': category,
            'mil': round(mil_amount, 2),
            'amount': round(total_amount, 2),
            'is_payment': True,
            'location': location
        })
        
        i = year_j
        continue
    
    i += 1

# Save JSON
with open('/tmp/bank_transactions.json', 'w', encoding='utf-8') as f:
    json.dump(transactions, f, ensure_ascii=False, indent=2)

print(f"Total transactions parsed: {len(transactions)}")
```

### 4. Generate Analytical Report

Use the parsed data to create breakdowns:

```python
from collections import defaultdict

# By card
by_card = defaultdict(lambda: {'count': 0, 'total': 0.0, 'mil': 0.0, 'currency': ''})
for t in transactions:
    key = f"{t['card']} ({t['currency']})"
    by_card[key]['count'] += 1
    by_card[key]['total'] += t['amount']
    by_card[key]['mil'] += t['mil']
    by_card[key]['currency'] = t['currency']

# By category + currency
by_cat_cur = defaultdict(lambda: {'count': 0, 'total': 0.0, 'mil': 0.0})
for t in transactions:
    key = f"{t['category']} ({t['currency']})"
    by_cat_cur[key]['count'] += 1
    by_cat_cur[key]['total'] += t['amount']
    by_cat_cur[key]['mil'] += t['mil']

# By category split by card
by_cat_card = defaultdict(lambda: defaultdict(lambda: {'count': 0, 'total': 0.0, 'mil': 0.0}))
for t in transactions:
    key = f"{t['card']} ({t['currency']})"
    by_cat_card[t['category']][key]['count'] += 1
    by_cat_card[t['category']][key]['total'] += t['amount']
    by_cat_card[t['category']][key]['mil'] += t['mil']
```

### 5. Save to Desktop

```bash
cp /tmp/bank_transactions.json ~/Desktop/bank_statement_transactions.json
cp ~/Desktop/bank_report.md ~/Desktop/bank_statement_report.md
```

## Pitfalls

- **`re.search` not `re.match`** for card headers — lines have leading whitespace.
- **Turkish characters** in `Numaralı` (with dotted `ı`) — regex must match `Numaralı` not `Numaralı`.
- **Category extraction** depends on the Turkish category names; update the list if the bank uses different labels.
- **Month detection** uses Turkish month names — update the list if the statement covers other months.
- **`pdftotext`** preserves column layout with spaces — the fixed-column approach is essential.
- **Amount parsing**: Turkish format uses `.` as thousand separator and `,` as decimal — must be handled when converting to float.
- **Different banks** may use different layouts — always inspect the raw text first (Step 2) before writing the parser.

## Verification

- Check that transaction count matches what you can see in the PDF page count
- Spot-check 3-5 transactions against the PDF to verify amounts, categories, and descriptions
- Ensure all 6 card sections are detected (2 cards × 3 currencies typically)
