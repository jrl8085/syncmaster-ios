import hmac
from fastapi import HTTPException, Security, status
from fastapi.security import APIKeyHeader
from .config import get_config

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

def verify_api_key(api_key: str = Security(api_key_header)) -> str:
    if api_key is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing API key")
    if not hmac.compare_digest(api_key.encode(), get_config()["api_key"].encode()):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid API key")
    return api_key
