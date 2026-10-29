import logging
from pathlib import Path
from fastapi import FastAPI, Request, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from app.analysis import analyze

logger = logging.getLogger('kakao')
ROOT = Path(__file__).resolve().parent.parent
MAX_BYTES = 5 * 1024 * 1024
app = FastAPI(title='대화의 온도', docs_url=None, redoc_url=None, openapi_url=None)

@app.middleware('http')
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers.update({'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"})
    return response

@app.exception_handler(RequestValidationError)
async def validation_error(request, exc):
    return JSONResponse(status_code=400, content={'detail': '잘못된 요청입니다.'})

@app.exception_handler(Exception)
async def unexpected_error(request, exc):
    # Never log exception payloads, request bodies, filenames or participant names.
    logger.error('analysis_request_failed type=%s', type(exc).__name__)
    return JSONResponse(status_code=500, content={'detail': '분석 중 오류가 발생했습니다. 입력 형식을 확인해 주세요.'})

@app.get('/')
def index():
    return FileResponse(ROOT / 'static' / 'index.html')

@app.get('/api/health')
def health():
    return {'status': 'ok'}

@app.post('/api/analyze')
async def analyze_input(request: Request):
    content_type = request.headers.get('content-type', '').split(';')[0].lower()
    if content_type != 'text/plain':
        raise HTTPException(415, 'TXT 텍스트만 지원합니다.')
    data = bytearray()
    async for chunk in request.stream():
        if len(data) + len(chunk) > MAX_BYTES:
            raise HTTPException(413, '최대 5 MiB까지 분석할 수 있습니다.')
        data.extend(chunk)
    if not data or b'\x00' in data:
        raise HTTPException(400, '비어 있거나 지원하지 않는 텍스트입니다. UTF-8 또는 CP949 TXT를 사용해 주세요.')
    for encoding in ('utf-8-sig', 'cp949'):
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            pass
    else:
        raise HTTPException(400, 'UTF-8 또는 CP949로 저장된 TXT 파일을 사용해 주세요.')
    try:
        threshold = int(request.query_params.get('session_minutes', '30'))
        if threshold not in (30, 60, 180):
            raise ValueError()
    except ValueError:
        raise HTTPException(400, '대화 구분 기준은 30, 60, 180분 중 선택해 주세요.')
    try:
        # CPU work is moved off the event loop.
        from starlette.concurrency import run_in_threadpool
        return await run_in_threadpool(analyze, text, threshold)
    except ValueError as exc:
        raise HTTPException(422, str(exc))

app.mount('/static', StaticFiles(directory=ROOT / 'static'), name='static')
