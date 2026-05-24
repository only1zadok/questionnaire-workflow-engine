.PHONY: lint format typecheck test run worker

lint:
	uv run ruff check .

format:
	uv run ruff format .

typecheck:
	uv run mypy app tests

test:
	uv run pytest

run:
	@echo "FastAPI app lands in Slice 1.2."

worker:
	@echo "Arq worker lands in Slice 1.4."
