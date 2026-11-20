"""Share bounded download workers across channels and subtitle providers."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext

_POOL=ThreadPoolExecutor(max_workers=8,thread_name_prefix='subtitle-resource')


def pool():
    return nullcontext(_POOL)
