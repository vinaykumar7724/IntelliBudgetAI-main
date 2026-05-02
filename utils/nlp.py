"""utils/nlp.py — NLP helpers for IntelliBudget AI chatbot."""
import re
from datetime import datetime, timedelta

try:
    import dateparser
    _DATEPARSER_AVAILABLE = True
except ImportError:
    _DATEPARSER_AVAILABLE = False


CATEGORY_KEYWORDS = {
    'Food':       ['food', 'eat', 'lunch', 'dinner', 'breakfast', 'restaurant',
                   'grocery', 'groceries', 'snack', 'coffee', 'meal', 'swiggy',
                   'zomato', 'dominos', 'pizza', 'burger'],
    'Transport':  ['transport', 'bus', 'auto', 'cab', 'uber', 'ola', 'petrol',
                   'fuel', 'metro', 'train', 'flight', 'travel', 'taxi', 'bike'],
    'Shopping':   ['shopping', 'clothes', 'shirt', 'shoes', 'amazon', 'flipkart',
                   'myntra', 'dress', 'purchase', 'buy', 'bought'],
    'Health':     ['health', 'medicine', 'doctor', 'hospital', 'pharmacy',
                   'medical', 'clinic', 'tablet', 'drug', 'gym', 'fitness',
                   'eye', 'dental', 'dentist', 'checkup', 'check up', 'check-up',
                   'consultation', 'test', 'lab', 'blood', 'xray', 'x-ray',
                   'scan', 'surgery', 'treatment', 'therapy', 'optical',
                   'spectacles', 'glasses', 'vision'],
    'Education':  ['education', 'book', 'course', 'school', 'college', 'fees',
                   'tuition', 'study', 'class', 'udemy', 'coursera'],
    'Bills':      ['bill', 'electricity', 'water', 'rent', 'internet', 'wifi',
                   'phone', 'recharge', 'broadband', 'gas', 'maintenance'],
    'Entertainment': ['entertainment', 'movie', 'netflix', 'prime', 'hotstar',
                      'spotify', 'game', 'concert', 'theatre', 'outing', 'fun'],
}

_WEEKDAYS = {
    'monday': 0, 'tuesday': 1, 'wednesday': 2,
    'thursday': 3, 'friday': 4, 'saturday': 5, 'sunday': 6,
}

_MONTHS = {
    'january': 1, 'february': 2, 'march': 3, 'april': 4,
    'may': 5, 'june': 6, 'july': 7, 'august': 8,
    'september': 9, 'october': 10, 'november': 11, 'december': 12,
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4,
    'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9,
    'oct': 10, 'nov': 11, 'dec': 12,
}

# Numbers that appear as time references — must NOT be treated as amounts
# Pattern: "<N> days back/ago", "<N> weeks ago", "<N> months ago"
_TIME_REF_PAT = re.compile(
    r'\b(\d+)\s+(?:days?\s+(?:ago|back)|weeks?\s+ago|months?\s+ago)\b',
    re.IGNORECASE
)


def _mask_time_refs(text: str) -> str:
    """Replace time-reference numbers with placeholder so amount regex skips them."""
    return _TIME_REF_PAT.sub(lambda m: m.group(0).replace(m.group(1), 'DAYS'), text)


def extract_amount_category(text: str, user_id: int = None):
    """
    Extract (amount, category) from a natural-language expense message.
    Time references like "5 days back" are excluded from amount candidates.
    """
    text_lower = text.lower()

    # ── Mask time references before amount extraction ─────────────────────────
    masked = _mask_time_refs(text_lower)

    # ── Amount extraction — runs on masked text ───────────────────────────────
    amount = None
    amount_patterns = [
        # Currency prefix: rs.500, ₹500, inr 500  ← highest priority
        r'(?:rs\.?|₹|inr\s*)(\d[\d,]*(?:\.\d{1,2})?)',
        # Currency suffix: 500 rs, 500 rupees
        r'(\d[\d,]*(?:\.\d{1,2})?)\s*(?:rs\.?|₹|rupees?)',
        # Bare number (fallback)
        r'\b(\d[\d,]*(?:\.\d{1,2})?)\b',
    ]
    for pattern in amount_patterns:
        match = re.search(pattern, masked)
        if match:
            raw = match.group(1).replace(',', '')
            try:
                amount = float(raw)
                break
            except ValueError:
                continue

    # ── Category extraction ───────────────────────────────────────────────────
    def _norm(s: str) -> str:
        return re.sub(r'[^a-z0-9]+', ' ', (s or '').lower()).strip()

    explicit = None
    m = re.search(r'\b(?:to|on|for|in)\s+([a-z][a-z0-9 &_-]{1,40})', text_lower)
    if m:
        explicit = m.group(1).strip()

    candidates = set(CATEGORY_KEYWORDS.keys()) | {
        'Other', 'Bills', 'Food', 'Transport', 'Shopping', 'Health', 'Education'
    }
    if user_id is not None:
        try:
            from models import UserCategory
            user_cats = UserCategory.query.filter_by(user_id=user_id).all()
            for c in user_cats:
                if c and c.name:
                    candidates.add(c.name)
        except Exception:
            pass

    norm_map = {_norm(c): c for c in candidates if _norm(c)}

    if explicit:
        ne = _norm(explicit)
        if ne in norm_map:
            return amount, norm_map[ne]
        for k, orig in norm_map.items():
            if ne and (ne in k or k in ne):
                return amount, orig

    # Multi-word keyword check first (longer matches win)
    multi_kw = {
        'Health': ['eye check up', 'eye check-up', 'eye checkup', 'check up',
                   'check-up', 'eye test', 'blood test', 'lab test'],
    }
    for cat, keywords in multi_kw.items():
        for kw in keywords:
            if kw in text_lower:
                return amount, cat

    for cat, keywords in CATEGORY_KEYWORDS.items():
        for kw in keywords:
            if kw in text_lower:
                return amount, cat

    nt = _norm(text)
    for k, orig in sorted(norm_map.items(), key=lambda x: len(x[0]), reverse=True):
        if k and f' {k} ' in f' {nt} ':
            return amount, orig

    return amount, 'Other'


def extract_description(text: str) -> str:
    cleaned = re.sub(
        r'\b(add|added|spent|spend|paid|pay|record|log|save)\b',
        '', text, flags=re.IGNORECASE
    ).strip()
    return cleaned[:100] if cleaned else text[:100]


# ── Date extraction ───────────────────────────────────────────────────────────

def _make_date(day: int, month: int, year: int) -> datetime:
    import calendar
    max_day = calendar.monthrange(year, month)[1]
    day = max(1, min(day, max_day))
    return datetime(year, month, day)


def extract_date(text: str) -> datetime:
    """
    Extract date from free-form text. Priority:
      1. today / yesterday / day before yesterday
      2. N days ago / N days back
      3. last/this <weekday>
      4. "<day>[ordinal] <month> [year]"  — "24th april", "25 apr 2026"
      5. "<month> <day>[ordinal] [year]"  — "april 24th", "Apr 24"
      6. Numeric DD/MM/YYYY or DD/MM
      7. dateparser fallback
      8. today
    """
    today   = datetime.utcnow()
    text_lo = text.lower()

    if re.search(r'\btoday\b', text_lo):
        return today

    if re.search(r'\bday before yesterday\b', text_lo):
        return today - timedelta(days=2)

    if re.search(r'\byesterday\b', text_lo):
        return today - timedelta(days=1)

    # "N days ago" OR "N days back"
    m = re.search(r'(\d+)\s+days?\s+(?:ago|back)', text_lo)
    if m:
        return today - timedelta(days=int(m.group(1)))

    m = re.search(r'(\d+)\s+weeks?\s+ago', text_lo)
    if m:
        return today - timedelta(weeks=int(m.group(1)))

    m = re.search(r'(\d+)\s+months?\s+ago', text_lo)
    if m:
        # Approximate month ago
        month = today.month - int(m.group(1))
        year  = today.year
        while month < 1:
            month += 12
            year  -= 1
        return _make_date(today.day, month, year)

    m = re.search(
        r'last\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)',
        text_lo
    )
    if m:
        target = _WEEKDAYS[m.group(1)]
        delta  = (today.weekday() - target) % 7 or 7
        return today - timedelta(days=delta)

    m = re.search(
        r'this\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)',
        text_lo
    )
    if m:
        target = _WEEKDAYS[m.group(1)]
        delta  = (today.weekday() - target) % 7
        return today - timedelta(days=delta)

    month_pat = '|'.join(_MONTHS.keys())

    # "<day>[ordinal] <month> [year]"
    m = re.search(
        rf'(\d{{1,2}})(?:st|nd|rd|th)?\s+({month_pat})(?:\s+(\d{{4}}))?',
        text_lo
    )
    if m:
        day   = int(m.group(1))
        month = _MONTHS[m.group(2)]
        year  = int(m.group(3)) if m.group(3) else today.year
        dt    = _make_date(day, month, year)
        if dt > today and not m.group(3):
            dt = _make_date(day, month, year - 1)
        return dt

    # "<month> <day>[ordinal] [year]"
    m = re.search(
        rf'({month_pat})\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:\s+(\d{{4}}))?',
        text_lo
    )
    if m:
        month = _MONTHS[m.group(1)]
        day   = int(m.group(2))
        year  = int(m.group(3)) if m.group(3) else today.year
        dt    = _make_date(day, month, year)
        if dt > today and not m.group(3):
            dt = _make_date(day, month, year - 1)
        return dt

    # Numeric DD/MM/YYYY
    m = re.search(r'(\d{1,2})[/\-](\d{1,2})[/\-](\d{4})', text_lo)
    if m:
        try:
            return _make_date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass

    # Numeric DD/MM (current year)
    m = re.search(r'\b(\d{1,2})[/\-](\d{1,2})\b', text_lo)
    if m:
        try:
            dt = _make_date(int(m.group(1)), int(m.group(2)), today.year)
            if dt > today:
                dt = _make_date(int(m.group(1)), int(m.group(2)), today.year - 1)
            return dt
        except ValueError:
            pass

    if _DATEPARSER_AVAILABLE:
        parsed = dateparser.parse(
            text,
            settings={
                'PREFER_DATES_FROM':        'past',
                'RETURN_AS_TIMEZONE_AWARE': False,
                'RELATIVE_BASE':            today,
            }
        )
        if parsed:
            return parsed

    return today
