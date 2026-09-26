"""Windows service entry point with bounded logs and no request access logging."""

import argparse
import logging
import logging.handlers
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    folder = args.backend.parent / "logs"
    folder.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        folder / "server.log", maxBytes=10 * 1024**2, backupCount=5, encoding="utf-8"
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    )
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True
    sys.path.insert(0, str(args.backend.resolve()))
    try:
        import uvicorn

        uvicorn.run(
            "app.main:app",
            host="0.0.0.0",
            port=args.port,
            access_log=False,
            proxy_headers=False,
            log_config=None,
        )
    except BaseException:
        logging.getLogger(__name__).exception("Server exited")
        raise


if __name__ == "__main__":
    main()
