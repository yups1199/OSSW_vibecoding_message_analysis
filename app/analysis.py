"""Korean KakaoTalk PC/mobile export parser; no persistent state."""
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from statistics import median

DATE = re.compile(r'^[-=\s]*(\d{4})[년.\-/]\s*(\d{1,2})[월.\-/]\s*(\d{1,2})(?:일|\.)?')
PC = re.compile(r'^\[(.+?)\]\s*\[(오전|오후|AM|PM)?\s*(\d{1,2}):(\d{2})\]\s?(.*)$', re.I)
MOBILE = re.compile(r'^(\d{4})[년.\-/]\s*(\d{1,2})[월.\-/]\s*(\d{1,2})(?:일|\.)?\s*(오전|오후|AM|PM)?\s*(\d{1,2}):(\d{2})\s*,\s*(.+?)\s*:\s?(.*)$', re.I)
SYSTEM = re.compile(r'(님이 (들어왔습니다|나갔습니다|초대했습니다)|삭제된 메시지입니다\.?$|메시지가 삭제되었습니다\.?$)')

def stamp(y, m, d, period, h, minute):
    h = int(h)
    if period:
        if not 1 <= h <= 12:
            raise ValueError('hour')
        h = h % 12 + (12 if period.lower() in ('오후', 'pm') else 0)
    return datetime(int(y), int(m), int(d), h, int(minute))

def parse(text):
    messages, current_date = [], None
    ignored = invalid = 0
    continuation = False
    for line in text.lstrip('\ufeff').splitlines():
        mobile, pc = MOBILE.match(line), PC.match(line)
        try:
            if mobile:
                y, m, d, period, h, minute, sender, body = mobile.groups()
                at = stamp(y, m, d, period, h, minute)
                current_date = at.date()
            elif pc:
                if current_date is None:
                    raise ValueError('missing date')
                sender, period, h, minute, body = pc.groups()
                at = stamp(current_date.year, current_date.month, current_date.day, period, h, minute)
            else:
                date = DATE.match(line)
                if date:
                    current_date = datetime(*map(int, date.groups())).date()
                    continuation = False
                    ignored += 1
                elif SYSTEM.search(line):
                    ignored += 1
                    continuation = False
                elif continuation and line.strip():
                    messages[-1]['body'] += '\n' + line
                elif line.strip():
                    ignored += 1
                continue
            if not sender.strip():
                raise ValueError('empty sender')
            messages.append(dict(at=at, sender=sender.strip(), body=body))
            continuation = True
        except ValueError:
            invalid += 1
            continuation = False
    if not messages:
        raise ValueError('인식 가능한 메시지가 없습니다. 한국어 카카오톡 PC/모바일 TXT 내보내기 형식을 확인해 주세요.')
    return sorted(messages, key=lambda m: m['at']), ignored, invalid

def analyze(text, session_minutes=30):
    messages, ignored, invalid = parse(text)
    users = Counter(m['sender'] for m in messages)
    days = Counter(m['at'].date().isoformat() for m in messages)
    hours = Counter(m['at'].hour for m in messages)
    weekdays = Counter(m['at'].weekday() for m in messages)
    starts, replies, words, phrases = Counter(), defaultdict(list), Counter(), Counter()
    stop = {'그리고', '그런데', '나는', '저는', '우리', '오늘', '진짜', '너무', '사진', '이모티콘', '동영상', '삭제된', '메시지입니다'}
    previous = None
    for message in messages:
        gap = (message['at'] - previous['at']).total_seconds() if previous else None
        if previous is None or gap >= session_minutes * 60:
            starts[message['sender']] += 1
        elif previous['sender'] != message['sender']:
            replies[(message['sender'], previous['sender'])].append(gap)
        tokens = [w.lower() for w in re.findall(r'[가-힣A-Za-z]{2,}', re.sub(r'https?://\S+', '', message['body'])) if w.lower() not in stop]
        words.update(tokens)
        phrases.update(' '.join(pair) for pair in zip(tokens, tokens[1:]))
        previous = message
    begin, end = messages[0]['at'], messages[-1]['at']
    span = (end.date() - begin.date()).days + 1
    # Bound chart size even for very long exports; active dates remain accurate.
    daily = [{'label': (begin.date() + timedelta(days=i)).isoformat(), 'value': days[(begin.date() + timedelta(days=i)).isoformat()]} for i in range(span)] if span <= 3660 else [{'label': k, 'value': v} for k, v in sorted(days.items())]
    return dict(total=len(messages), participant_count=len(users), active_days=len(days), start=begin.isoformat(), end=end.isoformat(),
                participants=[dict(name=u, count=n, ratio=round(n / len(messages) * 100, 2), starts=starts[u]) for u, n in users.most_common()],
                daily=daily, hourly=[dict(label=f'{h:02d}시', value=hours[h]) for h in range(24)],
                weekdays=[dict(label=label, value=weekdays[i]) for i, label in enumerate('월화수목금토일')],
                words=[dict(label=w, value=n) for w, n in words.most_common(20)], phrases=[dict(label=w, value=n) for w, n in phrases.most_common(10)],
                replies=[dict(responder=a, to=b, count=len(v), median_seconds=median(v), average_seconds=round(sum(v)/len(v), 1)) for (a,b),v in sorted(replies.items(), key=lambda item: median(item[1]))],
                sessions=sum(starts.values()), session_minutes=session_minutes, ignored_lines=ignored, invalid_lines=invalid)
